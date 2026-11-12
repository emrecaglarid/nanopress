@testable import AppBundle
import Common
import XCTest

/// Throws seeded random sequences of what users and macOS do at the window tree, and checks after every step that
/// nothing is lost or broken. A failure prints its seed: set `LayoutFuzzTest.onlySeed` to replay it.
///
/// The regular test run tries a few dozen sequences. For a long soak: `NANOPRESS_FUZZ_SEEDS=2000 swift test --filter LayoutFuzzTest`
///
/// What it checks (see checkInvariants):
/// - Every open window is in the tree exactly once, so it can't disappear
/// - The tree is well formed: parents know their children, no empty groups, weights are positive
/// - After a layout, every tiled window has a frame on screen, and tiles don't overlap
/// - A drop does exactly what its preview showed, and the refresh's normalization doesn't change it afterwards
@MainActor
final class LayoutFuzzTest: XCTestCase {
    /// Set to replay one failing seed
    static let onlySeed: UInt64? = nil
    static let seeds: UInt64 = ProcessInfo.processInfo.environment["NANOPRESS_FUZZ_SEEDS"].flatMap(UInt64.init) ?? 40
    static let steps = 80

    override func setUp() async throws {
        setUpWorkspacesForTests()
        // The app's defaults, not the simplified ones of the other layout tests: the real normalizations run here
        config.enableNormalizationFlattenContainers = true
        config.enableNormalizationOppositeOrientationForNestedContainers = true
    }

    func testRandomSequencesKeepEveryWindow() async throws {
        let seeds = Self.onlySeed.map { [$0] } ?? Array(0 ..< Self.seeds)
        for seed in seeds {
            setUpWorkspacesForTests()
            config.enableNormalizationFlattenContainers = true
            config.enableNormalizationOppositeOrientationForNestedContainers = true
            // The app draws tabs above a stack instead (see layoutAccordion). The padding only exists in tests, and would
            // make narrow stacks negative here when they aren't in the app
            config.accordionPadding = 0
            var run = FuzzRun(seed: seed)
            if let failure = await run.go(steps: Self.steps) {
                XCTFail(failure)
                return // One failure at a time: the first one is the clearest
            }
        }
    }
}

@MainActor
private struct FuzzRun {
    let seed: UInt64
    var rng: SeededGenerator
    var log: [String] = []
    var nextId: UInt32 = 1
    /// Windows that are open, by id. Everything else must not be in the tree
    var open: [UInt32: TestWindow] = [:]
    /// Layouts saved earlier in the run, to restore later like a display switch does
    var savedLayouts: [SavedLayout] = []
    /// Undo points, like the notes that offer to undo a change
    var undoPoints: [(workspace: Workspace, before: SimNode)] = []
    /// Set by drop() when the result isn't what the preview showed
    var previewMismatch: String? = nil
    /// How thin each window's tile was before the last drop. A drop must not squeeze one below what anyone can use
    var thicknessBeforeDrop: [UInt32: CGFloat]? = nil

    let main: Workspace
    let other: Workspace

    init(seed: UInt64) {
        self.seed = seed
        rng = SeededGenerator(seed: seed)
        main = focus.workspace
        other = Workspace.get(byName: "fuzz-other")
    }

    mutating func go(steps: Int) async -> String? {
        for step in 0 ..< steps {
            let description = await randomStep()
            log.append("\(step): \(description)")
            // What every refresh does after a change
            for workspace in [main, other] { workspace.normalizeContainers() }
            unstackWhereThereIsRoom(main)
            for workspace in [main, other] { try? await workspace.layoutWorkspace() }
            log.append("   = \(shape(main.rootTilingContainer))")
            if let before = thicknessBeforeDrop {
                thicknessBeforeDrop = nil
                let squeezed = tileThickness(main).filter { id, thickness in thickness < 119 && (before[id] ?? .infinity) > thickness + 2 }
                if !squeezed.isEmpty { return report("the drop squeezed \(squeezed.keys.sorted()) into a tile too thin to use") }
            }
            if let problem = checkInvariants() {
                return report(problem)
            }
        }
        return nil
    }

    func report(_ problem: String) -> String {
        """
        Seed \(seed): \(problem)
        Steps:
        \(log.suffix(12).joined(separator: "\n"))
        Main: \(shape(main.rootTilingContainer)) floating \(main.floatingWindows.map(\.windowId))
        Other: \(shape(other.rootTilingContainer)) floating \(other.floatingWindows.map(\.windowId))
        """
    }

    // MARK: Steps

    mutating func randomStep() async -> String {
        let tiled = main.rootTilingContainer.allLeafWindowsRecursive
        let roll = Int.random(in: 0 ..< 100, using: &rng)
        switch roll {
            case 0 ..< 22: return openWindow(floating: Int.random(in: 0 ..< 5, using: &rng) == 0)
            case 22 ..< 34: return closeWindow()
            case 34 ..< 60 where tiled.count >= 2 || !main.floatingWindows.isEmpty: return drop()
            case 60 ..< 66: return arrange()
            case 66 ..< 72: return pullOut()
            case 72 ..< 78: return moveToOtherWorkspace()
            case 78 ..< 84: return toggleFloating()
            case 84 ..< 90: return saveOrRestoreLayout()
            case 90 ..< 95: return undoOrRecord()
            default: return openWindow(floating: false)
        }
    }

    /// Like MacWindow.getOrRegister, for a window that gets a tile right away
    mutating func openWindow(floating: Bool) -> String {
        let id = nextId
        nextId += 1
        let workspace = Bool.random(using: &rng) || Int.random(in: 0 ..< 4, using: &rng) > 0 ? main : other
        let window = TestWindow.new(id: id, parent: workspace.floatingWindowsContainer)
        open[id] = window
        if floating { return "open \(id) floating on \(workspace.name)" }
        window.unbindFromParent()
        let data = bindingDataForNewWindowSplittingBiggestTile(workspace, app: window.app.rawAppBundleId)
            ?? BindingData(parent: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        window.bind(to: data.parent, adaptiveWeight: data.adaptiveWeight, index: data.index)
        return "open \(id) on \(workspace.name)"
    }

    mutating func closeWindow() -> String {
        guard let window = randomOpenWindow() else { return "close: nothing open" }
        window.closeAxWindow()
        TestApp.shared.windows.removeAll { $0 == window }
        open[window.windowId] = nil
        return "close \(window.windowId)"
    }

    /// A drop like the mouse makes, checked against its own preview
    mutating func drop() -> String {
        let tiled = main.rootTilingContainer.allLeafWindowsRecursive
        let candidates = tiled + main.floatingWindows
        guard let dragged = candidates.randomElement(using: &rng),
              let target = tiled.filter({ $0 != dragged }).randomElement(using: &rng) else { return "drop: no target" }
        let zones: [DropZone] = [.stack, .swap, .split(.left), .split(.right), .split(.up), .split(.down)]
        let zone = zones.randomElement(using: &rng)!
        let level = Int.random(in: 0 ..< 3, using: &rng)
        let drop = PendingDrop(window: dragged, workspace: main, op: .tile(targetWindowId: target.windowId, zone, level: level))
        let description = "drop \(dragged.windowId)\(dragged.isFloating ? " (floating)" : "") on \(target.windowId) \(zone) level \(level)"
        guard let preview = simulate(drop) else { return "\(description): no preview" }
        thicknessBeforeDrop = tileThickness(main)
        applyDrop(drop)
        // The preview must be what happened
        let expected = shape(preview.rootContainer)
        let actual = shape(main.rootTilingContainer)
        if expected != actual {
            previewMismatch = "preview \(expected)\n   but got \(actual)"
        }
        return description
    }

    mutating func arrange() -> String {
        let counts = arrangeCounts(of: main)
        guard let count = counts.randomElement(using: &rng), let sim = arrangement(of: main, showing: count) else { return "arrange: no options" }
        applyArrangement(sim, to: main)
        return "arrange showing \(count)"
    }

    /// Shrinking a stacked window from its free edge takes it out of the stack. See resizeWithMouse
    mutating func pullOut() -> String {
        let stacked = main.rootTilingContainer.allLeafWindowsRecursive.filter {
            ($0.parent as? TilingContainer)?.layout == .accordion && ($0.parent?.children.count ?? 0) > 1
        }
        guard let window = stacked.randomElement(using: &rng) else { return "pull out: no stack" }
        let side = [CardinalDirection.left, .right, .up, .down].randomElement(using: &rng)!
        let sim = SimNode.snapshot(main)
        guard pullOutOfStack(window.windowId, toward: side, share: 0.3, in: sim) else { return "pull out \(window.windowId): refused" }
        var windows: [UInt32: Window] = [:]
        for window in main.rootTilingContainer.allLeafWindowsRecursive { windows[window.windowId] = window }
        sim.materialize(into: main, windows: windows)
        return "pull \(window.windowId) out of its stack to the \(side)"
    }

    mutating func moveToOtherWorkspace() -> String {
        guard let window = randomOpenWindow(), let from = window.nodeWorkspace else { return "move: nothing open" }
        let to = from == main ? other : main
        moveWindow(window, to: to)
        return "move \(window.windowId) to \(to.name)"
    }

    mutating func toggleFloating() -> String {
        guard let window = randomOpenWindow(), let workspace = window.nodeWorkspace else { return "float: nothing open" }
        if window.isFloating {
            window.unbindFromParent()
            let data = bindingDataForNewWindowSplittingBiggestTile(workspace, app: window.app.rawAppBundleId)
                ?? BindingData(parent: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
            window.bind(to: data.parent, adaptiveWeight: data.adaptiveWeight, index: data.index)
            return "tile \(window.windowId)"
        }
        window.bindAsFloatingWindow(to: workspace)
        return "float \(window.windowId)"
    }

    /// Displays switching back and forth restore a layout saved a while ago, with windows opened and closed since
    mutating func saveOrRestoreLayout() -> String {
        if savedLayouts.isEmpty || Bool.random(using: &rng) {
            savedLayouts.append(SavedLayout.current)
            return "save layout #\(savedLayouts.count - 1)"
        }
        let index = Int.random(in: 0 ..< savedLayouts.count, using: &rng)
        applySavedLayout(savedLayouts[index])
        return "restore layout #\(index)"
    }

    mutating func undoOrRecord() -> String {
        if undoPoints.isEmpty || Bool.random(using: &rng) {
            let workspace = Bool.random(using: &rng) ? main : other
            undoPoints.append((workspace, SimNode.snapshot(workspace)))
            return "record undo point on \(workspace.name)"
        }
        let point = undoPoints.remove(at: Int.random(in: 0 ..< undoPoints.count, using: &rng))
        restoreLayout(point.before, into: point.workspace)
        return "undo on \(point.workspace.name)"
    }

    mutating func randomOpenWindow() -> TestWindow? {
        open.values.sorted { $0.windowId < $1.windowId }.randomElement(using: &rng)
    }

    // MARK: Invariants

    func checkInvariants() -> String? {
        if let previewMismatch { return "a drop didn't do what its preview showed:\n   \(previewMismatch)" }
        // Every open window is in the tree exactly once, and nothing else is
        var seen: [UInt32: Int] = [:]
        for workspace in Workspace.all {
            for window in workspace.allLeafWindowsRecursive { seen[window.windowId, default: 0] += 1 }
        }
        for (id, count) in seen where count > 1 { return "window \(id) is in the tree \(count) times" }
        for id in open.keys where seen[id] == nil { return "window \(id) is open but in no workspace: it disappeared" }
        for id in seen.keys where open[id] == nil { return "window \(id) was closed but is still in the tree" }

        for workspace in [main, other] {
            if let problem = checkTree(workspace.rootTilingContainer) { return "\(workspace.name): \(problem)" }
            if let problem = checkFrames(workspace) { return "\(workspace.name): \(problem)" }
        }
        return nil
    }

    func checkTree(_ container: TilingContainer) -> String? {
        if !container.isRootContainer && container.children.isEmpty { return "an empty group is left in the tree" }
        if container.layout == .accordion, (container.parent as? TilingContainer)?.layout == .accordion {
            return "a stack is inside another stack"
        }
        if let mru = container.mostRecentChild, !container.children.contains(where: { $0 === mru }) {
            return "the most recent child of a group isn't one of its children"
        }
        for child in container.children {
            if child.parent !== container { return "a child doesn't point back at its group" }
            let weight = child.getWeight(container.orientation)
            if !weight.isFinite || weight <= 0 { return "a weight is \(weight)" }
            if let group = child as? TilingContainer, let problem = checkTree(group) { return problem }
        }
        return nil
    }

    /// The smaller side of each window's tile, for tiles in a row or column. See stackSlivers
    func tileThickness(_ workspace: Workspace) -> [UInt32: CGFloat] {
        var result: [UInt32: CGFloat] = [:]
        for tile in windowsByRecency(workspace.rootTilingContainer).map(\.stackOrSelf).uniqueByIdentity() {
            guard (tile.parent as? TilingContainer)?.layout == .tiles, let rect = tile.lastAppliedLayoutPhysicalRect else { continue }
            for window in tile.allLeafWindowsRecursive { result[window.windowId] = min(rect.width, rect.height) }
        }
        return result
    }

    func checkFrames(_ workspace: Workspace) -> String? {
        let screen = workspace.workspaceMonitor.visibleRect
        let root = workspace.rootTilingContainer
        // A stack at the root is one tile on screen, though drops treat its windows one by one. See stackOrSelf
        let tiles: [TreeNode] = root.layout == .accordion && !root.children.isEmpty
            ? [root]
            : windowsByRecency(root).map(\.stackOrSelf).uniqueByIdentity()
        var rects: [(UInt32, Rect)] = []
        for tile in tiles {
            guard let window = tile.mostRecentWindowRecursive else { return "a tile has no window" }
            guard let rect = window.lastAppliedLayoutPhysicalRect else { return "window \(window.windowId) got no frame" }
            if rect.width < 1 || rect.height < 1 { return "window \(window.windowId) is \(rect.width)x\(rect.height)" }
            if rect.minX < screen.minX - 1 || rect.minY < screen.minY - 1 || rect.maxX > screen.maxX + 1 || rect.maxY > screen.maxY + 1 {
                return "window \(window.windowId) is off screen at \(rect)"
            }
            rects.append((window.windowId, rect))
        }
        for i in rects.indices {
            for j in rects.indices where i < j {
                let overlap = rects[i].1.cgRect.intersection(rects[j].1.cgRect)
                if !overlap.isNull && overlap.width > 2 && overlap.height > 2 {
                    return "tiles \(rects[i].0) and \(rects[j].0) overlap"
                }
            }
        }
        return nil
    }
}

// MARK: Tree shapes, comparable between the real tree and a simulation

@MainActor
private func shape(_ node: TreeNode) -> String {
    switch node.tilingTreeNodeCasesOrDie() {
        case .window(let window): return "\(window.windowId)"
        case .tilingContainer(let container):
            let children = container.children.map { "\(shape($0))@\(rounded($0.getWeight(container.orientation)))" }
            let front = container.mostRecentChild.flatMap { mru in container.children.firstIndex { $0 === mru } }.map { "^\($0)" } ?? ""
            return "\(container.orientation == .h ? "h" : "v")\(container.layout == .accordion ? "stack" : "")\(front)[\(children.joined(separator: " "))]"
    }
}

@MainActor
private func shape(_ node: SimNode) -> String {
    if let id = node.windowId { return "\(id)" }
    let children = node.children.map { "\(shape($0))@\(rounded($0.weight))" }
    let front = node.mostRecentChild.flatMap { mru in node.children.firstIndex { $0 === mru } }.map { "^\($0)" } ?? ""
    return "\(node.orientation == .h ? "h" : "v")\(node.layout == .accordion ? "stack" : "")\(front)[\(children.joined(separator: " "))]"
}

private func rounded(_ value: CGFloat) -> String { String(format: "%.3f", value) }

/// SplitMix64: small, fast, and the same sequence for the same seed on every machine
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_133E_E3BB
        return z ^ (z >> 31)
    }
}
