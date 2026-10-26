import AppKit
import Common

/// Double-clicking a title bar zooms the window, which macOS does by making it as big as the screen. A tiled window
/// can't be, so nanopress takes it as a wish to have the screen for a while: the workspace becomes one stack with the
/// window on top, and the other windows wait as tabs. Zooming again brings the layout from before back
@MainActor private var zoomedLayouts: [String: SimNode] = [:]
/// Frames that nanopress sets come back as resize events too, some of them late. Right after a zoom they're ignored
@MainActor private var lastZoomChange: ContinuousClock.Instant? = nil

enum ZoomIntent {
    case zoom
    case restore
}

/// Whether a resize that nanopress didn't make and the mouse didn't do is a zoom
@MainActor
func zoomIntent(_ window: Window) async throws -> ZoomIntent? {
    if let lastZoomChange, ContinuousClock.now - lastZoomChange < .milliseconds(1500) { return nil }
    guard let workspace = window.nodeWorkspace, workspace.isVisible, window.parent is TilingContainer,
          workspace.rootTilingContainer.allLeafWindowsRecursive.count > 1,
          let applied = window.lastAppliedLayoutPhysicalRect,
          let rect = try await window.getAxRect(.cancellable) else { return nil }
    let isOwnFrame = abs(rect.minX - applied.minX) < 4 && abs(rect.minY - applied.minY) < 4 &&
        abs(rect.width - applied.width) < 4 && abs(rect.height - applied.height) < 4
    if isOwnFrame { return nil }
    if zoomedLayouts[workspace.name] != nil { return .restore }
    let screen = workspace.workspaceMonitor.visibleRect
    return rect.width >= screen.width * 0.9 && rect.height >= screen.height * 0.9 ? .zoom : nil
}

@MainActor
func applyZoom(_ intent: ZoomIntent, _ window: Window) {
    guard let workspace = window.nodeWorkspace else { return }
    lastZoomChange = .now
    switch intent {
        case .zoom:
            let before = SimNode.snapshot(workspace)
            let sim = SimNode(.workspace)
            let stack = SimNode(.container(.h, .accordion))
            stack.bind(to: sim, weight: 1, index: 0)
            var windows: [UInt32: Window] = [:]
            for simWindow in before.allWindows {
                let id = simWindow.windowId.orDie()
                windows[id] = Window.get(byId: id)
                SimNode(.window(id)).bind(to: stack, weight: 1, index: INDEX_BIND_LAST)
            }
            stack.children.first { $0.windowId == window.windowId }?.markAsMostRecentChild()
            sim.materialize(into: workspace, windows: windows)
            zoomedLayouts[workspace.name] = before
            LayoutToast.shared.show("\(windowNames([window.windowId])) has the screen", action: "Restore", near: nil, on: workspace.workspaceMonitor) {
                guard let token: RunSessionGuard = .isServerEnabled else { return }
                Task.startUnstructured {
                    try await runLightSession(.menuBarButton, token) { applyZoom(.restore, window) }
                }
            }
        case .restore:
            LayoutToast.shared.hide()
            LastChange.shared.clear()
            guard let before = zoomedLayouts.removeValue(forKey: workspace.name) else { return }
            // Rearranged meanwhile: what's on screen now is what the user wants
            guard workspace.rootTilingContainer.layout == .accordion else { return }
            restoreLayout(before, into: workspace)
    }
}
