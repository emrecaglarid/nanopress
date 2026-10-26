import AppKit
import Common

/// "Arrange": rebuilds a workspace so that the `count` most recently used windows each get a tile and the rest are
/// stacked under the least recent of them. Column widths follow what each app is good at (see preferredWidth(of:)).
///
/// The result is a SimNode, like a drop, so the menu can preview it exactly before it's applied
@MainActor
func arrangement(of workspace: Workspace, showing count: Int) -> SimNode? {
    arrangements(of: workspace, showing: count, limit: 1).first
}

/// The `limit` best shapes for showing `count` windows, best fit first
@MainActor
func arrangements(of workspace: Workspace, showing count: Int, limit: Int) -> [SimNode] {
    let windows = windowsByRecency(workspace.rootTilingContainer)
    guard !windows.isEmpty, count >= 1 else { return [] }
    let shown = Array(windows.prefix(count))
    let overflow = Array(windows.dropFirst(count))
    let area = workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
    return arrangeShapes(shown, area: area)
        .prefix(limit)
        .map { buildArrangement($0, shown: shown, overflow: overflow, area: area) }
}

@MainActor
private func buildArrangement(_ columns: [[Window]], shown: [Window], overflow: [Window], area: Rect) -> SimNode {
    let widths = columnWidths(columns, area: area)

    let sim = SimNode(.workspace)
    let root = SimNode(.container(.h, .tiles))
    root.bind(to: sim, weight: 1, index: INDEX_BIND_LAST)
    var nodes: [UInt32: SimNode] = [:]
    for (column, width) in zip(columns, widths) {
        let parent: SimNode
        if column.count == 1 {
            parent = root
        } else {
            parent = SimNode(.container(.v, .tiles))
            parent.bind(to: root, weight: width, index: INDEX_BIND_LAST)
        }
        for window in column {
            let isStackTarget = window === shown.last && !overflow.isEmpty
            let weight = column.count == 1 ? width : area.height / CGFloat(column.count)
            let tile: SimNode
            if isStackTarget {
                tile = SimNode(.container(parent.orientation == .h ? .v : .h, .accordion))
                tile.bind(to: parent, weight: weight, index: INDEX_BIND_LAST)
                for hidden in overflow { SimNode(.window(hidden.windowId)).bind(to: tile, weight: 1, index: INDEX_BIND_LAST) }
                let node = SimNode(.window(window.windowId))
                node.bind(to: tile, weight: 1, index: 0)
                nodes[window.windowId] = node
            } else {
                let node = SimNode(.window(window.windowId))
                node.bind(to: parent, weight: weight, index: INDEX_BIND_LAST)
                nodes[window.windowId] = node
            }
        }
    }
    // Recency is kept: the least recent first, so that the most recent ends up on top
    for window in shown.reversed() { nodes[window.windowId]?.markAsMostRecentChild() }
    sim.normalizeContainers()
    return sim
}

@MainActor
func applyArrangement(_ sim: SimNode, to workspace: Workspace) {
    var windows: [UInt32: Window] = [:]
    for window in workspace.rootTilingContainer.allLeafWindowsRecursive { windows[window.windowId] = window }
    sim.materialize(into: workspace, windows: windows)
}

/// The window counts worth offering for `workspace`
@MainActor
func arrangeCounts(of workspace: Workspace) -> [Int] {
    let count = workspace.rootTilingContainer.allLeafWindowsRecursive.count
    return count == 0 ? [] : Array(1 ... min(count, tileCapacity(of: workspace.workspaceMonitor)))
}

/// How many tiles fit on `monitor` before windows get too small to use: 640 x 540 points each. A laptop screen fits
/// 2 side by side, a 1080p display 3, a 27" display 4 x 2. Windows past that are stacked
@MainActor
func tileCapacity(of monitor: any MonitorInfo) -> Int {
    let area = monitor.visibleRectPaddedByOuterGaps
    return min(max(Int(area.width / 640), 1) * max(Int(area.height / 540), 1), 9)
}

/// Most recently used first. Follows the MRU stack of every container, so the window on top of a stack counts as
/// more recent than the windows below it
@MainActor
func windowsByRecency(_ node: TreeNode) -> [Window] {
    if let window = node as? Window { return [window] }
    let mru = Array(node.mruChildren)
    let ordered = mru + node.children.filter { child in !mru.contains { $0 === child } }
    return ordered.flatMap(windowsByRecency)
}

/// Every sensible way to split the shown windows into columns, best fit first. Windows are dealt row by row, so
/// recency reads left to right, top to bottom. The most recent window always comes first
@MainActor
private func arrangeShapes(_ shown: [Window], area: Rect) -> [[[Window]]] {
    let n = shown.count
    guard n > 1 else { return [[shown]] }
    var candidates: [[[Int]]] = []
    // Grids, including a single row of columns
    for columnCount in 2 ... min(n, 6) {
        candidates.append(deal(Array(0 ..< n), into: columnCount))
    }
    // The main window on its own, the rest in one to three columns next to it
    for sideColumns in 1 ... min(n - 1, 3) {
        candidates.append([[0]] + deal(Array(1 ..< n), into: sideColumns))
    }
    var seen: [[[Int]]] = []
    let unique = candidates.filter { candidate in
        if seen.contains(candidate) { return false }
        seen.append(candidate)
        return true
    }
    let scored = unique.map { candidate in
        let columns = candidate.map { $0.map { shown[$0] } }
        return (columns, misfit(columns, area: area))
    }
    // Stable, so that on a tie the shape generated first (the simpler one) wins
    return scored.enumerated()
        .sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }
        .map(\.element.0)
}

/// Deals `items` into `count` columns row by row: [0 1 2 3 4] into 2 is [[0 2 4] [1 3]]
private func deal(_ items: [Int], into count: Int) -> [[Int]] {
    var columns = Array(repeating: [Int](), count: count)
    for (i, item) in items.enumerated() { columns[i % count].append(item) }
    return columns.filter { !$0.isEmpty }
}

/// How badly the tiles of `columns` fit their windows. 0 is a perfect fit. Too narrow for the app is the worst,
/// then too tall (a window much taller than wide wastes its bottom), then too wide
@MainActor
private func misfit(_ columns: [[Window]], area: Rect) -> CGFloat {
    let widths = columnWidths(columns, area: area)
    var result: CGFloat = 0
    for (columnIndex, (column, width)) in zip(columns, widths).enumerated() {
        let height = area.height / CGFloat(column.count)
        for window in column {
            let preferred = preferredWidth(of: window)
            let tooNarrow = max(0, preferred * 0.75 - width) / preferred * 3
            let tooTall = max(0, height / width - 1.2)
            let tooWide = max(0, width / height - 2.4)
            // Even on a big screen, a tile can get too small to be useful
            let tooSmall = max(0, 480 - min(width, height)) / 480 * 3
            // The main window matters most
            result += (tooNarrow + tooTall + tooWide + tooSmall) * (columnIndex == 0 && column.count == 1 ? 1.5 : 1)
        }
    }
    return result
}

/// Splits the width in proportion to what each column wants. The first column is the main one and gets a bit more.
/// The widths add up to exactly `area.width`, so that layoutTiles doesn't redistribute them
@MainActor
private func columnWidths(_ columns: [[Window]], area: Rect) -> [CGFloat] {
    var wanted = columns.map { column in column.map(preferredWidth(of:)).max() ?? 1 }
    if wanted.count > 1 { wanted[0] *= 1.2 }
    let minimum = area.width * 0.15
    let total = wanted.reduce(0, +)
    var widths = wanted.map { max($0 / total * area.width, minimum) }
    let scale = area.width / widths.reduce(0, +)
    widths = widths.map { $0 * scale }
    return widths
}

// MARK: Preferred widths

/// How wide a window of this app likes to be, in points. What the user picked by resizing wins, then the kind of app
@MainActor
func preferredWidth(of window: Window) -> CGFloat {
    guard let bundleId = window.app.rawAppBundleId else { return defaultPreferredWidth }
    if let learned = NanopressSettings.shared.learnedWidths[bundleId] { return learned }
    if let width = preferredWidthByBundleId[bundleId] { return width }
    return appCategory(of: window).flatMap { preferredWidthByCategory[$0] } ?? defaultPreferredWidth
}

private let defaultPreferredWidth: CGFloat = 900

/// Apps that don't declare a category, or whose category says little about the shape they want
private let preferredWidthByBundleId: [String: CGFloat] = [
    "company.thebrowser.dia": 1200,
    "company.thebrowser.Browser": 1200,
    "com.apple.Safari": 1200,
    "com.google.Chrome": 1200,
    "org.mozilla.firefox": 1200,
    "com.mitchellh.ghostty": 800,
    "com.apple.Terminal": 800,
    "com.googlecode.iterm2": 800,
    "com.tinyspeck.slackmacgap": 560,
    "com.apple.MobileSMS": 520,
    "com.spotify.client": 700,
]

/// LSApplicationCategoryType from the app's Info.plist
private let preferredWidthByCategory: [String: CGFloat] = [
    "public.app-category.social-networking": 520,
    "public.app-category.business": 600,
    "public.app-category.developer-tools": 1100,
    "public.app-category.graphics-design": 1400,
    "public.app-category.photography": 1300,
    "public.app-category.video": 1300,
    "public.app-category.productivity": 900,
    "public.app-category.music": 700,
    "public.app-category.utilities": 700,
]

@MainActor private var appCategoryCache: [String: String?] = [:]

@MainActor
private func appCategory(of window: Window) -> String? {
    guard let macApp = (window as? MacWindow)?.macApp, let bundleId = macApp.rawAppBundleId else { return nil }
    if let cached = appCategoryCache[bundleId] { return cached }
    let category = macApp.nsApp.bundleURL
        .flatMap { Bundle(url: $0)?.infoDictionary?["LSApplicationCategoryType"] as? String }
    appCategoryCache[bundleId] = category
    return category
}

// MARK: Placement of new windows

/// A new window splits the biggest tile on the workspace along its longer side: 1 window, 2 side by side, then a
/// 2 + 1 split and so on. Windows the user already arranged keep their place. Once the screen is full (see
/// tileCapacity(of:)), it goes on top of the least recent tile instead, like Arrange does with the windows that don't
/// get a tile. Nil falls back to AeroSpace's placement
@MainActor
func bindingDataForNewWindowSplittingBiggestTile(_ workspace: Workspace, app bundleId: String? = nil) -> BindingData? {
    // Most recent first, so that of tiles about the same size, the one being worked in is split
    let tiles = windowsByRecency(workspace.rootTilingContainer).map(\.stackOrSelf).uniqueByIdentity()
    if tiles.count >= tileCapacity(of: workspace.workspaceMonitor), let leastRecent = tiles.last {
        return bindingDataStacking(onto: leastRecent)
    }
    let sized = tiles.compactMap { tile in tile.lastAppliedLayoutPhysicalRect.map { (tile, $0) } }
    let maxArea = sized.map { $0.1.width * $0.1.height }.max() ?? 0
    guard sized.count == tiles.count, var (tile, rect) = sized.first(where: { $0.1.width * $0.1.height >= maxArea * 0.95 }) else {
        return nil
    }
    var orientation: Orientation = rect.width >= rect.height ? .h : .v
    var after = true
    // An app goes back where the user last put it, unless the tile there is too small to split
    if let bundleId, let place = NanopressSettings.shared.place(of: bundleId) {
        let area = workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
        let point = CGPoint(x: area.minX + place.x * area.width, y: area.minY + place.y * area.height)
        if let (placeTile, placeRect) = sized.first(where: { $0.1.cgRect.contains(point) }), placeRect.width * placeRect.height >= maxArea * 0.4 {
            (tile, rect) = (placeTile, placeRect)
            orientation = rect.width >= rect.height ? .h : .v
            after = orientation == .h ? point.x >= rect.center.x : point.y >= rect.center.y
        }
    }
    guard let parent = tile.parent as? TilingContainer, let index = tile.ownIndex else { return nil }
    if parent.orientation == orientation && parent.layout == .tiles {
        let half = tile.getWeight(orientation) / 2
        tile.setWeight(orientation, half)
        return BindingData(parent: parent, adaptiveWeight: half, index: after ? index + 1 : index)
    }
    let weight = tile.getWeight(parent.orientation)
    let container = TilingContainer(parent: parent, adaptiveWeight: weight, orientation, .tiles, index: index)
    _ = tile.bind(to: container, adaptiveWeight: 1, index: 0)
    return BindingData(parent: container, adaptiveWeight: 1, index: after ? INDEX_BIND_LAST : 0)
}

/// Moves a window to another workspace, where it goes like a new window would
@MainActor
func moveWindow(_ window: Window, to workspace: Workspace) {
    if window.isFloating {
        window.bindAsFloatingWindow(to: workspace)
        return
    }
    let data = bindingDataForNewWindowSplittingBiggestTile(workspace, app: window.app.rawAppBundleId)
        ?? BindingData(parent: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    window.bind(to: data.parent, adaptiveWeight: data.adaptiveWeight, index: data.index)
}

/// The window a new window was stacked on because the screen was full, so that the new window can say so. See
/// MacWindow.getOrRegister
@MainActor var lastPlacementStackedOn: Window? = nil

@MainActor
private func bindingDataStacking(onto tile: TreeNode) -> BindingData? {
    lastPlacementStackedOn = tile.mostRecentWindowRecursive
    if let stack = tile as? TilingContainer, stack.layout == .accordion {
        stack.isOverflowStack = true
        return BindingData(parent: stack, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    }
    guard let parent = tile.parent as? TilingContainer, let index = tile.ownIndex else { return nil }
    let stack = TilingContainer(parent: parent, adaptiveWeight: tile.getWeight(parent.orientation), parent.orientation.opposite, .accordion, index: index)
    stack.isOverflowStack = true
    _ = tile.bind(to: stack, adaptiveWeight: 1, index: 0)
    return BindingData(parent: stack, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
}

/// Once a window closes or leaves, a window stacked because the screen was full gets a tile again: the most recent one
/// behind a stack, so that what was hidden comes back first. Stacks made on purpose (a drop, Arrange) stay as they are
@MainActor
func unstackWhereThereIsRoom(_ workspace: Workspace) {
    var before: SimNode? = nil
    var unstacked: [UInt32] = []
    defer {
        if let before, let last = unstacked.last {
            offerUndo("\(windowNames(unstacked)) got \(unstacked.count == 1 ? "its" : "their") tile back", workspace: workspace, before: before, near: last)
        }
    }
    while true {
        let tiles = windowsByRecency(workspace.rootTilingContainer).map(\.stackOrSelf).uniqueByIdentity()
        guard tiles.count < tileCapacity(of: workspace.workspaceMonitor),
              let stack = tiles.lazy.compactMap({ $0 as? TilingContainer }).first(where: { $0.isOverflowStack && $0.children.count > 1 }),
              let window = windowsByRecency(stack).dropFirst().first
        else { return }
        if before == nil { before = SimNode.snapshot(workspace) }
        unstacked.append(window.windowId)
        window.unbindFromParent()
        let data = bindingDataForNewWindowSplittingBiggestTile(workspace, app: window.app.rawAppBundleId)
            ?? BindingData(parent: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        window.bind(to: data.parent, adaptiveWeight: data.adaptiveWeight, index: data.index)
        workspace.normalizeContainers()
    }
}

extension Array where Element: AnyObject {
    func uniqueByIdentity() -> [Element] {
        var seen: [ObjectIdentifier] = []
        return filter { element in
            let id = ObjectIdentifier(element)
            if seen.contains(id) { return false }
            seen.append(id)
            return true
        }
    }
}

// MARK: Preview

/// A tile of an arrangement, laid out on its monitor. Stacks are one tile, named after the window on top
struct ArrangedTile: Equatable, Identifiable {
    let id: UInt32
    let rect: CGRect
    let name: String
    /// The windows stacked behind the one on top, most recent first
    let behind: [UInt32]
    /// Every window of a stack in the stack's order, which tabs follow. Empty when not known
    var stackOrder: [UInt32] = []

    var stackCount: Int { behind.count + 1 }
}

@MainActor
func arrangedTiles(_ sim: SimNode, on workspace: Workspace) -> [ArrangedTile] {
    let monitor = workspace.workspaceMonitor
    sim.layout(monitor.visibleRectPaddedByOuterGaps, innerGaps: ResolvedGaps(gaps: effectiveGaps(on: monitor), monitor: monitor).inner)
    var seen: [ObjectIdentifier] = []
    var result: [ArrangedTile] = []
    for simWindow in sim.allWindows {
        let tile = simWindow.stackOrSelf
        if seen.contains(ObjectIdentifier(tile)) { continue }
        seen.append(ObjectIdentifier(tile))
        guard let rect = tile.rect, let topId = tile.mostRecentWindowRecursive?.windowId else { continue }
        result.append(ArrangedTile(
            id: topId,
            rect: rect.cgRect,
            name: Window.get(byId: topId)?.app.name ?? "Window",
            behind: tile.windowsByRecency.compactMap(\.windowId).filter { $0 != topId },
            stackOrder: tile.allWindows.compactMap(\.windowId),
        ))
    }
    return result
}
