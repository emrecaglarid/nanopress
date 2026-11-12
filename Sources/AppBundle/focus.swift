import AppKit
import Common

/// This object should be only passed around but never memorized
/// Alternative name: ResolvedFocus
struct LiveFocus: AeroAny, Equatable {
    let windowOrNil: Window?
    var workspace: Workspace

    @MainActor fileprivate var frozen: FrozenFocus {
        return FrozenFocus(
            windowId: windowOrNil?.windowId,
            workspaceName: workspace.name,
            monitorId_oneBased: workspace.workspaceMonitor.monitorId_oneBased ?? 0,
        )
    }
}

/// "old", "captured", "frozen in time" Focus
/// It's safe to keep a hard reference to this object.
/// Unlike in LiveFocus, information inside FrozenFocus isn't guaranteed to be self-consistent.
/// window - workspace - monitor relation could change since the moment object was created
private struct FrozenFocus: AeroAny, Equatable, Sendable {
    let windowId: UInt32?
    let workspaceName: String
    // monitorId is not part of the focus. A move to another monitor alone still counts as a focus change for prevFocus
    let monitorId_oneBased: Int

    @MainActor var live: LiveFocus { // Important: don't access focus.monitorId here. monitorId is not part of the focus. Always prefer workspace
        let window: Window? = windowId.flatMap { Window.get(byId: $0) }
        let workspace = Workspace.get(byName: workspaceName)

        let workspaceFocus = workspace.toLiveFocus()
        let windowFocus = window?.toLiveFocusOrNil() ?? workspaceFocus

        return workspaceFocus.workspace != windowFocus.workspace
            ? workspaceFocus // If window and workspace become separated prefer workspace
            : windowFocus
    }
}

@MainActor private var _focus: FrozenFocus = {
    let monitor = mainMonitorInfo
    return FrozenFocus(windowId: nil, workspaceName: monitor.activeWorkspace.name, monitorId_oneBased: monitor.monitorId_oneBased ?? 0)
}()

/// Global focus
@MainActor var focus: LiveFocus { _focus.live }

@MainActor func setFocus(to newFocus: LiveFocus) -> Bool {
    if _focus == newFocus.frozen { return true }
    let oldFocus = focus
    // Normalize mruWindow when focus away from a workspace
    if oldFocus.workspace != newFocus.workspace {
        oldFocus.windowOrNil?.markAsMostRecentChild()
    }

    _focus = newFocus.frozen
    let status = newFocus.workspace.workspaceMonitor.setActiveWorkspace(newFocus.workspace)

    newFocus.windowOrNil?.markAsMostRecentChild()
    return status
}
extension Window {
    @MainActor func focusWindow() -> Bool {
        if let focus = toLiveFocusOrNil() {
            return setFocus(to: focus)
        } else {
            // todo We should also exit-native-hidden/unminimize[/exit-native-fullscreen?] window if we want to fix ID-B6E178F2
            //      and retry to focus the window. Otherwise, it's not possible to focus minimized/hidden windows
            return false
        }
    }

    @MainActor func toLiveFocusOrNil() -> LiveFocus? { visualWorkspace.map { LiveFocus(windowOrNil: self, workspace: $0) } }
}
extension Workspace {
    @MainActor func focusWorkspace() -> Bool { setFocus(to: toLiveFocus()) }

    func toLiveFocus() -> LiveFocus {
        // todo unfortunately mostRecentWindowRecursive may recursively reach empty rootTilingContainer
        //      while floating or macos unconventional windows might be presented
        if let wd = mostRecentWindowRecursive ?? anyLeafWindowRecursive {
            LiveFocus(windowOrNil: wd, workspace: self)
        } else {
            LiveFocus(windowOrNil: nil, workspace: self) // emptyWorkspace
        }
    }
}

@MainActor private var _lastKnownFocus: FrozenFocus = _focus

@MainActor var _prevFocusedWorkspaceName: String? = nil {
    didSet {
        prevFocusedWorkspaceDate = .now
    }
}
@MainActor var prevFocusedWorkspaceDate: Date = .distantPast
@MainActor var prevFocusedWorkspace: Workspace? { _prevFocusedWorkspaceName.map { Workspace.get(byName: $0) } }

@MainActor private var _prevFocus: FrozenFocus? = nil
@MainActor var prevFocus: LiveFocus? { _prevFocus?.live.takeIf { $0 != focus } }

// Should be called in refreshSession. Keeps prevFocus and prevFocusedWorkspace current
@MainActor func checkOnFocusChangedCallbacks_nonCancellable() async {
    if refreshSessionEvent?.isStartup == true {
        return
    }
    let frozenFocus = focus.frozen
    if frozenFocus != _lastKnownFocus {
        _prevFocus = _lastKnownFocus
    }
    if frozenFocus.workspaceName != _lastKnownFocus.workspaceName {
        _prevFocusedWorkspaceName = _lastKnownFocus.workspaceName
    }
    _lastKnownFocus = frozenFocus
}
