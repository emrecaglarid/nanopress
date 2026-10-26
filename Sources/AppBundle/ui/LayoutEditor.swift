import AppKit
import Common
import SwiftUI

/// A map of the focused workspace in the menu panel, for rearranging windows without reaching for their title bars.
/// Drag a tile onto another to swap them (⌥ stacks instead) or onto its edge to split it, drag a gap to resize.
/// Like a real drag, the screen previews the result while dragging, and the windows move on release. Dropping a
/// window on a workspace chip in the panel header (see WorkspaceChips) moves it to that workspace
@MainActor
struct LayoutEditor: View {
    let workspace: Workspace
    let width: CGFloat
    /// Redraws the map when the layout changes
    let revision: Int

    @State private var drag: EditorDrag? = nil
    /// The map's view in the panel, to find where it is on screen
    @State private var anchor = ViewAnchor()

    private static let space = "layoutMap"

    var body: some View {
        map(mapState(drag))
            .background(AnchorView(anchor: anchor))
        .onChange(of: drag != nil) { isDragging in
            if !isDragging { endFloating() }
        }
        .onDisappear { endFloating() }
    }

    private func map(_ state: LayoutMapState) -> some View {
        ZStack(alignment: .topLeading) {
            LayoutMapCanvas(state: state, drag: drag, isFloating: false)
            ForEach(state.tiles) { tile in
                tileHandle(tile, state: state)
            }
            ForEach(state.tiles) { tile in
                behindHandles(tile, state: state)
            }
            ForEach(state.dividers) { divider in
                dividerView(divider, map: state.map)
            }
            ForEach(mapJunctions(state.dividers)) { junction in
                junctionView(junction, map: state.map)
            }
        }
        .frame(width: state.map.size.width, height: state.map.size.height, alignment: .topLeading)
        .coordinateSpace(name: Self.space)
    }

    private func mapState(_ drag: EditorDrag?) -> LayoutMapState {
        // The part of the screen windows can use: the menu bar and the Dock would be empty bands
        let monitorRect = workspace.workspaceMonitor.visibleRect.cgRect
        let scale = width / max(monitorRect.width, 1)
        let size = CGSize(width: width, height: (monitorRect.height * scale).rounded())
        let sim = drag?.resizedSim ?? SimNode.snapshot(workspace)
        let tiles = arrangedTiles(sim, on: workspace)
        let dividers = mapDividers(sim.rootContainer)
        var labels: [SizeLabel] = []
        if case .resize(let ids, _, _) = drag {
            labels = dividers.filter { ids.contains($0.id) }.flatMap { sizeLabels($0, sim) }
        }
        return LayoutMapState(
            tiles: tiles,
            dividers: dividers,
            labels: labels,
            map: MapGeometry(monitorRect: monitorRect, scale: scale, size: size),
        )
    }

    // MARK: Floating while dragging

    /// The panel can't be made see-through, so while dragging it's hidden and the map is drawn in a window of its own
    /// at the same place, with the workspace chips where they are in the header. The drag keeps going to the hidden panel
    private func updateDrag(_ newDrag: EditorDrag) {
        drag = newDrag
        guard let window = anchor.view?.window, let mapFrame = anchor.screenFrame else { return }
        window.alphaValue = 0
        let chipsFrame = WorkspaceChipRow.shared.anchor.screenFrame
        let frame = chipsFrame.map { mapFrame.union($0) } ?? mapFrame
        // Top-left offsets within `frame`, which is in AppKit coordinates
        func offset(_ rect: CGRect) -> CGSize { CGSize(width: rect.minX - frame.minX, height: frame.maxY - rect.maxY) }
        let canvas = EditorCanvas(
            state: mapState(newDrag),
            drag: newDrag,
            size: frame.size,
            mapOffset: offset(mapFrame),
            chipsOffset: chipsFrame.map(offset),
        )
        FloatingMap.shared.show(canvas, frame: frame)
    }

    private func endFloating() {
        FloatingMap.shared.hide()
        anchor.view?.window?.alphaValue = 1
    }

    // MARK: Workspaces

    private func move(_ windowId: UInt32, to target: Workspace) {
        guard let token: RunSessionGuard = .isServerEnabled else { return }
        Task.startUnstructured {
            try await runLightSession(.menuBarButton, token) {
                guard let window = Window.get(byId: windowId) else { return }
                moveWindow(window, to: target)
            }
        }
    }

    // MARK: Tiles

    private func tileHandle(_ tile: ArrangedTile, state: LayoutMapState) -> some View {
        let rect = state.map.local(tile.rect).insetBy(dx: 1.5, dy: 1.5)
        return Color.clear
            .frame(width: max(rect.width, 0), height: max(rect.height, 0))
            .contentShape(Rectangle())
            .offset(x: rect.minX, y: rect.minY)
            .gesture(
                tileDrag(tile.id, state: state),
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tile.stackCount > 1 ? "\(tile.name), stack of \(tile.stackCount)" : tile.name)
    }

    /// Dragging a window out of the map. It's the window on top of a tile, or one stacked behind it
    private func tileDrag(_ windowId: UInt32, state: LayoutMapState) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
            .onChanged { value in
                let target = tileTarget(dragging: windowId, at: value.location, state: state)
                updateDrag(.tile(windowId: windowId, translation: value.translation, target: target))
                if case .map(let target)? = target, let preview = previewDrop(target.drop, group: target.group, optionIndex: 0, optionCount: 1) {
                    DropZoneOverlay.shared.show(preview)
                } else {
                    DropZoneOverlay.shared.hide()
                }
            }
            .onEnded { _ in
                DropZoneOverlay.shared.hide()
                switch drag {
                    case .tile(_, _, .map(let target)?): apply(target.drop)
                    case .tile(let windowId, _, .workspace(let target)?): move(windowId, to: target)
                    default: break
                }
                drag = nil
            }
    }

    /// The tabs of a stack, like the tab bar above the real one. Click one to bring its window forward, drag it to take
    /// the window out
    @ViewBuilder
    private func behindHandles(_ tile: ArrangedTile, state: LayoutMapState) -> some View {
        let rect = state.map.local(tile.rect).insetBy(dx: 1.5, dy: 1.5)
        if let (_, tabs) = mapTabs(tile, size: rect.size) {
            ForEach(tabs) { tab in
                if let windowId = tab.windowId {
                    let name = Window.get(byId: windowId)?.app.name ?? "Window"
                    MapTabHandle(isFront: tab.isFront)
                        .frame(width: tab.rect.width, height: tab.rect.height)
                        .offset(x: rect.minX + tab.rect.minX, y: rect.minY + tab.rect.minY)
                        .onTapGesture { if !tab.isFront { bringForward(windowId) } }
                        .gesture(tileDrag(windowId, state: state))
                        .help(tab.isFront ? "\(name), in front. Drag to move it" : "\(name). Click to bring it forward, drag to move it")
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(tab.isFront ? "\(name), in front" : name)
                        .accessibilityAddTraits(tab.isFront ? [.isButton, .isSelected] : .isButton)
                }
            }
        }
    }

    private func bringForward(_ windowId: UInt32) {
        guard let token: RunSessionGuard = .isServerEnabled else { return }
        Task.startUnstructured {
            try await runLightSession(.menuBarButton, token) { _ = Window.get(byId: windowId)?.focusWindow() }
        }
    }

    /// Above the map is the workspace strip. Its own workspace and the space between the small maps take nothing
    private func tileTarget(dragging windowId: UInt32, at location: CGPoint, state: LayoutMapState) -> TileTarget? {
        if let mapFrame = anchor.screenFrame {
            let point = CGPoint(x: mapFrame.minX + location.x, y: mapFrame.maxY - location.y)
            if let target = WorkspaceChipRow.shared.workspace(at: point) {
                return target == workspace ? nil : .workspace(target)
            }
        }
        return dropTarget(dragging: windowId, at: location, tiles: state.tiles, map: state.map).map(TileTarget.map)
    }

    /// Same zones as a real drag, except that the center swaps: on a map, dropping a tile onto another reads as
    /// trading places. Near the edge of the map, the window splits the whole screen
    private func dropTarget(dragging windowId: UInt32, at location: CGPoint, tiles: [ArrangedTile], map: MapGeometry) -> MapDropTarget? {
        guard let window = Window.get(byId: windowId) else { return nil }
        let edge = map.edge(near: location)
        let probe = map.real(map.clamped(location))
        guard let tile = tiles.first(where: { $0.rect.contains(probe) }) else { return nil }
        // A window can split its own stack, to come out next to it. Any window of a stack stands for the whole stack
        let isOwnTile = tile.windowIds.contains(windowId)
        guard let targetId = tile.windowIds.first(where: { $0 != windowId }) else { return nil }
        let tileRect = Rect(topLeftX: tile.rect.minX, topLeftY: tile.rect.minY, width: tile.rect.width, height: tile.rect.height)
        let zone: DropZone
        var level = 0
        var highlight = map.local(tile.rect)
        if let edge {
            zone = .split(edge)
            level = levelsToRoot(targetId)
            let area = workspace.workspaceMonitor.visibleRectPaddedByOuterGaps.cgRect
            highlight = map.local(area).half(edge)
        } else {
            switch dropZone(for: probe, in: tileRect) {
                case .split(let direction):
                    zone = .split(direction)
                    highlight = highlight.half(direction)
                default:
                    if isOwnTile { return nil }
                    zone = NSEvent.modifierFlags.contains(.option) ? .stack : .swap
            }
        }
        let drop = PendingDrop(window: window, workspace: workspace, op: .tile(targetWindowId: targetId, zone, level: level))
        guard simulate(drop) != nil else { return nil }
        return MapDropTarget(drop: drop, group: level > 0 ? .screen : nil, highlight: highlight)
    }

    /// The level of a split that takes the whole screen. See DropOp.tile
    private func levelsToRoot(_ windowId: UInt32) -> Int {
        guard var node = SimNode.snapshot(workspace).window(windowId)?.stackOrSelf else { return 0 }
        var level = 0
        while let parent = node.parent, parent.isContainer {
            level += 1
            node = parent
        }
        return level
    }

    private func apply(_ drop: PendingDrop) {
        guard let token: RunSessionGuard = .isServerEnabled else { return }
        Task.startUnstructured {
            try await runLightSession(.menuBarButton, token) { applyDrop(drop) }
        }
    }

    // MARK: Resizing

    private func dividerView(_ divider: MapDivider, map: MapGeometry) -> some View {
        let isActive = if case .resize(let ids, _, _) = drag, ids.contains(divider.id) { true } else { false }
        return DividerHandle(divider: divider, map: map, isActive: isActive)
            .onTapGesture(count: 2) { evenOutDivider(divider, in: workspace) }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
                    .onChanged { value in
                        let delta = divider.orientation == .h ? value.translation.width : value.translation.height
                        resize([(divider, delta / map.scale)], map: map)
                    }
                    .onEnded { _ in endResize([divider]) },
            )
    }

    /// Where a column gap meets a row gap: dragging it resizes both at once
    private func junctionView(_ junction: MapJunction, map: MapGeometry) -> some View {
        let isActive = if case .resize(let ids, _, _) = drag, ids == junction.dividerIds { true } else { false }
        return JunctionHandle(junction: junction, map: map, isActive: isActive)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
                    .onChanged { value in
                        resize([
                            (junction.columns, value.translation.width / map.scale),
                            (junction.rows, value.translation.height / map.scale),
                        ], map: map)
                    }
                    .onEnded { _ in endResize([junction.columns, junction.rows]) },
            )
    }

    private func resize(_ moves: [(MapDivider, CGFloat)], map: MapGeometry) {
        let sim = SimNode.snapshot(workspace)
        _ = arrangedTiles(sim, on: workspace) // Lays it out, so that weights are sizes in points
        var snaps: [CGFloat?] = []
        for (divider, delta) in moves {
            snaps.append(resizeDivider(divider, by: delta, in: sim))
        }
        // A tap on the trackpad whenever the gap clicks into a new fraction
        if case .resize(_, _, let previous) = drag, previous != snaps, snaps.contains(where: { $0 != nil }) {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        updateDrag(.resize(ids: moves.map(\.0.id), sim: sim, snaps: snaps))
        DropZoneOverlay.shared.showArrangement(arrangedTiles(sim, on: workspace), monitorRect: map.monitorRect)
    }

    private func endResize(_ dividers: [MapDivider]) {
        DropZoneOverlay.shared.hide()
        if case .resize(_, let sim, _) = drag { applyDividerResize(dividers, from: sim, in: workspace) }
        drag = nil
    }

    /// The size of the two tiles or groups next to `divider`, as a share of their group
    private func sizeLabels(_ divider: MapDivider, _ sim: SimNode) -> [SizeLabel] {
        guard let container = sim.rootContainer.descendant(at: divider.path) else { return [] }
        let total = container.children.map(\.weight).reduce(0, +)
        guard total > 0 else { return [] }
        return [divider.index, divider.index + 1].compactMap { index in
            guard container.children.indices.contains(index), let rect = container.children[index].rect else { return nil }
            return SizeLabel(id: "\(divider.id)/\(index)", rect: rect.cgRect, text: fractionText(container.children[index].weight / total))
        }
    }
}

// MARK: Resizing, shared with GapHandles

/// Moves `divider` by `delta` points in `sim`, which must be laid out. Neither neighbour gets smaller than a usable
/// minimum, and near a half, third or quarter of the group the gap snaps to it. Returns the fraction it snapped to
@MainActor
func resizeDivider(_ divider: MapDivider, by delta: CGFloat, in sim: SimNode) -> CGFloat? {
    guard let container = sim.rootContainer.descendant(at: divider.path),
          container.children.indices.contains(divider.index + 1) else { return nil }
    let before = container.children[divider.index]
    let after = container.children[divider.index + 1]
    let minimum: CGFloat = 240
    var clamped = min(max(delta, min(0, minimum - before.weight)), max(0, after.weight - minimum))
    let total = container.children.map(\.weight).reduce(0, +)
    let start = container.children.prefix(divider.index).map(\.weight).reduce(0, +)
    var snapped: CGFloat? = nil
    if total > 0 {
        let fraction = (start + before.weight + clamped) / total
        if let target = snapFractions.min(by: { abs($0 - fraction) < abs($1 - fraction) }), abs(target - fraction) * total < 32 {
            let snappedDelta = target * total - start - before.weight
            if before.weight + snappedDelta >= minimum && after.weight - snappedDelta >= minimum {
                clamped = snappedDelta
                snapped = target
            }
        }
    }
    before.weight += clamped
    after.weight -= clamped
    return snapped
}

/// Double-clicking a gap gives every tile of its group the same size
@MainActor
func evenOutDivider(_ divider: MapDivider, in workspace: Workspace) {
    guard let token: RunSessionGuard = .isServerEnabled else { return }
    Task.startUnstructured {
        try await runLightSession(.menuBarButton, token) {
            guard let container = realContainer(at: divider.path, in: workspace) else { return }
            let weights = container.children.map { $0.getWeight(container.orientation) }
            let even = weights.reduce(0, +) / CGFloat(max(weights.count, 1))
            for child in container.children { child.setWeight(container.orientation, even) }
        }
    }
}

/// Gives the real tree the sizes that `sim` got by resizing `dividers`
@MainActor
func applyDividerResize(_ dividers: [MapDivider], from sim: SimNode, in workspace: Workspace) {
    guard let token: RunSessionGuard = .isServerEnabled else { return }
    var changes: [(path: [Int], index: Int, weights: (CGFloat, CGFloat))] = []
    for divider in dividers {
        guard let simContainer = sim.rootContainer.descendant(at: divider.path),
              simContainer.children.indices.contains(divider.index + 1) else { continue }
        changes.append((divider.path, divider.index, (simContainer.children[divider.index].weight, simContainer.children[divider.index + 1].weight)))
    }
    Task.startUnstructured {
        try await runLightSession(.menuBarButton, token) {
            for change in changes {
                guard let container = realContainer(at: change.path, in: workspace),
                      container.children.indices.contains(change.index + 1) else { continue }
                container.children[change.index].setWeight(container.orientation, change.weights.0)
                container.children[change.index + 1].setWeight(container.orientation, change.weights.1)
            }
        }
    }
}

private let snapFractions: [CGFloat] = [1 / 4, 1 / 3, 1 / 2, 2 / 3, 3 / 4]

/// ½ and ⅓ read faster than 50% and 33%
private func fractionText(_ fraction: CGFloat) -> String {
    let names: [(CGFloat, String)] = [(1 / 4, "¼"), (1 / 3, "⅓"), (1 / 2, "½"), (2 / 3, "⅔"), (3 / 4, "¾")]
    if let name = names.first(where: { abs($0.0 - fraction) < 0.002 }) { return name.1 }
    return "\(Int((fraction * 100).rounded()))%"
}

@MainActor
func realContainer(at path: [Int], in workspace: Workspace) -> TilingContainer? {
    var node: TreeNode = workspace.rootTilingContainer
    for index in path {
        guard node.children.indices.contains(index) else { return nil }
        node = node.children[index]
    }
    return node as? TilingContainer
}

private struct LayoutMapState {
    let tiles: [ArrangedTile]
    let dividers: [MapDivider]
    /// While resizing, the share each resized tile gets
    let labels: [SizeLabel]
    let map: MapGeometry
}

/// What the floating window shows while dragging: the workspace strip and the map, where they are in the panel
private struct EditorCanvas: View {
    let state: LayoutMapState
    let drag: EditorDrag?
    let size: CGSize
    let mapOffset: CGSize
    let chipsOffset: CGSize?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let chipsOffset {
                WorkspaceChipsRow(current: focus.workspace, target: dropWorkspace, isFloating: true)
                    .offset(chipsOffset)
            }
            LayoutMapCanvas(state: state, drag: drag, isFloating: true)
                .offset(mapOffset)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private var dropWorkspace: Workspace? {
        if case .tile(_, _, .workspace(let target)?) = drag { target } else { nil }
    }
}

private struct SizeLabel: Identifiable {
    let id: String
    /// In screen coordinates
    let rect: CGRect
    let text: String
}

/// What the map looks like. Drawn in the panel, and in FloatingMap while dragging
private struct LayoutMapCanvas: View {
    let state: LayoutMapState
    let drag: EditorDrag?
    /// On its own over the screen, the map needs a background that reads over any window
    let isFloating: Bool

    var body: some View {
        let map = state.map
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isFloating ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(Color.primary.opacity(0.04)))
                .frame(width: map.size.width, height: map.size.height)
                .shadow(color: .black.opacity(isFloating ? 0.3 : 0), radius: 16, y: 6)
            if state.tiles.isEmpty {
                Text("No windows on this workspace")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: map.size.width, height: map.size.height)
            }
            ForEach(state.tiles) { tile in
                let rect = map.local(tile.rect).insetBy(dx: 1.5, dy: 1.5)
                if let remaining = tile.removing(draggedWindowId) {
                    MapTile(tile: remaining, size: rect.size, style: .normal)
                        .offset(x: rect.minX, y: rect.minY)
                } else {
                    MapTile(tile: tile, size: rect.size, style: .origin)
                        .offset(x: rect.minX, y: rect.minY)
                }
            }
            if case .tile(_, _, .map(let target)?) = drag {
                let highlight = target.highlight.insetBy(dx: 1.5, dy: 1.5)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.accentColor.opacity(0.25))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 1.5))
                    .frame(width: highlight.width, height: highlight.height)
                    .offset(x: highlight.minX, y: highlight.minY)
            }
            if case .resize(let ids, _, _) = drag {
                ForEach(state.dividers.filter { ids.contains($0.id) }) { divider in
                    DividerLine(divider: divider, map: map)
                }
                ForEach(state.labels) { label in
                    let rect = map.local(label.rect)
                    Text(label.text)
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
                        .position(x: rect.midX, y: rect.midY)
                }
            }
            if case .tile(let windowId, let translation, _) = drag, let tile = state.tiles.first(where: { $0.windowIds.contains(windowId) }) {
                // Only the dragged window comes along. The rest of its stack stays
                let lifted = ArrangedTile(id: windowId, rect: tile.rect, name: Window.get(byId: windowId)?.app.name ?? "Window", behind: [])
                let rect = map.local(tile.rect).insetBy(dx: 1.5, dy: 1.5)
                MapTile(tile: lifted, size: rect.size, style: .lifted)
                    .offset(x: rect.minX + translation.width, y: rect.minY + translation.height)
            }
        }
        .frame(width: map.size.width, height: map.size.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private var draggedWindowId: UInt32? {
        if case .tile(let windowId, _, _) = drag { windowId } else { nil }
    }
}

extension ArrangedTile {
    /// The top window first
    var windowIds: [UInt32] { [id] + behind }

    /// The tile without `windowId`: the next window comes to the top when it's the top one. Nil when nothing is left
    @MainActor fileprivate func removing(_ windowId: UInt32?) -> ArrangedTile? {
        guard let windowId, windowIds.contains(windowId) else { return self }
        let rest = windowIds.filter { $0 != windowId }
        guard let top = rest.first else { return nil }
        let name = top == id ? name : Window.get(byId: top)?.app.name ?? "Window"
        return ArrangedTile(id: top, rect: rect, name: name, behind: Array(rest.dropFirst()), stackOrder: stackOrder.filter { $0 != windowId })
    }
}

// MARK: Stacked windows

private let mapTabHeight: CGFloat = 18
private let mapTabMinimum: CGFloat = 24
private let mapTabGap: CGFloat = 2
/// Around the bar inside the tile, and around the tabs inside the bar
private let mapTabInset: CGFloat = 3
private let mapBarPadding: CGFloat = 2

/// A window of a stack, as a tab in a bar along the top of its tile
private struct MapTab: Identifiable {
    /// Nil for the tab that counts the windows that didn't fit
    let windowId: UInt32?
    let overflow: Int
    let isFront: Bool
    /// Relative to the tile
    let rect: CGRect

    var id: String { windowId.map { "\($0)" } ?? "more" }
}

/// The bar and its tabs, in the stack's order. The window in front always gets a tab. Nil when the tile isn't a stack,
/// or has no room for the bar
@MainActor
private func mapTabs(_ tile: ArrangedTile, size: CGSize) -> (bar: CGRect, tabs: [MapTab])? {
    guard tile.stackCount > 1, size.height >= 56, size.width >= 2 * mapTabMinimum + 2 * (mapTabInset + mapBarPadding) else { return nil }
    let order = tile.stackOrder.isEmpty ? tile.windowIds : tile.stackOrder
    // On the same side as the real tabs
    let barHeight = mapTabHeight + 2 * mapBarPadding
    let barY = NanopressSettings.shared.tabsPosition == .top ? mapTabInset : size.height - mapTabInset - barHeight
    let bar = CGRect(x: mapTabInset, y: barY, width: size.width - 2 * mapTabInset, height: barHeight)
    let inner = bar.insetBy(dx: mapBarPadding, dy: mapBarPadding)
    let fit = max(Int((inner.width + mapTabGap) / (mapTabMinimum + mapTabGap)), 2)
    var shown = order.count <= fit ? order : Array(order.prefix(fit - 1))
    if !shown.contains(tile.id), let last = shown.indices.last { shown[last] = tile.id }
    let overflow = order.count - shown.count
    let count = shown.count + (overflow > 0 ? 1 : 0)
    let width = min((inner.width - mapTabGap * CGFloat(count - 1)) / CGFloat(count), 130)
    let tabs = (0 ..< count).map { index in
        let windowId = shown.getOrNil(atIndex: index)
        let rect = CGRect(x: inner.minX + CGFloat(index) * (width + mapTabGap), y: inner.minY, width: width, height: inner.height)
        return MapTab(windowId: windowId, overflow: overflow, isFront: windowId == tile.id, rect: rect)
    }
    return (bar, tabs)
}

/// Over a tab in the map, which draws it. Shows that the tab can be clicked
private struct MapTabHandle: View {
    let isFront: Bool
    @State private var isHovered = false

    var body: some View {
        Capsule()
            .fill(Color.primary.opacity(isHovered && !isFront ? 0.05 : 0))
            .contentShape(Capsule())
            .onHover { isHovered = $0 }
    }
}

/// A borderless window above the menu panel that shows the map while the panel is hidden
@MainActor
private final class FloatingMap {
    static let shared = FloatingMap()

    /// Room for the map's shadow
    private let margin: CGFloat = 32
    private let hostingView = NSHostingView(rootView: AnyView(EmptyView()))
    private lazy var panel: NSPanel = {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.contentView = hostingView
        return panel
    }()

    private init() {}

    /// `frame` is the map's frame in AppKit screen coordinates
    func show(_ canvas: some View, frame: CGRect) {
        hostingView.rootView = AnyView(canvas.padding(margin))
        panel.setFrame(frame.insetBy(dx: -margin, dy: -margin), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}

/// Holds an AppKit view placed in a SwiftUI hierarchy
@MainActor
private final class ViewAnchor {
    weak var view: NSView? = nil

    var screenFrame: CGRect? {
        guard let view, let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}

private struct AnchorView: NSViewRepresentable {
    let anchor: ViewAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        anchor.view = view
    }
}

private enum EditorDrag {
    case tile(windowId: UInt32, translation: CGSize, target: TileTarget?)
    /// `snaps` holds the fraction each divider snapped to, nil where it didn't
    case resize(ids: [String], sim: SimNode, snaps: [CGFloat?])

    var resizedSim: SimNode? { if case .resize(_, let sim, _) = self { sim } else { nil } }
}

private enum TileTarget {
    case map(MapDropTarget)
    /// Moves the window to another workspace
    case workspace(Workspace)
}

private struct MapDropTarget {
    let drop: PendingDrop
    let group: DropPreview.Group?
    /// Where the window goes, on the map
    let highlight: CGRect
}

/// Converts between the screen and the map
private struct MapGeometry {
    let monitorRect: CGRect
    let scale: CGFloat
    let size: CGSize

    func local(_ rect: CGRect) -> CGRect {
        CGRect(
            x: (rect.minX - monitorRect.minX) * scale,
            y: (rect.minY - monitorRect.minY) * scale,
            width: rect.width * scale,
            height: rect.height * scale,
        )
    }

    func real(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x / scale + monitorRect.minX, y: point.y / scale + monitorRect.minY)
    }

    func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 1), size.width - 1), y: min(max(point.y, 1), size.height - 1))
    }

    /// The edge of the map the point is on or past
    func edge(near point: CGPoint) -> CardinalDirection? {
        let snap: CGFloat = 6
        let distances: [(CGFloat, CardinalDirection)] = [
            (point.x, .left), (size.width - point.x, .right), (point.y, .up), (size.height - point.y, .down),
        ]
        guard let nearest = distances.min(by: { $0.0 < $1.0 }), nearest.0 < snap else { return nil }
        return nearest.1
    }
}

/// The gap between two neighbouring children of a tiles container
struct MapDivider: Identifiable {
    /// Child indices from the root container down to the container
    let path: [Int]
    /// Between the children at `index` and `index + 1`
    let index: Int
    let orientation: Orientation
    /// Along `orientation`, in screen coordinates
    let position: CGFloat
    /// Across `orientation`, in screen coordinates
    let crossStart: CGFloat
    let crossEnd: CGFloat

    var id: String { path.map(String.init).joined(separator: ".") + ":\(index)" }
}

/// `node` must be laid out
@MainActor
func mapDividers(_ node: SimNode, path: [Int] = []) -> [MapDivider] {
    var result: [MapDivider] = []
    if let orientation = node.orientation, node.layout == .tiles, let rect = node.rect {
        for index in node.children.indices.dropLast() {
            guard let a = node.children[index].rect, let b = node.children[index + 1].rect else { continue }
            result.append(MapDivider(
                path: path,
                index: index,
                orientation: orientation,
                position: orientation == .h ? (a.maxX + b.minX) / 2 : (a.maxY + b.minY) / 2,
                crossStart: orientation == .h ? rect.minY : rect.minX,
                crossEnd: orientation == .h ? rect.maxY : rect.maxX,
            ))
        }
    }
    for (index, child) in node.children.enumerated() where child.isContainer {
        result += mapDividers(child, path: path + [index])
    }
    return result
}

extension SimNode {
    func descendant(at path: [Int]) -> SimNode? {
        var node = self
        for index in path {
            guard node.children.indices.contains(index) else { return nil }
            node = node.children[index]
        }
        return node
    }
}

/// Where a divider sits on the map
private struct DividerPlacement {
    let isHorizontal: Bool
    /// Along the divider's orientation
    let position: CGFloat
    /// Across it
    let start: CGFloat
    let length: CGFloat

    init(_ divider: MapDivider, _ map: MapGeometry) {
        isHorizontal = divider.orientation == .h
        position = isHorizontal
            ? (divider.position - map.monitorRect.minX) * map.scale
            : (divider.position - map.monitorRect.minY) * map.scale
        start = (divider.crossStart - (isHorizontal ? map.monitorRect.minY : map.monitorRect.minX)) * map.scale
        length = (divider.crossEnd - divider.crossStart) * map.scale
    }

    /// A strip `thickness` wide centered on the divider
    func frame(thickness: CGFloat) -> CGRect {
        isHorizontal
            ? CGRect(x: position - thickness / 2, y: start, width: thickness, height: length)
            : CGRect(x: start, y: position - thickness / 2, width: length, height: thickness)
    }
}

/// The accent line on a divider that's hovered or dragged
private struct DividerLine: View {
    let divider: MapDivider
    let map: MapGeometry

    var body: some View {
        let placement = DividerPlacement(divider, map)
        let frame = placement.frame(thickness: 3).insetBy(dx: placement.isHorizontal ? 0 : 4, dy: placement.isHorizontal ? 4 : 0)
        Capsule()
            .fill(Color.accentColor)
            .frame(width: max(frame.width, 0), height: max(frame.height, 0))
            .offset(x: frame.minX, y: frame.minY)
    }
}

/// A gap between tiles. A grip in its middle shows that it can be dragged
private struct DividerHandle: View {
    let divider: MapDivider
    let map: MapGeometry
    let isActive: Bool
    @State private var isHovered = false

    /// Wider than the gap it sits in, so it's easy to grab
    private let hitWidth: CGFloat = 10

    var body: some View {
        let placement = DividerPlacement(divider, map)
        let frame = placement.frame(thickness: hitWidth)
        ZStack(alignment: .topLeading) {
            if isHovered || isActive {
                DividerLine(divider: divider, map: map)
            } else {
                Grip(isHorizontal: placement.isHorizontal)
                    .position(x: frame.midX, y: frame.midY)
            }
            Color.clear
                .frame(width: frame.width, height: frame.height)
                .contentShape(Rectangle())
                .offset(x: frame.minX, y: frame.minY)
                .onHover { hovering in
                    isHovered = hovering
                    if hovering {
                        (placement.isHorizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .help("Drag to resize, double-click to even out")
                .accessibilityLabel(placement.isHorizontal ? "Resize columns" : "Resize rows")
        }
    }
}

/// A short pill across a gap
private struct Grip: View {
    let isHorizontal: Bool

    var body: some View {
        Capsule()
            .fill(Color.primary.opacity(0.35))
            .overlay(Capsule().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
            .frame(width: isHorizontal ? 6 : 22, height: isHorizontal ? 22 : 6)
    }
}

/// A column gap and a row gap that ends on it, T-shaped
struct MapJunction: Identifiable {
    /// The gap between columns
    let columns: MapDivider
    /// The gap between rows
    let rows: MapDivider

    var id: String { columns.id + "+" + rows.id }
    var dividerIds: [String] { [columns.id, rows.id] }
    /// In screen coordinates
    var point: CGPoint { CGPoint(x: columns.position, y: rows.position) }
}

func mapJunctions(_ dividers: [MapDivider]) -> [MapJunction] {
    let columns = dividers.filter { $0.orientation == .h }
    let rows = dividers.filter { $0.orientation == .v }
    var result: [MapJunction] = []
    for column in columns {
        for row in rows where row.position > column.crossStart && row.position < column.crossEnd {
            // The row gap starts or ends at the column gap
            if abs(row.crossStart - column.position) < 16 || abs(row.crossEnd - column.position) < 16 {
                result.append(MapJunction(columns: column, rows: row))
            }
        }
    }
    return result
}

private struct JunctionHandle: View {
    let junction: MapJunction
    let map: MapGeometry
    let isActive: Bool
    @State private var isHovered = false

    private let size: CGFloat = 14

    var body: some View {
        let point = map.local(CGRect(origin: junction.point, size: .zero)).origin
        Circle()
            .fill(isHovered || isActive ? Color.accentColor : Color.primary.opacity(0.35))
            .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
            .frame(width: isHovered || isActive ? 10 : 8, height: isHovered || isActive ? 10 : 8)
            .frame(width: size, height: size)
            .contentShape(Circle())
            .onHover { hovering in
                isHovered = hovering
                if hovering {
                    junctionCursor.push()
                } else {
                    NSCursor.pop()
                }
            }
            .help("Drag to resize both ways")
            .accessibilityLabel("Resize columns and rows")
            .position(x: point.x, y: point.y)
    }
}

@MainActor private var junctionCursor: NSCursor {
    if #available(macOS 15, *) {
        NSCursor.frameResize(position: .bottomRight, directions: .all)
    } else {
        NSCursor.crosshair
    }
}

private struct MapTile: View {
    enum Style {
        case normal
        /// The empty slot of the tile being dragged
        case origin
        /// The copy that follows the cursor
        case lifted
    }

    let tile: ArrangedTile
    let size: CGSize
    let style: Style

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        let iconSize = min(32, (min(size.width, size.height) - 8).rounded(.down))
        ZStack {
            switch style {
                case .normal:
                    // A fill alone: the map is the one raised surface, and outlines on every tile read as noise
                    shape.fill(Color.primary.opacity(0.09))
                case .origin:
                    shape.fill(Color.accentColor.opacity(0.04))
                    shape.strokeBorder(Color.accentColor.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                case .lifted:
                    // See-through, so that the layout under it stays readable
                    shape.fill(Color.accentColor.opacity(0.15))
                    shape.strokeBorder(Color.accentColor, lineWidth: 1.5)
            }
            let stack = style == .origin ? nil : mapTabs(tile, size: size)
            if style != .origin {
                let barRoom = stack.map { $0.bar.height + mapTabInset } ?? 0
                let isBarOnTop = NanopressSettings.shared.tabsPosition == .top
                let bodyHeight = size.height - barRoom
                VStack(spacing: 4) {
                    AppIcon(windowId: tile.id, size: min(iconSize, (bodyHeight - 8).rounded(.down)))
                    if bodyHeight >= 64 && size.width >= 60 {
                        Text(tile.name)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(isBarOnTop ? .top : .bottom, barRoom)
            }
            if let (_, tabs) = stack {
                // Straight on the tile: a bar around them would be one box too many
                ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                    // Like the real tabs: round at the ends of the block, nearly square between tabs
                    MapTabView(tab: tab, shape: TabShape(leading: index == 0 ? 6 : 2, trailing: index == tabs.count - 1 ? 6 : 2))
                        .frame(width: tab.rect.width, height: tab.rect.height)
                        .position(x: tab.rect.midX, y: tab.rect.midY)
                }
            } else if tile.stackCount > 1 && style != .origin {
                Text("\(tile.stackCount)")
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .frame(height: 16)
                    .background(Color.primary.opacity(0.08), in: Capsule())
                    .padding(4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .frame(width: max(size.width, 0), height: max(size.height, 0))
        .opacity(style == .lifted ? 0.75 : 1)
        .contentShape(shape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tile.stackCount > 1 ? "\(tile.name), stack of \(tile.stackCount)" : tile.name)
    }
}

private struct MapTabView: View {
    let tab: MapTab
    let shape: TabShape

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 4) {
                if let windowId = tab.windowId {
                    AppIcon(windowId: windowId, size: 12)
                    if geometry.size.width >= 56 {
                        Text(Window.get(byId: windowId)?.app.name ?? "Window")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(tab.isFront ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                            .lineLimit(1)
                    }
                } else {
                    Text("+\(tab.overflow)")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: geometry.size.width >= 56 ? .leading : .center)
        }
        .background(tab.isFront ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06), in: shape)
    }
}

extension CGRect {
    /// The half on the `direction` side
    fileprivate func half(_ direction: CardinalDirection) -> CGRect {
        switch direction {
            case .left: CGRect(x: minX, y: minY, width: width / 2, height: height)
            case .right: CGRect(x: midX, y: minY, width: width / 2, height: height)
            case .up: CGRect(x: minX, y: minY, width: width, height: height / 2)
            case .down: CGRect(x: minX, y: midY, width: width, height: height / 2)
        }
    }
}

// MARK: Workspace chips

/// Where the chips in the panel header are, so that a window dragged on the map can be dropped on one
@MainActor
final class WorkspaceChipRow {
    static let shared = WorkspaceChipRow()
    fileprivate let anchor = ViewAnchor()

    static let chipSize = CGSize(width: 34, height: 22)
    static let gap: CGFloat = 6

    private init() {}

    /// `point` is in AppKit screen coordinates. A little past the edges still counts, so that a chip is easy to hit
    fileprivate func workspace(at point: CGPoint) -> Workspace? {
        guard let row = anchor.screenFrame else { return nil }
        for (index, workspace) in Workspace.all.enumerated() {
            let chip = CGRect(x: row.minX + CGFloat(index) * (Self.chipSize.width + Self.gap), y: row.minY, width: Self.chipSize.width, height: Self.chipSize.height)
            if chip.insetBy(dx: -4, dy: -4).contains(point) { return workspace }
        }
        return nil
    }
}

/// Every workspace as a small numbered chip, for the panel header. Click one to switch, drop a window on one from the
/// map to move it there
struct WorkspaceChips: View {
    /// Redraws the chips when windows move
    let revision: Int

    var body: some View {
        WorkspaceChipsRow(current: focus.workspace, target: nil, isFloating: false)
            .background(AnchorView(anchor: WorkspaceChipRow.shared.anchor))
    }
}

private struct WorkspaceChipsRow: View {
    let current: Workspace
    /// A window is dragged over it
    let target: Workspace?
    /// Drawn over the screen while dragging
    let isFloating: Bool

    var body: some View {
        HStack(spacing: WorkspaceChipRow.gap) {
            ForEach(Workspace.all, id: \.name) { workspace in
                WorkspaceChip(workspace: workspace, isCurrent: workspace == current, isTarget: workspace == target, isInteractive: !isFloating)
            }
        }
        .background {
            if isFloating {
                Capsule().fill(.regularMaterial).padding(-5)
            }
        }
    }
}

private struct WorkspaceChip: View {
    let workspace: Workspace
    let isCurrent: Bool
    let isTarget: Bool
    let isInteractive: Bool
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        let isEmpty = workspace.isEffectivelyEmpty
        let isAccent = isCurrent || isTarget
        Button(action: focusWorkspace) {
            Text(workspace.name)
                .font(.system(size: 11, weight: isAccent ? .semibold : .medium))
                .foregroundStyle(isAccent ? AnyShapeStyle(Color.accentColor) : isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                .frame(width: WorkspaceChipRow.chipSize.width, height: WorkspaceChipRow.chipSize.height)
                .background(fill, in: shape)
                .overlay {
                    if isAccent {
                        shape.strokeBorder(Color.accentColor, lineWidth: 1.5)
                    } else if isEmpty {
                        shape.strokeBorder(Color.primary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    } else {
                        shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                    }
                }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(!isInteractive)
        .onHover { isHovered = $0 }
        .help(isCurrent ? "Drop a window from the map on another workspace to move it there" : "Click to switch, drop a window from the map here to move it")
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }

    private var fill: AnyShapeStyle {
        if isTarget { return AnyShapeStyle(Color.accentColor.opacity(0.2)) }
        if workspace.isEffectivelyEmpty { return AnyShapeStyle(Color.primary.opacity(isHovered ? 0.05 : 0)) }
        return AnyShapeStyle(Color.primary.opacity(isHovered ? 0.1 : 0.05))
    }

    private var accessibilityLabel: String {
        var apps: [String] = []
        for name in workspace.allLeafWindowsRecursive.compactMap(\.app.name) where !apps.contains(name) { apps.append(name) }
        return "Workspace \(workspace.name), " + (apps.isEmpty ? "empty" : apps.joined(separator: ", "))
    }

    private func focusWorkspace() {
        guard let token: RunSessionGuard = .isServerEnabled else { return }
        let workspace = workspace
        Task.startUnstructured {
            try await runLightSession(.menuBarButton, token) { _ = workspace.focusWorkspace() }
        }
    }
}
