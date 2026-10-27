@testable import AppBundle
import Common
import XCTest

@MainActor
final class DropZonesTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testDropZoneGeometry() {
        let rect = Rect(topLeftX: 0, topLeftY: 0, width: 1000, height: 500)
        assertEquals(dropZone(for: CGPoint(x: 500, y: 250), in: rect), .stack)
        assertEquals(dropZone(for: CGPoint(x: 50, y: 250), in: rect), .split(.left))
        assertEquals(dropZone(for: CGPoint(x: 950, y: 250), in: rect), .split(.right))
        assertEquals(dropZone(for: CGPoint(x: 500, y: 20), in: rect), .split(.up))
        assertEquals(dropZone(for: CGPoint(x: 500, y: 480), in: rect), .split(.down))
        // The middle box: stack on its left half, swap on its right
        let middle = dropZoneMiddle(of: rect.cgRect)
        assertEquals(dropZone(for: CGPoint(x: middle.midX + 20, y: 250), in: rect), .swap)
        // Just outside the box splits toward the nearest edge, so there's nowhere that does nothing
        assertEquals(dropZone(for: CGPoint(x: middle.minX - 10, y: 250), in: rect), .split(.left))
        assertEquals(dropZone(for: CGPoint(x: 500, y: middle.maxY + 10), in: rect), .split(.down))
    }

    func testStackCreatesAccordion() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let w0 = TestWindow.new(id: 0, parent: root)
        TestWindow.new(id: 1, parent: root)
        TestWindow.new(id: 2, parent: root)

        applyDrop(PendingDrop(window: w0, workspace: workspace, op: .tile(targetWindowId: 1, .stack)))
        assertEquals(root.layoutDescription, .h_tiles([.v_accordion([.window(1), .window(0)]), .window(2)]))
        assertEquals(w0.parent?.mostRecentChild, w0)
    }

    func testSwap() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let w0 = TestWindow.new(id: 0, parent: root)
        TestWindow.new(id: 1, parent: root)
        TestWindow.new(id: 2, parent: root)

        applyDrop(PendingDrop(window: w0, workspace: workspace, op: .tile(targetWindowId: 1, .swap)))
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(0), .window(2)]))
    }

    func testStackOntoExistingStack() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let w0 = TestWindow.new(id: 0, parent: root)
        let stack = TilingContainer(parent: root, adaptiveWeight: 1, .v, .accordion, index: INDEX_BIND_LAST)
        TestWindow.new(id: 1, parent: stack)
        TestWindow.new(id: 2, parent: stack)

        applyDrop(PendingDrop(window: w0, workspace: workspace, op: .tile(targetWindowId: 2, .stack)))
        assertEquals(root.layoutDescription, .h_tiles([.v_accordion([.window(1), .window(2), .window(0)])]))
    }

    func testSplitStackKeepsItWhole() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let w0 = TestWindow.new(id: 0, parent: root)
        let stack = TilingContainer(parent: root, adaptiveWeight: 1, .v, .accordion, index: INDEX_BIND_LAST)
        TestWindow.new(id: 1, parent: stack)
        TestWindow.new(id: 2, parent: stack)

        applyDrop(PendingDrop(window: w0, workspace: workspace, op: .tile(targetWindowId: 2, .split(.down))))
        assertEquals(root.layoutDescription, .h_tiles([.v_tiles([.v_accordion([.window(1), .window(2)]), .window(0)])]))
    }

    func testSplitAlongParentOrientationInsertsSibling() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let w0 = TestWindow.new(id: 0, parent: root)
        TestWindow.new(id: 1, parent: root)
        TestWindow.new(id: 2, parent: root)

        applyDrop(PendingDrop(window: w0, workspace: workspace, op: .tile(targetWindowId: 2, .split(.left))))
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(0), .window(2)]))
    }

    func testSplitAlongParentOrientationOnlyShrinksTarget() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let w0 = TestWindow.new(id: 0, parent: root)
        let w1 = TestWindow.new(id: 1, parent: root)
        let w2 = TestWindow.new(id: 2, parent: workspace.floatingWindowsContainer)

        applyDrop(PendingDrop(window: w2, workspace: workspace, op: .tile(targetWindowId: 1, .split(.right))))
        assertEquals(root.layoutDescription, .h_tiles([.window(0), .window(1), .window(2)]))
        assertEquals(w0.getWeight(.h), 1)
        assertEquals(w1.getWeight(.h), 0.5)
        assertEquals(w2.getWeight(.h), 0.5)
    }

    func testSplitAcrossParentOrientationWrapsTarget() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let w0 = TestWindow.new(id: 0, parent: root)
        TestWindow.new(id: 1, parent: root)
        TestWindow.new(id: 2, parent: root)

        applyDrop(PendingDrop(window: w0, workspace: workspace, op: .tile(targetWindowId: 1, .split(.down))))
        assertEquals(root.layoutDescription, .h_tiles([
            .v_tiles([.window(1), .window(0)]),
            .window(2),
        ]))
    }

    /// The case that the old "half of the hovered tile" preview got wrong: once the dragged window leaves the row,
    /// normalization flattens the root and the dropped window takes the whole width
    func testPreviewAccountsForNormalization() async throws {
        config.enableNormalizationFlattenContainers = true
        config.enableNormalizationOppositeOrientationForNestedContainers = true
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let w0 = TestWindow.new(id: 0, parent: root)
        let w1 = TestWindow.new(id: 1, parent: root)
        try await workspace.layoutWorkspace()

        let drop = PendingDrop(window: w0, workspace: workspace, op: .tile(targetWindowId: 1, .split(.up)))
        let sim = try XCTUnwrap(simulate(drop))
        layout(sim, workspace)
        let predicted = try XCTUnwrap(sim.window(0)?.rect)
        let w1Width = try XCTUnwrap(w1.lastAppliedLayoutPhysicalRect).width
        XCTAssertEqual(predicted.width, w1Width * 2, accuracy: 1)
    }

    func testSplitGroupAlongItsOrientationTakesHalfOfIt() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        TestWindow.new(id: 0, parent: root)
        let column = TilingContainer(parent: root, adaptiveWeight: 1, .v, .tiles, index: INDEX_BIND_LAST)
        TestWindow.new(id: 1, parent: column)
        TestWindow.new(id: 2, parent: column)
        let w3 = TestWindow.new(id: 3, parent: workspace.floatingWindowsContainer)

        applyDrop(PendingDrop(window: w3, workspace: workspace, op: .tile(targetWindowId: 2, .split(.down), level: 1)))
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([
            .window(0),
            .v_tiles([.window(1), .window(2), .window(3)]),
        ]))
        assertEquals(w3.getWeight(.v), 2)
    }

    func testSplitScreenWrapsRoot() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        TestWindow.new(id: 0, parent: root)
        TestWindow.new(id: 1, parent: root)
        let w2 = TestWindow.new(id: 2, parent: workspace.floatingWindowsContainer)

        applyDrop(PendingDrop(window: w2, workspace: workspace, op: .tile(targetWindowId: 1, .split(.down), level: 1)))
        assertEquals(workspace.rootTilingContainer.layoutDescription, .v_tiles([
            .h_tiles([.window(0), .window(1)]),
            .window(2),
        ]))
    }

    func testDropOnEmptyWorkspace() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let w0 = TestWindow.new(id: 0, parent: root)
        TestWindow.new(id: 1, parent: root)
        let other = Workspace.get(byName: "other")

        applyDrop(PendingDrop(window: w0, workspace: other, op: .intoEmptyWorkspace))
        assertEquals(root.layoutDescription, .h_tiles([.window(1)]))
        assertEquals(other.rootTilingContainer.layoutDescription, .h_tiles([.window(0)]))
    }

    /// The guarantee behind the drag overlay: what it draws is exactly where windows end up
    func testPreviewMatchesResultOnRandomTrees() async throws {
        var checkedDrops = 0
        for normalization in [false, true] {
            for seed in 0 ..< 300 {
                setUpWorkspacesForTests()
                config.enableNormalizationFlattenContainers = normalization
                config.enableNormalizationOppositeOrientationForNestedContainers = normalization
                var rng = Lcg(seed: UInt64(seed))
                let workspace = Workspace.get(byName: name)
                var nextId: UInt32 = 0
                buildRandomTree(workspace.rootTilingContainer, depth: 0, &rng, &nextId)
                if normalization { workspace.normalizeContainers() }
                try await workspace.layoutWorkspace()

                let windows = workspace.rootTilingContainer.allLeafWindowsRecursive
                guard windows.count >= 2 else { continue }
                let dragged = windows[rng.next(windows.count)]
                let target = windows.filter { $0 != dragged }[rng.next(windows.count - 1)]
                let zones: [DropZone] = [.stack, .swap, .split(.left), .split(.right), .split(.up), .split(.down)]
                let drop = PendingDrop(window: dragged, workspace: workspace, op: .tile(targetWindowId: target.windowId, zones[rng.next(zones.count)], level: rng.next(3)))
                let context = "seed: \(seed), normalization: \(normalization), drop: \(drop.op), dragged: \(dragged.windowId)"

                guard let sim = simulate(drop) else { continue }
                layout(sim, workspace)
                applyDrop(drop)
                workspace.normalizeContainers()
                try await workspace.layoutWorkspace()

                let realWindows = workspace.rootTilingContainer.allLeafWindowsRecursive
                XCTAssertEqual(Set(realWindows.map(\.windowId)), Set(sim.allWindows.compactMap(\.windowId)), context)
                for window in realWindows {
                    let real = try XCTUnwrap(window.lastAppliedLayoutPhysicalRect, context)
                    let predicted = try XCTUnwrap(sim.window(window.windowId)?.rect, context)
                    XCTAssertEqual(real.minX, predicted.minX, accuracy: 0.01, "\(context), window: \(window.windowId)")
                    XCTAssertEqual(real.minY, predicted.minY, accuracy: 0.01, "\(context), window: \(window.windowId)")
                    XCTAssertEqual(real.width, predicted.width, accuracy: 0.01, "\(context), window: \(window.windowId)")
                    XCTAssertEqual(real.height, predicted.height, accuracy: 0.01, "\(context), window: \(window.windowId)")
                }
                checkedDrops += 1
            }
        }
        XCTAssertGreaterThan(checkedDrops, 300)
    }

    func testResizingOverATileStacksIt() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let column = TilingContainer(parent: root, adaptiveWeight: 500, .v, .tiles, index: INDEX_BIND_LAST)
        let w0 = TestWindow.new(id: 0, parent: column, adaptiveWeight: 950)
        TestWindow.new(id: 1, parent: column, adaptiveWeight: 50) // Squeezed by w0
        TestWindow.new(id: 2, parent: root, adaptiveWeight: 500)

        let sim = SimNode.snapshot(workspace)
        assertEquals(stackSqueezedTiles(resizing: 0, in: sim), StackChange(front: 0, behind: [1]))
        sim.materialize(into: workspace, windows: [0: w0, 1: Window.get(byId: 1)!, 2: Window.get(byId: 2)!])
        // Tests don't flatten the column that's left with one child
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.v_tiles([.h_accordion([.window(0), .window(1)])]), .window(2)]))
        assertEquals(w0.parent?.mostRecentChild, w0)
    }

    func testResizingWithRoomLeftStacksNothing() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        TestWindow.new(id: 0, parent: root, adaptiveWeight: 700)
        TestWindow.new(id: 1, parent: root, adaptiveWeight: 300)

        assertEquals(stackSqueezedTiles(resizing: 0, in: SimNode.snapshot(workspace)), nil)
    }

    func testShrinkingAWindowAwayStacksItBehindTheNeighbour() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        TestWindow.new(id: 0, parent: root, adaptiveWeight: 60) // Shrunk away
        TestWindow.new(id: 1, parent: root, adaptiveWeight: 940)
        TestWindow.new(id: 2, parent: root, adaptiveWeight: 500)

        let sim = SimNode.snapshot(workspace)
        assertEquals(stackSqueezedTiles(resizing: 0, in: sim), StackChange(front: 1, behind: [0]))
        assertEquals(sim.rootContainer.children[0].allWindows.compactMap(\.windowId), [1, 0])
        assertEquals(sim.rootContainer.children[0].mostRecentWindowRecursive?.windowId, 1)
    }

    func testShrinkingAStackedWindowTakesItOut() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        TestWindow.new(id: 0, parent: root)
        let stack = TilingContainer(parent: root, adaptiveWeight: 1, .v, .accordion, index: INDEX_BIND_LAST)
        TestWindow.new(id: 1, parent: stack)
        TestWindow.new(id: 2, parent: stack)

        let sim = SimNode.snapshot(workspace)
        XCTAssertTrue(pullOutOfStack(2, toward: .up, share: 0.3, in: sim))
        // Two windows: the stack becomes two tiles, the window on top at the size it was shrunk to
        let column = sim.rootContainer.children[1]
        assertEquals(column.orientation, .v)
        assertEquals(column.children.map { $0.allWindows.map(\.windowId) }, [[2], [1]]) // Tests don't flatten the stack of one
        assertEquals((column.children[0].weight / (column.children[0].weight + column.children[1].weight) * 10).rounded(), 3)
    }

    func testTheRestOfABiggerStackStaysStacked() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let stack = TilingContainer(parent: root, adaptiveWeight: 1, .v, .accordion, index: INDEX_BIND_LAST)
        TestWindow.new(id: 0, parent: stack)
        TestWindow.new(id: 1, parent: stack)
        TestWindow.new(id: 2, parent: stack)
        TestWindow.new(id: 3, parent: root)

        let sim = SimNode.snapshot(workspace)
        XCTAssertTrue(pullOutOfStack(0, toward: .right, share: 0.5, in: sim))
        let row = sim.rootContainer
        assertEquals(row.children.map { $0.windowId ?? 99 }, [99, 0, 3])
        assertEquals(row.children[0].layout, .accordion)
        assertEquals(row.children[0].allWindows.compactMap(\.windowId), [1, 2])
    }
}

@MainActor
private func layout(_ sim: SimNode, _ workspace: Workspace) {
    let monitor = workspace.workspaceMonitor
    sim.layout(monitor.visibleRectPaddedByOuterGaps, innerGaps: ResolvedGaps(gaps: config.gaps, monitor: monitor).inner)
}

@MainActor
private func buildRandomTree(_ container: TilingContainer, depth: Int, _ rng: inout Lcg, _ nextId: inout UInt32) {
    for _ in 0 ..< 1 + rng.next(depth == 0 ? 4 : 3) {
        let weight = CGFloat(1 + rng.next(4)) / 2
        if depth < 3 && rng.next(3) == 0 {
            let orientation: Orientation = rng.next(2) == 0 ? .h : .v
            let layout: Layout = rng.next(4) == 0 ? .accordion : .tiles
            let child = TilingContainer(parent: container, adaptiveWeight: weight, orientation, layout, index: INDEX_BIND_LAST)
            buildRandomTree(child, depth: depth + 1, &rng, &nextId)
        } else {
            TestWindow.new(id: nextId, parent: container, adaptiveWeight: weight)
            nextId += 1
        }
    }
    // Random MRU, so that accordions don't always show the last child on top
    if !container.children.isEmpty { container.children[rng.next(container.children.count)].markAsMostRecentChild() }
}

/// Deterministic, so that a failing seed can be replayed
private struct Lcg {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next(_ upperBound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(upperBound))
    }
}
