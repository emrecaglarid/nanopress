import AppKit
import Common
import HotKey

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
    /// `level` > 0 splits the group (container) that many levels above the tile instead of the tile itself
    case tile(targetWindowId: UInt32, DropZone, level: Int = 0)
    case intoEmptyWorkspace
}

struct PendingDrop {
    let window: Window
    let workspace: Workspace
    let op: DropOp
}

/// Fraction of the target window's width/height (measured from each edge) that counts as a split zone
private let splitZoneFraction: CGFloat = 0.3
/// Pushing the cursor this close to the screen edge (or into the menu bar or Dock) targets the whole screen
private let screenEdgeSnapDistance: CGFloat = 12

private struct DragSession {
    let windowId: UInt32
    let initialSize: CGSize?
    /// Dialogs (see isDialogHeuristic) are never tiled by a drop
    let isDialog: Bool
    /// The tile the window was dragged out of. It stays empty until the drop. Nil if the window wasn't tiled on its own
    let origin: (rect: Rect, workspace: Workspace)?
    var isResize = false
    /// Tab steps through the options of a split zone. The choice is kept while the cursor stays in the same zone
    var optionsKey: DropOptions.Key? = nil
    var optionIndex = 0
}

/// Split zones offer one option per group that the hovered tile is at the edge of: the tile, its row or column, the screen.
/// Options that produce the same layout are merged
private struct DropOptions {
    struct Key: Equatable {
        let targetWindowId: UInt32
        let zone: DropZone
        let snapsToScreen: Bool
    }

    var key: Key?
    var options: [(drop: PendingDrop, group: DropPreview.Group?)]
    var defaultIndex: Int
}

@MainActor private var dragSession: DragSession? = nil
@MainActor private var pendingDrop: PendingDrop? = nil
@MainActor private var nextOptionHotKey: HotKey? = nil

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
        dragSession = DragSession(windowId: window.windowId, initialSize: initialSize, isDialog: isDialog, origin: dragOrigin(window))
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

@MainActor
private func dragOrigin(_ window: Window) -> (rect: Rect, workspace: Workspace)? {
    guard let parent = window.parent as? TilingContainer, let workspace = window.nodeWorkspace,
          let rect = window.lastAppliedLayoutPhysicalRect else { return nil }
    if parent.layout == .accordion && parent.children.count > 1 { return nil } // The rest of the stack stays there
    return (rect, workspace)
}

/// The Option key switches between stack and swap without moving the mouse
@MainActor
func dropModifierFlagsChanged() {
    guard let dragSession, isLeftMouseButtonDown, let window = Window.get(byId: dragSession.windowId) else { return }
    refreshDropPreview(window)
}

@MainActor
private func selectNextDropOption() {
    guard let session = dragSession, isLeftMouseButtonDown, let window = Window.get(byId: session.windowId) else { return }
    dragSession?.optionIndex += 1
    refreshDropPreview(window)
}

@MainActor
private func refreshDropPreview(_ window: Window) {
    guard let session = dragSession, !session.isResize, !session.isDialog,
          let found = findDropOptions(window, at: mouseLocation), !found.options.isEmpty
    else {
        pendingDrop = nil
        setNextOptionHotKeyEnabled(false)
        DropZoneOverlay.shared.hide()
        return
    }
    if session.optionsKey != found.key {
        dragSession?.optionsKey = found.key
        dragSession?.optionIndex = found.defaultIndex
    }
    let index = (dragSession?.optionIndex ?? 0) % found.options.count
    let option = found.options[index]
    guard let preview = previewDrop(option.drop, group: option.group, optionIndex: index, optionCount: found.options.count) else {
        pendingDrop = nil
        DropZoneOverlay.shared.hide()
        return
    }
    pendingDrop = option.drop
    setNextOptionHotKeyEnabled(found.options.count > 1)
    DropZoneOverlay.shared.show(preview)
}

/// Tab is taken only while there is something to switch between, so it doesn't reach the dragged window's app
@MainActor
private func setNextOptionHotKeyEnabled(_ enabled: Bool) {
    if enabled && nextOptionHotKey == nil {
        nextOptionHotKey = HotKey(key: .tab, modifiers: [], keyDownHandler: {
            Task.startUnstructured { @MainActor in selectNextDropOption() }
        })
    } else if !enabled, let hotKey = nextOptionHotKey {
        hotKey.isEnabled = false
        nextOptionHotKey = nil
    }
}

/// Decides what the drop can mean, based on where the windows are now
@MainActor
private func findDropOptions(_ window: Window, at point: CGPoint) -> DropOptions? {
    let monitor = point.monitorApproximation
    let workspace = monitor.activeWorkspace
    let isFloating = window.parent is FloatingWindowsContainer
    let snapEdge = screenEdge(near: point, monitor)
    // Near the screen edge, the cursor might be outside of every tile (menu bar, Dock, outer gaps)
    let probe = snapEdge == nil ? point : point.clamped(to: monitor.visibleRectPaddedByOuterGaps)
    if let targetWindow = probe.findWindowRecursively(in: workspace.rootTilingContainer, virtual: false, fullscreenCoversAll: false, excluding: window),
       targetWindow != window,
       let rect = targetWindow.stackOrSelf.lastAppliedLayoutPhysicalRect
    {
        var zone = snapEdge.map { .split($0) } ?? dropZone(for: point, in: rect)
        // Floating windows are tiled only via the edge zones. The center keeps them floating
        if isFloating && zone == .stack { return nil }
        // Swapping with a window of another workspace would need to preview two workspaces at once
        if zone == .stack && NSEvent.modifierFlags.contains(.option) && window.nodeWorkspace == workspace { zone = .swap }
        let key = DropOptions.Key(targetWindowId: targetWindow.windowId, zone: zone, snapsToScreen: snapEdge != nil)
        guard case .split(let direction) = zone else {
            return DropOptions(key: key, options: [(PendingDrop(window: window, workspace: workspace, op: .tile(targetWindowId: targetWindow.windowId, zone)), nil)], defaultIndex: 0)
        }
        var options: [(drop: PendingDrop, group: DropPreview.Group?)] = []
        var layouts: [String] = []
        for (level, group) in splitGroups(targetWindow.stackOrSelf, direction).enumerated() {
            let drop = PendingDrop(window: window, workspace: workspace, op: .tile(targetWindowId: targetWindow.windowId, zone, level: level))
            guard let sim = simulate(drop) else { continue }
            layout(sim, workspace)
            let signature = sim.layoutSignature
            if layouts.contains(signature) { continue }
            layouts.append(signature)
            options.append((drop, group))
        }
        return DropOptions(key: key, options: options, defaultIndex: snapEdge != nil ? options.count - 1 : 0)
    }
    // Floating windows moved to another monitor stay floating
    if !isFloating && workspace != window.nodeWorkspace && workspace.rootTilingContainer.allLeafWindowsRecursive.isEmpty {
        return DropOptions(key: nil, options: [(PendingDrop(window: window, workspace: workspace, op: .intoEmptyWorkspace), nil)], defaultIndex: 0)
    }
    return nil
}

/// The tile (nil) and every group whose `direction` edge is the tile's edge, innermost first
@MainActor
private func splitGroups(_ tile: TreeNode, _ direction: CardinalDirection) -> [DropPreview.Group?] {
    var result: [DropPreview.Group?] = [nil]
    guard let tileRect = tile.lastAppliedLayoutPhysicalRect else { return result }
    var node = tile
    while let parent = node.parent as? TilingContainer, let parentRect = parent.lastAppliedLayoutPhysicalRect,
          abs(parentRect.edge(direction) - tileRect.edge(direction)) < 2
    {
        result.append(parent.isRootContainer ? .screen : parent.orientation == .h ? .row : .column)
        node = parent
    }
    return result
}

@MainActor
private func screenEdge(near point: CGPoint, _ monitor: any MonitorInfo) -> CardinalDirection? {
    let visible = monitor.visibleRect
    let screen = monitor.rect
    let edges: [(toVisible: CGFloat, toScreen: CGFloat, CardinalDirection)] = [
        (point.x - visible.minX, point.x - screen.minX, .left),
        (visible.maxX - point.x, screen.maxX - point.x, .right),
        (point.y - visible.minY, point.y - screen.minY, .up),
        (visible.maxY - point.y, screen.maxY - point.y, .down),
    ]
    guard let nearest = edges.min(by: { $0.toVisible < $1.toVisible }) else { return nil }
    // Outside of the visible rect means the menu bar or the Dock
    return nearest.toVisible < 0 || nearest.toScreen < screenEdgeSnapDistance ? nearest.2 : nil
}

@MainActor
private func layout(_ sim: SimNode, _ workspace: Workspace) {
    let monitor = workspace.workspaceMonitor
    sim.layout(monitor.visibleRectPaddedByOuterGaps, innerGaps: ResolvedGaps(gaps: config.gaps, monitor: monitor).inner)
}

/// Lays out the simulated result. Draws where every window ends up, not where the cursor is
@MainActor
private func previewDrop(_ drop: PendingDrop, group: DropPreview.Group?, optionIndex: Int, optionCount: Int) -> DropPreview? {
    guard let sim = simulate(drop) else { return nil }
    layout(sim, drop.workspace)
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
        case .tile(let targetWindowId, let zone, _):
            targetName = Window.get(byId: targetWindowId)?.app.name
            action = switch zone {
                case .stack: .stack
                case .swap: .swap
                case .split(let direction): .split(direction, group)
            }
    }
    let monitor = drop.workspace.workspaceMonitor
    var originRect: Rect? = nil
    if let origin = dragSession?.origin, origin.workspace == drop.workspace, !origin.rect.isClose(to: landingRect) {
        originRect = origin.rect
    }
    return DropPreview(
        action: action,
        targetName: targetName,
        monitorRect: monitor.rect.cgRect,
        originRect: originRect?.cgRect,
        landingRect: landingRect.cgRect,
        landingStackCount: landingTile.allWindows.count,
        ghosts: ghosts,
        optionIndex: optionIndex,
        optionCount: optionCount,
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
        case .tile(let targetWindowId, let zone, let level):
            guard let target = sim.window(targetWindowId), target !== dragged else { return nil }
            switch zone {
                case .stack:
                    stackWindow(dragged, onto: target.stackOrSelf)
                case .swap:
                    guard dragged.parent != nil else { return nil }
                    swapWindows(dragged, target)
                case .split(let direction):
                    var tile = target.stackOrSelf
                    for _ in 0 ..< level {
                        guard let parent = tile.parent, parent.isContainer else { return nil }
                        tile = parent
                    }
                    splitTile(tile, with: dragged, direction)
            }
    }
    sim.normalizeContainers()
    return sim
}

/// Hides the preview and returns the drop that should be applied on mouse up, if any
@MainActor
func takePendingDrop() -> PendingDrop? {
    DropZoneOverlay.shared.hide()
    setNextOptionHotKeyEnabled(false)
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

    /// Two drops with the same signature produce the same layout
    fileprivate var layoutSignature: String {
        allWindows
            .map { window in
                let rect = window.rect.orDie()
                return "\(window.windowId.orDie()):\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))"
            }
            .sorted()
            .joined(separator: ";")
    }
}

extension Rect {
    fileprivate func isClose(to other: Rect) -> Bool {
        abs(minX - other.minX) < 2 && abs(minY - other.minY) < 2 && abs(width - other.width) < 2 && abs(height - other.height) < 2
    }

    fileprivate func edge(_ direction: CardinalDirection) -> CGFloat {
        switch direction {
            case .left: minX
            case .right: maxX
            case .up: minY
            case .down: maxY
        }
    }
}

extension CGPoint {
    fileprivate func clamped(to rect: Rect) -> CGPoint {
        CGPoint(x: min(max(x, rect.minX + 1), rect.maxX - 1), y: min(max(y, rect.minY + 1), rect.maxY - 1))
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

/// Splits the space of `target` (a tile or a whole group) in half and puts `window` on the `direction` side.
/// Other tiles keep their sizes
@MainActor
private func splitTile(_ target: SimNode, with window: SimNode, _ direction: CardinalDirection) {
    if window.parent != nil { window.unbind() }
    guard let parent = target.parent else { return }
    if target.orientation == direction.orientation && target.layout == .tiles {
        // A group laid out along the split direction: the window joins it at the edge and takes half of it
        let total = target.children.map(\.weight).reduce(0, +)
        window.bind(to: target, weight: total, index: direction.isPositive ? INDEX_BIND_LAST : 0)
    } else if parent.orientation == direction.orientation && parent.layout == .tiles {
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
