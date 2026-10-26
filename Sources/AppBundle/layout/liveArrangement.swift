import AppKit
import Combine
import Common

/// Hovering an Arrange option for a moment moves the windows for real. Leaving the option puts them back where they
/// were, clicking it keeps them
@MainActor
final class LiveArrangement: ObservableObject {
    static let shared = LiveArrangement()
    private init() {}

    struct Key: Equatable {
        let workspaceName: String
        let count: Int
        let rank: Int
    }

    private struct Session {
        let workspaceName: String
        /// The workspace before the first option was tried
        let original: SimNode
        /// The options the panel showed when trying started. Trying one changes which windows are most recent, so
        /// computing them again would reorder them under the cursor
        let count: Int
        let options: [SimNode]
        var tried: Key
    }

    @Published private var session: Session? = nil
    private var revertTask: Task<(), any Error>? = nil

    /// The key of the option that's on screen right now
    var tried: Key? { session?.tried }

    /// While an option is tried, the panel keeps showing the options it showed before
    func frozenOptions(of workspace: Workspace) -> (count: Int, options: [SimNode])? {
        guard let session, session.workspaceName == workspace.name else { return nil }
        return (session.count, session.options)
    }

    func tryOption(_ key: Key, options: [SimNode]) {
        cancelRevert()
        guard let sim = options.getOrNil(atIndex: key.rank) else { return }
        if session == nil {
            let workspace = Workspace.get(byName: key.workspaceName)
            session = Session(workspaceName: key.workspaceName, original: SimNode.snapshot(workspace), count: key.count, options: options, tried: key)
        }
        session?.tried = key
        materialize(sim, key.workspaceName)
    }

    /// Applies the option and ends trying
    func apply(_ key: Key, options: [SimNode]) {
        cancelRevert()
        if session?.tried != key, let sim = options.getOrNil(atIndex: key.rank) {
            materialize(sim, key.workspaceName)
        }
        session = nil
    }

    /// Reverts after a short delay, so that moving the cursor to the next option doesn't bounce the windows back first
    func scheduleRevert() {
        cancelRevert()
        guard session != nil else { return }
        revertTask = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(300))
            revert()
        }
    }

    func cancelRevert() {
        revertTask?.cancel()
        revertTask = nil
    }

    func revert() {
        cancelRevert()
        guard let session else { return }
        self.session = nil
        materialize(session.original, session.workspaceName)
    }

    private func materialize(_ sim: SimNode, _ workspaceName: String) {
        guard let token: RunSessionGuard = .isServerEnabled else { return }
        Task.startUnstructured {
            try await runLightSession(.menuBarButton, token) {
                let workspace = Workspace.get(byName: workspaceName)
                var windows: [UInt32: Window] = [:]
                for window in workspace.rootTilingContainer.allLeafWindowsRecursive { windows[window.windowId] = window }
                // A window opened or closed in the meantime. Materializing would lose it
                guard Set(windows.keys) == Set(sim.allWindows.compactMap(\.windowId)) else { return }
                sim.materialize(into: workspace, windows: windows)
            }
        }
    }
}
