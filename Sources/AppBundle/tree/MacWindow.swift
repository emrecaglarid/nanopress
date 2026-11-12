import AppKit
import Common

final class MacWindow: Window {
    let macApp: MacApp
    private var prevUnhiddenProportionalPositionInsideWorkspaceRect: CGPoint?

    @MainActor
    private init(_ id: UInt32, _ actor: MacApp, lastFloatingSize: CGSize?, parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, index: Int) {
        self.macApp = actor
        super.init(id: id, actor, lastFloatingSize: lastFloatingSize, parent: parent, adaptiveWeight: adaptiveWeight, index: index)
    }

    @MainActor static var allWindowsMap: [UInt32: MacWindow] = [:]
    @MainActor static var allWindows: [MacWindow] { Array(allWindowsMap.values) }

    @MainActor
    @discardableResult
    static func getOrRegister(windowId: UInt32, macApp: MacApp) async throws -> MacWindow {
        if let existing = allWindowsMap[windowId] { return existing }
        let known = prefetchedWindows.removeValue(forKey: windowId)
        let rect = if let known { known.rect } else { try await macApp.getAxRect(windowId, .cancellable) }
        let workspace = isStartup ? (rect?.center.monitorApproximation ?? mainMonitorInfo).activeWorkspace : focus.workspace
        let before = SimNode.snapshot(workspace)
        lastPlacementStackedOn = nil
        lastPlacementJoinedStackOf = nil
        lastPlacementVisits = false
        lastPlacementWasDialog = false
        let data = try await unbindAndGetBindingDataForNewWindow(windowId, macApp, workspace, window: nil, knownType: known?.type, .cancellable)
        let stackedOn = lastPlacementStackedOn
        let joinedStackOf = lastPlacementJoinedStackOf
        let visits = lastPlacementVisits
        let wasDialog = lastPlacementWasDialog

        // atomic synchronous section
        if let existing = allWindowsMap[windowId] { return existing }
        let window = MacWindow(windowId, macApp, lastFloatingSize: rect?.size, parent: data.parent, adaptiveWeight: data.adaptiveWeight, index: data.index)
        allWindowsMap[windowId] = window
        window.floatsAsDialog = wasDialog
        if let joinedStackOf, let stackWorkspace = joinedStackOf.nodeWorkspace {
            let app = macApp.name ?? "window"
            offerUndo("New \(app) window joined its stack", action: "Give it a tile", workspace: stackWorkspace, before: before, near: windowId)
        } else if let stackedOn, !isStartup {
            // Undo gives it a tile of its own after all
            offerUndo("Stacked \(windowNames([windowId])) on \(windowNames([stackedOn.windowId])), the screen is full", action: "Give it a tile", workspace: workspace, before: before, near: windowId)
        }

        if try await !restoreClosedWindowsCacheIfNeeded(newlyDetectedWindow: window) {
            if visits { await Visitors.shared.arrived(window, on: workspace) }
        }
        return window
    }

    // var description: String {
    //     let description = [
    //         ("title", title),
    //         ("role", axWindow.get(Ax.roleAttr)),
    //         ("subrole", axWindow.get(Ax.subroleAttr)),
    //         ("identifier", axWindow.get(Ax.identifierAttr)),
    //         ("modal", axWindow.get(Ax.modalAttr).map { String($0) } ?? ""),
    //         ("windowId", String(windowId)),
    //     ].map { "\($0.0): '\(String(describing: $0.1))'" }.joined(separator: ", ")
    //     return "Window(\(description))"
    // }

    func isWindowHeuristic(_ windowLevel: MacOsWindowLevel?, _ cm: CancellationMode) async throws -> Bool { // todo cache
        try await macApp.isWindowHeuristic(windowId, windowLevel, cm)
    }

    func isDialogHeuristic(_ windowLevel: MacOsWindowLevel?, _ cm: CancellationMode) async throws -> Bool { // todo cache
        try await macApp.isDialogHeuristic(windowId, windowLevel, cm)
    }

    func dumpAxInfo(_ cm: CancellationMode) async throws -> [String: Json] {
        try await macApp.dumpWindowAxInfo(windowId: windowId, cm)
    }

    func setNativeFullscreen(_ value: Bool) {
        macApp.setNativeFullscreen(windowId, value)
    }

    func setNativeMinimized(_ value: Bool) {
        macApp.setNativeMinimized(windowId, value)
    }

    // skipClosedWindowsCache is an optimization when it's definitely not necessary to cache closed window.
    //                        If you are unsure, it's better to pass `false`
    @MainActor
    func garbageCollect(skipClosedWindowsCache: Bool) {
        if MacWindow.allWindowsMap.removeValue(forKey: windowId) == nil {
            return
        }
        if !skipClosedWindowsCache { cacheClosedWindowIfNeeded() }
        let parent = unbindFromParent().parent
        let deadWindowWorkspace = parent.nodeWorkspace
        let focus = focus
        if let deadWindowWorkspace, deadWindowWorkspace == focus.workspace ||
            deadWindowWorkspace == prevFocusedWorkspace && prevFocusedWorkspaceDate.distance(to: .now) < 1
        {
            switch parent.cases {
                case .tilingContainer, .floatingWindowsContainer, .macosHiddenAppsWindowsContainer, .macosFullscreenWindowsContainer:
                    let deadWindowFocus = deadWindowWorkspace.toLiveFocus()
                    _ = setFocus(to: deadWindowFocus)
                    // Guard against "Apple Reminders popup" bug: https://github.com/nikitabobko/AeroSpace/issues/201
                    if focus.windowOrNil?.app.pid != app.pid {
                        // Force focus to fix macOS annoyance with focused apps without windows.
                        //   https://github.com/nikitabobko/AeroSpace/issues/65
                        deadWindowFocus.windowOrNil?.nativeFocus()
                    }
                case .macosPopupWindowsContainer, // Don't switch back on popup destruction
                     .workspace, // Workspace is invalid parent for windows
                     .macosMinimizedWindowsContainer: // Don't switch back on minimized windows destruction
                    break
            }
        }
    }

    override func getTitle(_ cm: CancellationMode) async throws -> String { try await macApp.getAxTitle(windowId, cm) ?? "" }
    override func isMacosFullscreen(_ cm: CancellationMode) async throws -> Bool { try await macApp.isMacosNativeFullscreen(windowId, cm) == true }
    override func isMacosMinimized(_ cm: CancellationMode) async throws -> Bool { try await macApp.isMacosNativeMinimized(windowId, cm) == true }

    @MainActor override func nativeFocus() {
        macApp.nativeFocus(windowId)
    }

    /// Brings the window above the other windows without activating its app. See Visitors
    @MainActor func raiseWithoutFocus() {
        macApp.raiseWithoutFocus(windowId)
    }

    override func closeAxWindow() {
        garbageCollect(skipClosedWindowsCache: true)
        macApp.closeAndUnregisterAxWindow(windowId)
    }

    // todo it's part of the window layout and should be moved to layoutRecursive.swift
    @MainActor
    func hideInCorner(_ corner: OptimalHideCorner) async throws {
        guard let nodeMonitor else { return }
        // Don't accidentally override prevUnhiddenEmulationPosition in case of subsequent `hideInCorner` calls
        if !isHiddenInCorner {
            guard let windowRect = try await getAxRect(.cancellable) else { return }
            // Check for isHiddenInCorner for the second time because of the suspension point above
            if !isHiddenInCorner {
                let topLeftCorner = windowRect.topLeftCorner
                let monitorRect = windowRect.center.monitorApproximation.rect // Similar to layoutFloatingWindow. Non idempotent
                let absolutePoint = topLeftCorner - monitorRect.topLeftCorner
                prevUnhiddenProportionalPositionInsideWorkspaceRect =
                    CGPoint(x: absolutePoint.x / monitorRect.width, y: absolutePoint.y / monitorRect.height)
                if isFloating {
                    lastFloatingSize = windowRect.size
                }
            }
        }
        let p: CGPoint
        switch corner {
            case .bottomLeftCorner:
                guard let s = try await getAxSize(.cancellable) else { fallthrough }
                // Zoom will jump off if you do one pixel offset https://github.com/nikitabobko/AeroSpace/issues/527
                // todo this ad hoc won't be necessary once I implement optimization suggested by Zalim
                let onePixelOffset = macApp.appId == .zoom ? .zero : CGPoint(x: 1, y: -1)
                p = nodeMonitor.visibleRect.bottomLeftCorner + onePixelOffset + CGPoint(x: -s.width, y: 0)
            case .bottomRightCorner:
                // Zoom will jump off if you do one pixel offset https://github.com/nikitabobko/AeroSpace/issues/527
                // todo this ad hoc won't be necessary once I implement optimization suggested by Zalim
                let onePixelOffset = macApp.appId == .zoom ? .zero : CGPoint(x: 1, y: 1)
                p = nodeMonitor.visibleRect.bottomRightCorner - onePixelOffset
        }
        setAxFrame(p, nil)
    }

    @MainActor
    func unhideFromCorner() {
        guard let prevUnhiddenProportionalPositionInsideWorkspaceRect else { return }
        guard let nodeWorkspace else { return } // hiding only makes sense for workspace windows
        guard let parent else { return }

        switch getChildParentRelation(child: self, parent: parent) {
            // Just a small optimization to avoid unnecessary AX calls for non floating windows
            // Tiling windows should be unhidden with layoutRecursive anyway
            case .floatingWindow:
                let workspaceRect = nodeWorkspace.workspaceMonitor.rect
                var newX = workspaceRect.topLeftX + workspaceRect.width * prevUnhiddenProportionalPositionInsideWorkspaceRect.x
                var newY = workspaceRect.topLeftY + workspaceRect.height * prevUnhiddenProportionalPositionInsideWorkspaceRect.y
                // todo we probably should replace lastFloatingSize with proper floating window sizing
                // https://github.com/nikitabobko/AeroSpace/issues/1519
                let windowWidth = lastFloatingSize?.width ?? 0
                let windowHeight = lastFloatingSize?.height ?? 0
                newX = newX.coerce(in: workspaceRect.minX ... max(workspaceRect.minX, workspaceRect.maxX - windowWidth))
                newY = newY.coerce(in: workspaceRect.minY ... max(workspaceRect.minY, workspaceRect.maxY - windowHeight))

                setAxFrame(CGPoint(x: newX, y: newY), nil)
            case .macosNativeFullscreenWindow, .macosNativeHiddenAppWindow, .macosNativeMinimizedWindow:
                // Still in the corner, only macOS hides it now. Forgetting that here left a floating window in the
                // corner for good once its app was shown again. The next layout after it's back brings it back
                return
            case .macosPopupWindow, .tiling, .rootTilingContainer, .shimContainerRelation: break
        }

        self.prevUnhiddenProportionalPositionInsideWorkspaceRect = nil
    }

    override var isHiddenInCorner: Bool {
        prevUnhiddenProportionalPositionInsideWorkspaceRect != nil
    }

    override func getAxSize(_ cm: CancellationMode) async throws -> CGSize? {
        try await macApp.getAxSize(windowId, cm)
    }

    override func setAxFrame(_ topLeft: CGPoint?, _ size: CGSize?) {
        macApp.setAxFrame(windowId, topLeft, size)
    }

    override func getAxRect(_ cm: CancellationMode) async throws -> Rect? {
        try await macApp.getAxRect(windowId, cm)
    }
}

extension Window {
    @MainActor
    func relayoutWindow(on workspace: Workspace, _ cm: CancellationMode, forceTile: Bool = false) async throws {
        let data = forceTile
            ? unbindAndGetBindingDataForNewTilingWindow(workspace, window: self)
            : try await unbindAndGetBindingDataForNewWindow(self.asMacWindow().windowId, self.asMacWindow().macApp, workspace, window: self, cm)
        bind(to: data.parent, adaptiveWeight: data.adaptiveWeight, index: data.index)
    }
}

// The function is private because it's unsafe. It leaves the window in unbound state
@MainActor
private func unbindAndGetBindingDataForNewWindow(
    _ windowId: UInt32,
    _ macApp: MacApp,
    _ workspace: Workspace,
    window: Window?,
    knownType: AxUiElementWindowType? = nil,
    _ cm: CancellationMode,
) async throws -> BindingData {
    let type = if let knownType { knownType } else { try await macApp.getAxUiElementWindowType(windowId, getWindowLevel(for: windowId), cm) }
    lastPlacementWasDialog = type == .dialog
    window?.floatsAsDialog = type == .dialog
    return switch type {
        case .popup: BindingData(parent: macosPopupWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        case .dialog: BindingData(parent: workspace.floatingWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        case .window where NanopressSettings.shared.isFloatingApp(macApp.rawAppBundleId):
            BindingData(parent: workspace.floatingWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        case .window: unbindAndGetBindingDataForNewTilingWindow(workspace, window: window, bundleId: macApp.rawAppBundleId)
    }
}

// The function is private because it's unsafe. It leaves the window in unbound state
/// The window whose stack a new window of the same app joined. See unbindAndGetBindingDataForNewTilingWindow
@MainActor private var lastPlacementJoinedStackOf: Window? = nil
/// Whether the new window was bound as a visitor. See Visitors
@MainActor private var lastPlacementVisits = false
/// Whether the new window floats because it looked like a dialog. See Window.floatsAsDialog
@MainActor private var lastPlacementWasDialog = false

@MainActor
private func unbindAndGetBindingDataForNewTilingWindow(_ workspace: Workspace, window: Window?, bundleId: String? = nil) -> BindingData {
    window?.unbindFromParent() // It's important to unbind to get correct data from below
    if let window, let data = StackTabs.shared.takePendingJoin(window.windowId) {
        return data
    }
    // A new window of the app in front, with the app in a stack: like a new browser tab, it joins the stack
    if window == nil && !isStartup, let bundleId, let focused = focus.windowOrNil, focused.app.rawAppBundleId == bundleId,
       let stack = focused.parent as? TilingContainer, stack.layout == .accordion
    {
        lastPlacementJoinedStackOf = focused
        return BindingData(parent: stack, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    }
    // A new window floats over the layout until the user gives it a tile, so that nothing moves for a quick look
    if window == nil && Visitors.shared.shouldVisit(workspace) {
        lastPlacementVisits = true
        return BindingData(parent: workspace.floatingWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    }
    if window == nil && !isStartup, let data = bindingDataForNewWindowSplittingBiggestTile(workspace, app: bundleId) {
        return data
    }
    let mruWindow = workspace.mostRecentWindowRecursive
    if let mruWindow, let tilingParent = mruWindow.parent as? TilingContainer {
        return BindingData(
            parent: tilingParent,
            adaptiveWeight: WEIGHT_AUTO,
            index: mruWindow.ownIndex.orDie() + 1,
        )
    } else {
        return BindingData(
            parent: workspace.rootTilingContainer,
            adaptiveWeight: WEIGHT_AUTO,
            index: INDEX_BIND_LAST,
        )
    }
}

// MARK: Reading new windows ahead

/// Frames and kinds of new windows, read for all apps at once. See prefetchNewWindows
@MainActor private var prefetchedWindows: [UInt32: (rect: Rect?, type: AxUiElementWindowType)] = [:]

/// Reads the frame and kind of every new window before registering them, every app at once. Each app answers on its
/// own thread, but registration waits on one window at a time: with many windows, or apps slow to answer because
/// memory is low and they were swapped out, startup waited on each app in turn
@MainActor
func prefetchNewWindows(_ windowIdsByApp: [MacApp: [UInt32]]) async -> [(app: String, windows: Int, duration: Duration)] {
    prefetchedWindows = [:]
    return await withTaskGroup(of: PrefetchResult.self, returning: [(app: String, windows: Int, duration: Duration)].self) { group in
        // Like refreshAllAndGetAliveWindowIds: the app can't be sent to the task, so the task looks it up by pid
        func read(pid: pid_t, name: String, windowIds: [UInt32]) {
            group.addTask { @Sendable @MainActor in
                guard let app = MacApp.allAppsMap[pid] else { return PrefetchResult(app: name, windows: [], duration: .zero) }
                let start = ContinuousClock.now
                var windows: [PrefetchedWindow] = []
                for windowId in windowIds {
                    // Left out on failure: registration then reads it itself, as before
                    guard let rect = try? await app.getAxRect(windowId, .cancellable),
                          let type = try? await app.getAxUiElementWindowType(windowId, getWindowLevel(for: windowId), .cancellable)
                    else { continue }
                    windows.append(PrefetchedWindow(id: windowId, rect: rect, type: type))
                }
                return PrefetchResult(app: name, windows: windows, duration: ContinuousClock.now - start)
            }
        }
        for (app, windowIds) in windowIdsByApp {
            let new = windowIds.filter { MacWindow.allWindowsMap[$0] == nil }
            if !new.isEmpty { read(pid: app.pid, name: app.name ?? app.rawAppBundleId ?? "pid \(app.pid)", windowIds: new) }
        }
        var timings: [(app: String, windows: Int, duration: Duration)] = []
        for await result in group {
            for window in result.windows { prefetchedWindows[window.id] = (window.rect, window.type) }
            timings.append((result.app, result.windows.count, result.duration))
        }
        return timings
    }
}

private struct PrefetchedWindow: Sendable {
    let id: UInt32
    let rect: Rect?
    let type: AxUiElementWindowType
}

private struct PrefetchResult: Sendable {
    let app: String
    let windows: [PrefetchedWindow]
    let duration: Duration
}

/// Anything not registered after all, like a window that closed meanwhile
@MainActor
func forgetPrefetchedWindows() {
    prefetchedWindows = [:]
}
