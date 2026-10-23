import AppKit
import Common

/// Where a window dragged with the mouse lands relative to the tile under the cursor
enum DropZone: Equatable {
    /// Puts the window on top of the tile. The tile becomes (or already is) an accordion, aka stack
    case stack
    /// The center zone with the Option key held
    case swap
    case split(CardinalDirection)
}

/// Targets are window ids, so that a drop can be replayed on a fresh snapshot of the tree. See SimNode
enum DropOp: Equatable {
    case tile(targetWindowId: UInt32, DropZone)
    case intoEmptyWorkspace
}

struct PendingDrop {
    let window: Window
    let workspace: Workspace
    let op: DropOp
}

/// Fraction of the target window's width/height (measured from each edge) that counts as a split zone
private let splitZoneFraction: CGFloat = 0.3

private struct DragSession {
    let windowId: UInt32
    let initialSize: CGSize?
    /// Dialogs (see isDialogHeuristic) are never tiled by a drop
    let isDialog: Bool
    var isResize = false
}

@MainActor private var dragSession: DragSession? = nil
@MainActor private var pendingDrop: PendingDrop? = nil

func dropZone(for point: CGPoint, in rect: Rect) -> DropZone {
    guard rect.width > 0 && rect.height > 0 else { return .stack }
    let fx = (point.x - rect.minX) / rect.width
    let fy = (point.y - rect.minY) / rect.height
    let edges: [(CGFloat, CardinalDirection)] = [(fx, .left), (1 - fx, .right), (fy, .up), (1 - fy, .down)]
    guard let (distance, direction) = edges.min(by: { $0.0 < $1.0 }) else { return .stack }
    return distance < splitZoneFraction ? .split(direction) : .stack
}

/// Called on every move event of a tiling or floating window dragged with the mouse. Only previews the drop; see takePendingDrop
@MainActor
func updateDropPreview(_ window: Window) async throws {
    if dragSession?.windowId != window.windowId {
        // Not nil'ed by resizeWithMouse, so it still holds the size from before the drag. Floating windows don't have it
        var initialSize = window.lastAppliedLayoutPhysicalRect?.size
        if initialSize == nil { initialSize = try await window.getAxRect(.cancellable)?.size }
        let isDialog = window.parent is FloatingWindowsContainer
            ? try await (window as? MacWindow)?.isDialogHeuristic(getWindowLevel(for: window.windowId), .cancellable) ?? false
            : false
        dragSession = DragSession(windowId: window.windowId, initialSize: initialSize, isDialog: isDialog)
    }
    currentlyManipulatedWithMouseWindowId = window.windowId
    window.lastAppliedLayoutPhysicalRect = nil
    if let initialSize = dragSession?.initialSize, let size = try await window.getAxRect(.cancellable)?.size,
       abs(size.width - initialSize.width) > 5 || abs(size.height - initialSize.height) > 5
    {
        dragSession?.isResize = true // Dragging the left or top edge also moves the window
    }
    refreshDropPreview(window)
}

/// The Option key switches between stack and swap without moving the mouse
@MainActor
func dropModifierFlagsChanged() {
    guard let dragSession, isLeftMouseButtonDown, let window = Window.get(byId: dragSession.windowId) else { return }
    refreshDropPreview(window)
}

@MainActor
private func refreshDropPreview(_ window: Window) {
    guard let dragSession, !dragSession.isResize, !dragSession.isDialog,
          let drop = findDrop(window, at: mouseLocation),
          let preview = previewDrop(drop)
    else {
        pendingDrop = nil
        DropZoneOverlay.shared.hide()
        return
    }
    pendingDrop = drop
    DropZoneOverlay.shared.show(preview)
}

/// Decides what the drop means, based on where the windows are now
@MainActor
private func findDrop(_ window: Window, at point: CGPoint) -> PendingDrop? {
    let workspace = point.monitorApproximation.activeWorkspace
    let isFloating = window.parent is FloatingWindowsContainer
    if let targetWindow = point.findWindowRecursively(in: workspace.rootTilingContainer, virtual: false, fullscreenCoversAll: false, excluding: window),
       targetWindow != window,
       let rect = targetWindow.stackOrSelf.lastAppliedLayoutPhysicalRect
    {
        var zone = dropZone(for: point, in: rect)
        // Floating windows are tiled only via the edge zones. The center keeps them floating
        if isFloating && zone == .stack { return nil }
        // Swapping with a window of another workspace would need to preview two workspaces at once
        if zone == .stack && NSEvent.modifierFlags.contains(.option) && window.nodeWorkspace == workspace { zone = .swap }
        return PendingDrop(window: window, workspace: workspace, op: .tile(targetWindowId: targetWindow.windowId, zone))
    }
    // Floating windows moved to another monitor stay floating
    if !isFloating && workspace != window.nodeWorkspace && workspace.rootTilingContainer.allLeafWindowsRecursive.isEmpty {
        return PendingDrop(window: window, workspace: workspace, op: .intoEmptyWorkspace)
    }
    return nil
}

/// Lays out the simulated result. Draws where every window ends up, not where the cursor is
@MainActor
private func previewDrop(_ drop: PendingDrop) -> DropPreview? {
    guard let sim = simulate(drop) else { return nil }
    let monitor = drop.workspace.workspaceMonitor
    sim.layout(monitor.visibleRectPaddedByOuterGaps, innerGaps: ResolvedGaps(gaps: config.gaps, monitor: monitor).inner)
    guard let landingTile = sim.window(drop.window.windowId)?.stackOrSelf, let landingRect = landingTile.rect else { return nil }

    var ghosts: [DropPreview.Ghost] = []
    var seenTiles: [ObjectIdentifier] = [ObjectIdentifier(landingTile)]
    for simWindow in sim.allWindows {
        let tile = simWindow.stackOrSelf
        if seenTiles.contains(ObjectIdentifier(tile)) { continue }
        seenTiles.append(ObjectIdentifier(tile))
        guard let futureRect = tile.rect, let topId = tile.mostRecentWindowRecursive?.windowId else { continue }
        let currentRect = Window.get(byId: topId)?.stackOrSelf.lastAppliedLayoutPhysicalRect
        if let currentRect, currentRect.isClose(to: futureRect) { continue } // Only windows that move are drawn
        ghosts.append(DropPreview.Ghost(
            id: topId,
            rect: futureRect.cgRect,
            name: Window.get(byId: topId)?.app.name ?? "Window",
            stackCount: tile.allWindows.count,
        ))
    }

    let action: DropPreview.Action
    var targetName: String? = nil
    switch drop.op {
        case .intoEmptyWorkspace:
            action = .moveToWorkspace(drop.workspace.name)
        case .tile(let targetWindowId, let zone):
            targetName = Window.get(byId: targetWindowId)?.app.name
            action = switch zone {
                case .stack: .stack
                case .swap: .swap
                case .split(let direction): .split(direction)
            }
    }
    return DropPreview(
        action: action,
        targetName: targetName,
        monitorRect: monitor.rect.cgRect,
        landingRect: landingRect.cgRect,
        landingStackCount: landingTile.allWindows.count,
        ghosts: ghosts,
    )
}

/// Applies the drop to a snapshot of the target workspace and normalizes it, exactly as the real refresh would
@MainActor
func simulate(_ drop: PendingDrop) -> SimNode? {
    let sim = SimNode.snapshot(drop.workspace)
    let dragged = sim.window(drop.window.windowId) ?? SimNode(.window(drop.window.windowId))
    switch drop.op {
        case .intoEmptyWorkspace:
            dragged.bind(to: sim.rootContainer, weight: WEIGHT_AUTO, index: 0)
        case .tile(let targetWindowId, let zone):
            guard let target = sim.window(targetWindowId), target !== dragged else { return nil }
            switch zone {
                case .stack:
                    stackWindow(dragged, onto: target.stackOrSelf)
                case .swap:
                    guard dragged.parent != nil else { return nil }
                    swapWindows(dragged, target)
                case .split(let direction):
                    splitTile(target.stackOrSelf, with: dragged, direction)
            }
    }
    sim.normalizeContainers()
    return sim
}

/// Hides the preview and returns the drop that should be applied on mouse up, if any
@MainActor
func takePendingDrop() -> PendingDrop? {
    DropZoneOverlay.shared.hide()
    dragSession = nil
    defer { pendingDrop = nil }
    return pendingDrop
}

/// Rebuilds the target workspace from the same simulation that the preview showed
@MainActor
func applyDrop(_ drop: PendingDrop) {
    let window = drop.window
    guard window.parent is TilingContainer || window.parent is FloatingWindowsContainer else { return }
    guard let sim = simulate(drop) else { return } // The tree might have changed during the drag
    var windows: [UInt32: Window] = [window.windowId: window]
    for window in drop.workspace.rootTilingContainer.allLeafWindowsRecursive {
        windows[window.windowId] = window
    }
    sim.materialize(into: drop.workspace, windows: windows)
}

extension Window {
    /// Stacks are dropped onto as a whole, so that splitting a stack doesn't split the window on top of it
    @MainActor
    fileprivate var stackOrSelf: TreeNode {
        if let stack = parent as? TilingContainer, stack.layout == .accordion, !stack.isRootContainer { stack } else { self }
    }
}

extension SimNode {
    fileprivate var mostRecentWindowRecursive: SimNode? {
        windowId != nil ? self : mostRecentChild?.mostRecentWindowRecursive
    }
}

extension Rect {
    fileprivate func isClose(to other: Rect) -> Bool {
        abs(minX - other.minX) < 2 && abs(minY - other.minY) < 2 && abs(width - other.width) < 2 && abs(height - other.height) < 2
    }
}

// MARK: Drop operations on the simulated tree

@MainActor
private func stackWindow(_ window: SimNode, onto tile: SimNode) {
    if window.parent != nil { window.unbind() }
    if tile.layout == .accordion {
        window.bind(to: tile, weight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    } else {
        guard let parentOrientation = tile.parent?.orientation else { return }
        // Opposite orientation, so that enable-normalization-opposite-orientation-for-nested-containers doesn't flip it
        let stack = wrap(tile, parentOrientation.opposite, .accordion)
        window.bind(to: stack, weight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    }
}

/// Splits the space of `target` in half and puts `window` on the `direction` side. Other tiles keep their sizes
@MainActor
private func splitTile(_ target: SimNode, with window: SimNode, _ direction: CardinalDirection) {
    if window.parent != nil { window.unbind() }
    guard let parent = target.parent, parent.isContainer else { return }
    if parent.orientation == direction.orientation && parent.layout == .tiles {
        let half = target.weight / 2
        target.weight = half
        window.bind(to: parent, weight: half, index: target.ownIndex.orDie() + direction.insertionOffset)
    } else {
        let newParent = wrap(target, direction.orientation, .tiles)
        window.bind(to: newParent, weight: WEIGHT_AUTO, index: direction.isPositive ? INDEX_BIND_LAST : 0)
    }
}

/// Same as swapWindows(mruDominant:_:)
@MainActor
private func swapWindows(_ window1: SimNode, _ window2: SimNode) {
    let binding2 = window2.unbind()
    let binding1 = window1.unbind()
    window2.bind(to: binding1.parent, weight: binding1.weight, index: binding1.index)
    window1.bind(to: binding2.parent, weight: binding2.weight, index: binding2.index)
}

/// Replaces `node` with a new container that holds `node`
@MainActor
private func wrap(_ node: SimNode, _ orientation: Orientation, _ layout: Layout) -> SimNode {
    let binding = node.unbind()
    let container = SimNode(.container(orientation, layout))
    container.bind(to: binding.parent, weight: binding.weight, index: binding.index)
    node.bind(to: container, weight: WEIGHT_AUTO, index: 0)
    return container
}
