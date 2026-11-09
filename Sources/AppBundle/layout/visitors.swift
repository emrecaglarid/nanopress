import AppKit
import Common

/// A new window doesn't get a tile right away: it floats over the layout as a visitor, and nothing else moves. Most new
/// windows are a quick look, like checking a design, and splitting a tile for each of them reshuffles the windows the
/// user is working in. Once the user clicks away, the visitor goes into a stack as a tab behind the window in front, so
/// that it's one click away and still nothing moves. It gets a tile only when the user gives it one: from its note,
/// by dragging it to a side of a window, or by dragging its tab out of the stack.
/// See NanopressSettings.newWindowsVisit
@MainActor
final class Visitors {
    static let shared = Visitors()

    private struct Visitor {
        let windowId: UInt32
        let workspace: Workspace
        /// Tucking waits until the visitor has been in front once. An app can take a moment to focus its new window,
        /// and the window focused meanwhile isn't the user clicking away
        var wasFocused = false
    }

    private var visitor: Visitor? = nil

    private init() {}

    func isVisitor(_ windowId: UInt32) -> Bool {
        visitor?.windowId == windowId
    }

    /// Whether a new window on `workspace` floats as a visitor instead of getting a tile. The first window on a
    /// workspace gets a tile: there's no layout to keep yet
    func shouldVisit(_ workspace: Workspace) -> Bool {
        NanopressSettings.shared.newWindowsVisit && !isStartup && !workspace.rootTilingContainer.allLeafWindowsRecursive.isEmpty
    }

    /// Called once a new window was bound to the floating windows of `workspace` because of shouldVisit
    func arrived(_ window: Window, on workspace: Workspace) async {
        // One visitor at a time. The one before goes into a tab, as if the user had clicked away from it
        if let previous = visitor, let previousWindow = Window.get(byId: previous.windowId), previousWindow.parent is FloatingWindowsContainer {
            tuck(previousWindow, on: previous.workspace)
        }
        visitor = Visitor(windowId: window.windowId, workspace: workspace)
        if focus.windowOrNil == window { visitor?.wasFocused = true }
        let rect = await center(window, on: workspace)
        let app = window.app.name ?? "The window"
        LayoutToast.shared.show("\(app) floats for now", action: "Give it a tile", near: rect, on: workspace.workspaceMonitor) {
            Visitors.shared.giveTile(window.windowId)
        }
    }

    /// The app's size if it fits, centered over the layout. Apps tend to open new windows where their last one was,
    /// which can be anywhere over the tiles
    private func center(_ window: Window, on workspace: Workspace) async -> CGRect? {
        guard let rect = try? await window.getAxRect(.cancellable) else { return nil }
        let area = workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
        let size = CGSize(width: min(rect.width, area.width * 0.8), height: min(rect.height, area.height * 0.85))
        let topLeft = CGPoint(x: area.minX + (area.width - size.width) / 2, y: area.minY + (area.height - size.height) / 2)
        window.setAxFrame(topLeft, size)
        return CGRect(origin: topLeft, size: size)
    }

    /// Called on every refresh, before the layout. Tucks the visitor away once the user clicks away from it
    func settle() {
        guard var visitor else { return }
        guard let window = Window.get(byId: visitor.windowId) else {
            // Closed while it floated: the layout never knew about it
            NanopressSettings.shared.countVisitor(.closed)
            self.visitor = nil
            return
        }
        // Dragged into the layout, minimized or moved on in some other way: no longer a visitor
        guard window.parent is FloatingWindowsContainer, let workspace = window.nodeWorkspace else {
            if window.parent is TilingContainer { NanopressSettings.shared.countVisitor(.tiled) }
            self.visitor = nil
            return
        }
        guard let focused = focus.windowOrNil else { return }
        if focused == window {
            visitor.wasFocused = true
            self.visitor = visitor
            return
        }
        // A dialog or another floating window of the same app is still the visit
        let isSameApp = (focused as? MacWindow)?.macApp === (window as? MacWindow)?.macApp
        guard visitor.wasFocused, !(isSameApp && focused.parent is FloatingWindowsContainer) else { return }
        self.visitor = nil
        tuck(window, on: workspace)
    }

    /// Puts `window` into a stack as a tab behind the window in front: in the stack where its app was last put, or
    /// else on the tile used least recently. No tile moves or changes size
    private func tuck(_ window: Window, on workspace: Workspace) {
        let tiles = windowsByRecency(workspace.rootTilingContainer).map(\.stackOrSelf).uniqueByIdentity()
        guard let tile = tuckTarget(tiles, for: window, on: workspace) else {
            // Nothing tiled to go behind any more: it gets the screen
            window.bind(to: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
            if visitor?.windowId == window.windowId { visitor = nil }
            return
        }
        NanopressSettings.shared.countVisitor(.tucked)
        let front: TreeNode
        let stack: TilingContainer
        if let existing = tile as? TilingContainer, existing.layout == .accordion {
            front = existing.mostRecentChild ?? existing
            stack = existing
            // A stack made because the screen was full hands its windows tiles once there's room. The visitor would be
            // one of them, and reshuffle the layout after all. The stack stays as it is instead, like a stack made on purpose
            stack.isOverflowStack = false
        } else {
            guard let parent = tile.parent as? TilingContainer, let index = tile.ownIndex else { return }
            front = tile
            stack = TilingContainer(parent: parent, adaptiveWeight: tile.getWeight(parent.orientation), parent.orientation.opposite, .accordion, index: index)
            _ = tile.bind(to: stack, adaptiveWeight: 1, index: 0)
        }
        window.bind(to: stack, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        // Binding made the visitor the most recent, which would bring it to the front of the stack. Put back the window
        // that was in front, and then the window the user is in, so that recency stays as the user left it
        front.markAsMostRecentChild()
        focus.windowOrNil?.markAsMostRecentChild()
        let frontWindow = front.mostRecentWindowRecursive
        let windowId = window.windowId
        Task.startUnstructured { @MainActor in
            // Once the layout put the visitor in the stack's rect
            try? await Task.sleep(for: .milliseconds(120))
            // The visitor was the last window in front, so it's above the stack's window until that one is raised
            (frontWindow as? MacWindow)?.raiseWithoutFocus()
            guard let rect = stack.lastAppliedLayoutPhysicalRect?.cgRect else { return }
            VisitorHighlight.shared.show(around: rect)
            StackTabs.shared.markFresh(windowId)
            let app = window.app.name ?? "The window"
            LayoutToast.shared.show("\(app) is in a tab here", action: "Give it a tile", near: rect, on: workspace.workspaceMonitor) {
                Visitors.shared.giveTile(windowId)
            }
        }
    }

    private func tuckTarget(_ tiles: [TreeNode], for window: Window, on workspace: Workspace) -> TreeNode? {
        if let bundleId = window.app.rawAppBundleId, let place = NanopressSettings.shared.place(of: bundleId) {
            let area = workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
            let point = CGPoint(x: area.minX + place.x * area.width, y: area.minY + place.y * area.height)
            if let tile = tiles.first(where: { $0.lastAppliedLayoutPhysicalRect?.contains(point) == true }) { return tile }
        }
        return tiles.last
    }

    /// Splits a tile for the window, the way new windows are placed without visitors, and brings it forward
    func giveTile(_ windowId: UInt32) {
        guard let token: RunSessionGuard = .isServerEnabled else { return }
        Task.startUnstructured {
            try await runLightSession(.menuBarButton, token) {
                guard let window = Window.get(byId: windowId), let workspace = window.nodeWorkspace else { return }
                if self.visitor?.windowId == windowId { self.visitor = nil }
                NanopressSettings.shared.countVisitor(.tiled)
                window.unbindFromParent()
                workspace.normalizeContainers()
                let data = bindingDataForNewWindowSplittingBiggestTile(workspace, app: window.app.rawAppBundleId)
                    ?? BindingData(parent: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
                window.bind(to: data.parent, adaptiveWeight: data.adaptiveWeight, index: data.index)
                _ = window.focusWindow()
            }
        }
    }
}

/// How a visit ended, counted so that it shows whether visiting fits how windows are used. See Settings, Advanced
enum VisitorOutcome: String, CaseIterable {
    /// Closed while it floated
    case closed
    /// Went into a stack as a tab
    case tucked
    /// Given a tile
    case tiled
}
