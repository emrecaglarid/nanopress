@testable import AppBundle
import Common
import XCTest

@MainActor
final class SavedLayoutTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testRoundTrip() throws {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        TestWindow.new(id: 0, parent: root, adaptiveWeight: 3)
        let stack = TilingContainer(parent: root, adaptiveWeight: 2, .v, .accordion, index: INDEX_BIND_LAST)
        let w1 = TestWindow.new(id: 1, parent: stack)
        TestWindow.new(id: 2, parent: stack)
        TestWindow.new(id: 3, parent: root, adaptiveWeight: 1)
        w1.markAsMostRecentChild()
        let saved = SavedLayout.current
        let expected = root.layoutDescription

        // Scramble: every window flat in the root
        let windows = root.allLeafWindowsRecursive
        for window in windows { window.unbindFromParent() }
        for child in root.children { child.unbindFromParent() }
        for window in windows.reversed() { window.bind(to: root, adaptiveWeight: 1, index: INDEX_BIND_LAST) }

        applySavedLayout(try roundTripThroughJson(saved))
        assertEquals(root.layoutDescription, expected)
        assertEquals(root.children.map { $0.getWeight(.h) }, [3, 2, 1])
        assertEquals(w1.parent?.mostRecentChild, w1)
    }

    func testClosedWindowsAreSkippedAndNewWindowsKept() {
        config.enableNormalizationFlattenContainers = true
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        TestWindow.new(id: 0, parent: root)
        TestWindow.new(id: 1, parent: root)
        TestWindow.new(id: 5, parent: root) // Opened while nanopress wasn't running

        let saved = SavedLayout(
            workspaces: [SavedWorkspace(
                name: name,
                root: .container(orientation: "v", layout: "tiles", weight: 1, mostRecentChild: nil, children: [
                    .window(id: 1, weight: 1),
                    .container(orientation: "h", layout: "tiles", weight: 1, mostRecentChild: nil, children: [
                        .window(id: 0, weight: 1),
                        .window(id: 99, weight: 1), // Closed while nanopress wasn't running
                    ]),
                ]),
                floatingWindowIds: [],
            )],
            monitors: [],
        )
        applySavedLayout(saved)
        // The inner container lost a window, so it's flattened
        assertEquals(root.layoutDescription, .v_tiles([.window(1), .window(0), .window(5)]))
    }

    func testWindowsMoveBackToTheirWorkspace() {
        let a = Workspace.get(byName: "a")
        let b = Workspace.get(byName: "b")
        TestWindow.new(id: 0, parent: a.rootTilingContainer)
        TestWindow.new(id: 1, parent: a.rootTilingContainer)

        let saved = SavedLayout(
            workspaces: [
                SavedWorkspace(name: "a", root: .container(orientation: "h", layout: "tiles", weight: 1, mostRecentChild: nil, children: [
                    .window(id: 0, weight: 1),
                ]), floatingWindowIds: []),
                SavedWorkspace(name: "b", root: .container(orientation: "h", layout: "tiles", weight: 1, mostRecentChild: nil, children: [
                    .window(id: 1, weight: 1),
                ]), floatingWindowIds: []),
            ],
            monitors: [],
        )
        applySavedLayout(saved)
        assertEquals(a.rootTilingContainer.layoutDescription, .h_tiles([.window(0)]))
        assertEquals(b.rootTilingContainer.layoutDescription, .h_tiles([.window(1)]))
    }

    private func roundTripThroughJson(_ layout: SavedLayout) throws -> SavedLayout {
        let decoded = try JSONDecoder().decode(SavedLayout.self, from: JSONEncoder().encode(layout))
        assertEquals(decoded, layout)
        return decoded
    }
}
