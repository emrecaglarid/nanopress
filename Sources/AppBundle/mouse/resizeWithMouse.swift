import AppKit
import Common

@MainActor
private var resizeWithMouseTask: Task<(), any Error>? = nil

func resizedObs(_: AXObserver, ax: AXUIElement, notif: CFString, _: UnsafeMutableRawPointer?) {
    let notif = notif as String
    let windowId = ax.containingWindowId()
    Task.startUnstructured { @MainActor in
        guard let token: RunSessionGuard = .isServerEnabled else { return }
        guard let windowId, let window = Window.get(byId: windowId), try await isManipulatedWithMouse(window) else {
            if let windowId, let window = Window.get(byId: windowId) {
                if let intent = try await zoomIntent(window) {
                    try await runLightSession(.ax(notif), token) { applyZoom(intent, window) }
                    return
                }
                checkForMinimumSize(window)
            }
            scheduleCancellableCompleteRefreshSession(.ax(notif))
            return
        }
        resizeWithMouseTask?.cancel()
        resizeWithMouseTask = Task.startUnstructured {
            try checkCancellation()
            try await runLightSession(.ax(notif), token) {
                try await resizeWithMouse(window)
            }
        }
    }
}

/// What releasing the mouse does to the layout, beyond the new sizes
private enum ResizeChange {
    /// See stackSqueezedTiles
    case squeeze
    /// See pullOutOfStack
    case pullOut(CardinalDirection, share: CGFloat)
}

@MainActor
private var pendingResizeChange: (windowId: UInt32, change: ResizeChange)? = nil

@MainActor
func resetManipulatedWithMouseIfPossible() async throws {
    if let (windowId, change) = pendingResizeChange {
        pendingResizeChange = nil
        DropZoneOverlay.shared.hide()
        apply(change, resizing: windowId)
    }
    if currentlyManipulatedWithMouseWindowId != nil {
        currentlyManipulatedWithMouseWindowId = nil
        for workspace in Workspace.all {
            workspace.resetResizeWeightBeforeResizeRecursive()
        }
        scheduleCancellableCompleteRefreshSession(.resetManipulatedWithMouse, optimisticallyPreLayoutWorkspaces: true)
    }
}

private let adaptiveWeightBeforeResizeWithMouseKey = TreeNodeUserDataKey<CGFloat>(key: "adaptiveWeightBeforeResizeWithMouseKey")

@MainActor
private func resizeWithMouse(_ window: Window) async throws { // todo cover with tests
    resetClosedWindowsCache()
    switch window.windowParentCases {
        case .unbound: return
        case .floatingWindowsContainer, .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer,
             .macosPopupWindowsContainer, .macosHiddenAppsWindowsContainer:
            return // Nothing to do for floating, or unconventional windows
        case .tilingContainer:
            guard let rect = try await window.getAxRect(.cancellable) else { return }
            guard let lastAppliedLayoutRect = window.lastAppliedLayoutPhysicalRect else { return }
            // Arrange gives the app this width from now on
            if let bundleId = window.app.rawAppBundleId { NanopressSettings.shared.learnWidth(rect.width, for: bundleId) }
            let (lParent, lOwnIndex) = window.closestParent(hasChildrenInDirection: .left, withLayout: .tiles) ?? (nil, nil)
            let (dParent, dOwnIndex) = window.closestParent(hasChildrenInDirection: .down, withLayout: .tiles) ?? (nil, nil)
            let (uParent, uOwnIndex) = window.closestParent(hasChildrenInDirection: .up, withLayout: .tiles) ?? (nil, nil)
            let (rParent, rOwnIndex) = window.closestParent(hasChildrenInDirection: .right, withLayout: .tiles) ?? (nil, nil)
            let table: [(CGFloat, TilingContainer?, Int?, Int?)] = [
                (lastAppliedLayoutRect.minX - rect.minX, lParent, 0,                        lOwnIndex),               // Horizontal, to the left of the window
                (rect.maxY - lastAppliedLayoutRect.maxY, dParent, dOwnIndex.map { $0 + 1 }, dParent?.children.count), // Vertical, to the down of the window
                (lastAppliedLayoutRect.minY - rect.minY, uParent, 0,                        uOwnIndex),               // Vertical, to the up of the window
                (rect.maxX - lastAppliedLayoutRect.maxX, rParent, rOwnIndex.map { $0 + 1 }, rParent?.children.count), // Horizontal, to the right of the window
            ]
            for (diff, parent, startIndex, pastTheEndIndex) in table {
                if let parent, let startIndex, let pastTheEndIndex, pastTheEndIndex - startIndex > 0 && abs(diff) > 5 { // 5 pixels should be enough to fight with accumulated floating precision error
                    let siblingDiff = diff.div(pastTheEndIndex - startIndex).orDie()
                    let orientation = parent.orientation

                    window.parentsWithSelf.lazy
                        .prefix(while: { $0 != parent })
                        .filter {
                            let parent = $0.parent as? TilingContainer
                            return parent?.orientation == orientation && parent?.layout == .tiles
                        }
                        .forEach { $0.setWeight(orientation, $0.getWeightBeforeResize(orientation) + diff) }
                    for sibling in parent.children[startIndex ..< pastTheEndIndex] {
                        sibling.setWeight(orientation, sibling.getWeightBeforeResize(orientation) - siblingDiff)
                    }
                }
            }
            currentlyManipulatedWithMouseWindowId = window.windowId
            // An edge of a stacked window with nothing next to it has no neighbour to resize. Pulling it in takes the
            // window out of the stack instead
            let stackSize = window.parent?.lastAppliedLayoutPhysicalRect ?? lastAppliedLayoutRect
            let pulls: [(CardinalDirection, CGFloat, CGFloat, TilingContainer?)] = [
                (.up, lastAppliedLayoutRect.maxY - rect.maxY, rect.height / max(stackSize.height, 1), dParent), // Bottom edge up
                (.down, rect.minY - lastAppliedLayoutRect.minY, rect.height / max(stackSize.height, 1), uParent), // Top edge down
                (.left, lastAppliedLayoutRect.maxX - rect.maxX, rect.width / max(stackSize.width, 1), rParent), // Right edge left
                (.right, rect.minX - lastAppliedLayoutRect.minX, rect.width / max(stackSize.width, 1), lParent), // Left edge right
            ]
            let isStacked = (window.parent as? TilingContainer)?.layout == .accordion && window.parent?.children.count ?? 0 > 1
            let pull = !isStacked ? nil : pulls.first { side, pulledIn, _, neighbour in
                neighbour == nil && pulledIn > max(80, (side.orientation == .h ? stackSize.width : stackSize.height) * 0.15)
            }
            if let (side, _, share, _) = pull {
                preview(.pullOut(side, share: min(max(share, 0.15), 0.85)), resizing: window)
            } else {
                preview(.squeeze, resizing: window)
            }
    }
}

/// Shows the layout a release would make, if the resize changes more than sizes
@MainActor
private func preview(_ change: ResizeChange, resizing window: Window) {
    guard let workspace = window.nodeWorkspace else { return }
    let sim = SimNode.snapshot(workspace)
    if apply(change, to: sim, resizing: window.windowId) != nil {
        pendingResizeChange = (window.windowId, change)
        DropZoneOverlay.shared.showArrangement(arrangedTiles(sim, on: workspace), monitorRect: workspace.workspaceMonitor.rect.cgRect)
    } else if pendingResizeChange != nil {
        pendingResizeChange = nil
        DropZoneOverlay.shared.hide()
    }
}

/// Changes `sim` and returns what to say about it, or nil if the change doesn't apply
@MainActor
private func apply(_ change: ResizeChange, to sim: SimNode, resizing windowId: UInt32) -> (message: String, near: UInt32)? {
    switch change {
        case .squeeze:
            guard let stacked = stackSqueezedTiles(resizing: windowId, in: sim) else { return nil }
            return ("Stacked \(windowNames(stacked.behind)) behind \(windowNames([stacked.front]))", stacked.front)
        case .pullOut(let side, let share):
            guard pullOutOfStack(windowId, toward: side, share: share, in: sim) else { return nil }
            return ("Took \(windowNames([windowId])) out of the stack", windowId)
    }
}

@MainActor
private func apply(_ change: ResizeChange, resizing windowId: UInt32) {
    guard let workspace = Window.get(byId: windowId)?.nodeWorkspace else { return }
    let before = SimNode.snapshot(workspace)
    let sim = SimNode.snapshot(workspace)
    guard let (message, near) = apply(change, to: sim, resizing: windowId) else { return }
    var windows: [UInt32: Window] = [:]
    for window in workspace.rootTilingContainer.allLeafWindowsRecursive {
        windows[window.windowId] = window
    }
    sim.materialize(into: workspace, windows: windows)
    offerUndo(message, workspace: workspace, before: before, near: near)
}

extension TreeNode {
    @MainActor
    fileprivate func getWeightBeforeResize(_ orientation: Orientation) -> CGFloat {
        let currentWeight = getWeight(orientation) // Check assertions
        return getUserData(key: adaptiveWeightBeforeResizeWithMouseKey)
            ?? (lastAppliedLayoutVirtualRect?.getDimension(orientation) ?? currentWeight)
            .also { putUserData(key: adaptiveWeightBeforeResizeWithMouseKey, data: $0) }
    }

    fileprivate func resetResizeWeightBeforeResizeRecursive() {
        cleanUserData(key: adaptiveWeightBeforeResizeWithMouseKey)
        for child in children {
            child.resetResizeWeightBeforeResizeRecursive()
        }
    }
}
