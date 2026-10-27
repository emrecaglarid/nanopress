import AppKit

@MainActor var currentlyManipulatedWithMouseWindowId: UInt32? = nil
var isLeftMouseButtonDown: Bool { NSEvent.pressedMouseButtons == 1 }

/// The window under the pointer when the left button went down. Apps that draw their own title bar (ChatGPT, Elyx and
/// the like) are often not focused yet while their window is dragged, so focus alone misses those drags
@MainActor var mouseDownWindowId: UInt32? = nil

@MainActor
func isManipulatedWithMouse(_ window: Window) async throws -> Bool {
    guard !window.isHiddenInCorner, // Don't allow to resize/move windows of hidden workspaces
          isLeftMouseButtonDown,
          currentlyManipulatedWithMouseWindowId == nil || window.windowId == currentlyManipulatedWithMouseWindowId
    else { return false }
    if window.windowId == mouseDownWindowId { return true }
    return try await getNativeFocusedWindow(.cancellable) == window
}

/// The topmost normal window of another app at `point`, from the window server, which knows about every window whether
/// or not its app is focused
@MainActor
func windowId(at point: CGPoint) -> UInt32? {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
    let ownPid = ProcessInfo.processInfo.processIdentifier
    for info in list { // Front to back
        guard (info[kCGWindowLayer as String] as? Int) == 0,
              (info[kCGWindowOwnerPID as String] as? Int32) != ownPid,
              let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
              let id = info[kCGWindowNumber as String] as? UInt32
        else { continue }
        let rect = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
        if rect.contains(point) { return id }
    }
    return nil
}

/// Some apps don't report that their window moved until the drag is over. While the button is down, a moved window is
/// noticed from the mouse instead: the same as a move notification
@MainActor private var lastDragCheck: ContinuousClock.Instant? = nil

@MainActor
func checkDraggedWindow() {
    guard let id = mouseDownWindowId, let window = Window.get(byId: id) else { return }
    if let lastDragCheck, ContinuousClock.now - lastDragCheck < .milliseconds(50) { return }
    lastDragCheck = .now
    // Already being dragged: keep the preview following the pointer
    if currentlyManipulatedWithMouseWindowId == id { return handleWindowMovedWithMouse(window) }
    if currentlyManipulatedWithMouseWindowId != nil { return }
    Task.startUnstructured { @MainActor in
        guard let applied = window.lastAppliedLayoutPhysicalRect, let rect = try await window.getAxRect(.cancellable),
              abs(rect.minX - applied.minX) > 4 || abs(rect.minY - applied.minY) > 4 else { return }
        handleWindowMovedWithMouse(window)
    }
}

/// Same motivation as in monitorFrameNormalized
var mouseLocation: CGPoint { NSEvent.mouseLocation.withYAxisFlipped }
