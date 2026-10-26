@testable import AppBundle
import Common
import XCTest

@MainActor
final class AutoLayoutTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testOverflowIsStackedUnderTheLeastRecentShownWindow() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        TestWindow.new(id: 0, parent: root)
        TestWindow.new(id: 1, parent: root)
        TestWindow.new(id: 2, parent: root) // Most recent

        applyArrangement(arrangement(of: workspace, showing: 2)!, to: workspace)
        assertEquals(root.layoutDescription, .h_tiles([.window(2), .v_accordion([.window(1), .window(0)])]))
        assertEquals(root.mostRecentWindowRecursive?.windowId, 2)
        assertEquals((root.children[1] as? TilingContainer)?.mostRecentChild, Window.get(byId: 1))
    }

    func testTilesFillTheScreen() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        for id: UInt32 in 0 ..< 4 { TestWindow.new(id: id, parent: root) }

        for count in 1 ... 4 {
            let options = arrangements(of: workspace, showing: count, limit: 3)
            XCTAssertFalse(options.isEmpty)
            var shapes: [[CGRect]] = []
            for sim in options {
                let tiles = arrangedTiles(sim, on: workspace)
                let area = workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
                assertEquals(tiles.count, count)
                assertEquals(tiles.map(\.stackCount).reduce(0, +), 4)
                XCTAssertEqual(tiles.map { $0.rect.width * $0.rect.height }.reduce(0, +), area.width * (area.height - 1), accuracy: 1)
                shapes.append(tiles.map(\.rect))
            }
            // Every option is a different layout
            for i in shapes.indices { for j in shapes.indices where i < j { XCTAssertNotEqual(shapes[i], shapes[j]) } }
        }
    }

    func testRecencyFollowsStacks() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let w0 = TestWindow.new(id: 0, parent: root)
        let stack = TilingContainer(parent: root, adaptiveWeight: 1, .v, .accordion, index: INDEX_BIND_LAST)
        TestWindow.new(id: 1, parent: stack)
        TestWindow.new(id: 2, parent: stack)
        w0.markAsMostRecentChild()
        assertEquals(windowsByRecency(root).map(\.windowId), [0, 2, 1])
    }

    func testNewWindowSplitsTheBiggestTileAlongItsLongerSide() async throws {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        TestWindow.new(id: 0, parent: root)
        try await workspace.layoutWorkspace()

        // One wide window: the new one goes next to it
        var data = bindingDataForNewWindowSplittingBiggestTile(workspace)!
        TestWindow.new(id: 1, parent: data.parent, adaptiveWeight: data.adaptiveWeight)
        assertEquals(root.layoutDescription, .h_tiles([.window(0), .window(1)]))
        try await workspace.layoutWorkspace()

        // Two tall halves: the next one goes below one of them
        data = bindingDataForNewWindowSplittingBiggestTile(workspace)!
        TestWindow.new(id: 2, parent: data.parent, adaptiveWeight: data.adaptiveWeight)
        assertEquals(root.layoutDescription, .h_tiles([.window(0), .v_tiles([.window(1), .window(2)])]))
    }

    func testArrangeCountsStopAtWhatFitsOnScreen() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let capacity = tileCapacity(of: workspace.workspaceMonitor)
        for id in 0 ..< UInt32(capacity + 2) { TestWindow.new(id: id, parent: root) }
        assertEquals(arrangeCounts(of: workspace), Array(1 ... capacity))
    }

    func testNewWindowIsStackedOnceTheScreenIsFull() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let capacity = tileCapacity(of: workspace.workspaceMonitor)
        for id in 0 ..< UInt32(capacity) { TestWindow.new(id: id, parent: root) } // 0 is the least recent

        let data = bindingDataForNewWindowSplittingBiggestTile(workspace)!
        let new = TestWindow.new(id: 100, parent: data.parent, adaptiveWeight: data.adaptiveWeight)
        assertEquals(root.children.count, capacity)
        XCTAssertTrue(new.parent === root.children[0])
        assertEquals((root.children[0] as? TilingContainer)?.layout, .accordion)
        assertEquals(root.children[0].allLeafWindowsRecursive.map(\.windowId), [0, 100])
    }

    func testStackedWindowGetsATileBackOnceThereIsRoom() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let capacity = tileCapacity(of: workspace.workspaceMonitor)
        for id in 0 ..< UInt32(capacity) { TestWindow.new(id: id, parent: root) }
        let data = bindingDataForNewWindowSplittingBiggestTile(workspace)!
        TestWindow.new(id: 100, parent: data.parent, adaptiveWeight: data.adaptiveWeight)

        unstackWhereThereIsRoom(workspace)
        assertEquals(root.children.count, capacity) // Still full

        Window.get(byId: 1)!.unbindFromParent()
        unstackWhereThereIsRoom(workspace)
        assertEquals(root.children.count, capacity)
        // The new window stays on top. The one it covered comes back
        XCTAssertTrue(Window.get(byId: 0)!.parent === root)
        assertEquals(root.allLeafWindowsRecursive.filter { $0.parent !== root }.map(\.windowId), [100])
    }

    func testStackMadeOnPurposeStays() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        TestWindow.new(id: 1, parent: root)
        let stack = TilingContainer(parent: root, adaptiveWeight: 1, .v, .accordion, index: INDEX_BIND_LAST)
        TestWindow.new(id: 2, parent: stack)
        TestWindow.new(id: 3, parent: stack)

        unstackWhereThereIsRoom(workspace)
        assertEquals(stack.children.count, 2)
    }

    func testUndoPutsBackTheLayoutAndKeepsNewWindows() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        TestWindow.new(id: 0, parent: root)
        TestWindow.new(id: 1, parent: root)
        TestWindow.new(id: 2, parent: root)
        let before = SimNode.snapshot(workspace)

        let stack = TilingContainer(parent: root, adaptiveWeight: 1, .v, .accordion, index: 0)
        Window.get(byId: 1)!.bind(to: stack, adaptiveWeight: 1, index: 0)
        Window.get(byId: 2)!.bind(to: stack, adaptiveWeight: 1, index: 1)
        Window.get(byId: 0)!.unbindFromParent() // Closed meanwhile
        TestWindow.new(id: 3, parent: root) // Opened meanwhile

        restoreLayout(before, into: workspace)
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .window(2), .window(3)]))
    }

    func testNewWindowGoesWhereItsAppWasLastPut() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let area = workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
        let left = TestWindow.new(id: 0, parent: root)
        let right = TestWindow.new(id: 1, parent: root)
        left.lastAppliedLayoutPhysicalRect = Rect(topLeftX: area.minX, topLeftY: area.minY, width: area.width / 2, height: area.height)
        right.lastAppliedLayoutPhysicalRect = Rect(topLeftX: area.minX + area.width / 2, topLeftY: area.minY, width: area.width / 2, height: area.height)
        right.markAsMostRecentChild() // The biggest-tile rule alone would split the right one
        NanopressSettings.shared.learnPlace(CGPoint(x: 0.1, y: 0.5), for: "com.example.chat")

        let data = bindingDataForNewWindowSplittingBiggestTile(workspace, app: "com.example.chat")!
        TestWindow.new(id: 2, parent: data.parent).bind(to: data.parent, adaptiveWeight: data.adaptiveWeight, index: data.index)
        // The left tile is taller than wide, so it's split into rows, and the new window takes the half nearer the place
        assertEquals(root.layoutDescription, .h_tiles([.v_tiles([.window(0), .window(2)]), .window(1)]))
    }

    func testTileGrowsToFitAWindowThatWontShrink() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        TestWindow.new(id: 0, parent: root, adaptiveWeight: 800)
        let stack = TilingContainer(parent: root, adaptiveWeight: 800, .v, .accordion, index: INDEX_BIND_LAST)
        TestWindow.new(id: 1, parent: stack)
        let wide = TestWindow.new(id: 2, parent: stack)

        XCTAssertTrue(makeRoom(for: wide, extra: CGSize(width: 150, height: 0)))
        assertEquals(root.children.map { $0.getWeight(.h) }, [650, 950])

        // The neighbour keeps at least 200
        XCTAssertFalse(makeRoom(for: wide, extra: CGSize(width: 500, height: 0)))
    }
}
