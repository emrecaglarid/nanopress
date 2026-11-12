import AppKit
import Common

/// A floating window left behind the layout, like a Settings window or a dialog, shows only as slivers in the gaps
/// between tiles, and there's no way to click back to it. Once the user goes to another app and the window is mostly
/// covered by tiles, it's parked: moved off screen like the windows of other workspaces. Going back to its app (⌘Tab,
/// the Dock, a notification or one of its windows) brings it back where it was, in front. See Visitors for new windows
@MainActor
final class Parking {
    static let shared = Parking()

    private var parked: Set<UInt32> = []
    private var lastFocusedWindowId: UInt32? = nil
    private var checkTask: Task<(), Never>? = nil

    /// Share of a floating window that tiles above it must cover before it's parked. A floating window the user put
    /// somewhere clear stays where it is
    private static let coverageToPark: CGFloat = 0.6

    private init() {}

    func isParked(_ window: Window) -> Bool {
        parked.contains(window.windowId)
    }

    /// Called on every refresh, before the layout
    func refresh() {
        // Closed, minimized or tiled meanwhile
        parked = parked.filter { Window.get(byId: $0)?.parent is FloatingWindowsContainer }
        guard let focused = focus.windowOrNil as? MacWindow else { return }
        for id in parked {
            if let window = Window.get(byId: id) as? MacWindow, window.macApp === focused.macApp { unpark(window) }
        }
        if focused.windowId != lastFocusedWindowId {
            lastFocusedWindowId = focused.windowId
            scheduleCheck()
        }
    }

    func unpark(_ window: Window) {
        guard parked.remove(window.windowId) != nil, let window = window as? MacWindow else { return }
        window.unhideFromCorner()
        window.raiseWithoutFocus()
    }

    /// When nanopress is turned off, every window goes back on screen
    func releaseAll() {
        parked = []
    }

    /// The app that comes forward raises its windows a moment after the focus changes, so the check waits for that
    private func scheduleCheck() {
        checkTask?.cancel()
        checkTask = Task.startUnstructured { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, TrayMenuModel.shared.isEnabled else { return }
            await self.parkCovered()
        }
    }

    private func parkCovered() async {
        guard let focused = focus.windowOrNil as? MacWindow else { return }
        let candidates = focus.workspace.floatingWindowsContainer.children.compactMap { $0 as? MacWindow }.filter { window in
            window != focused && window.macApp !== focused.macApp && !isParked(window) && !window.isHiddenInCorner
                && !Visitors.shared.isVisitor(window.windowId)
        }
        if candidates.isEmpty { return }
        let stacking = windowsFrontToBack()
        for window in candidates where coverageByTiles(of: window.windowId, stacking) > Self.coverageToPark {
            // Checked again after the wait: the user may have gone back to it meanwhile
            guard focus.windowOrNil != window, window.parent is FloatingWindowsContainer else { continue }
            parked.insert(window.windowId)
            try? await window.hideInCorner(.bottomRightCorner)
            // Its app came forward while hiding waited for the window's frame: unpark found nothing to bring back yet
            if !parked.contains(window.windowId) { window.unhideFromCorner() }
        }
    }
}

/// Windows of the normal level as the window server stacks them, front first, with their frames in the same
/// coordinates as Rect
@MainActor
private func windowsFrontToBack() -> [(id: UInt32, frame: CGRect)] {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
    return list.compactMap { info in
        guard info[kCGWindowLayer as String] as? Int == 0,
              let id = info[kCGWindowNumber as String] as? UInt32,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: bounds) else { return nil }
        return (id, frame)
    }
}

/// How much of the window the tiled windows above it cover, from 0 to 1. Sampled on a grid, which is plenty to tell a
/// window behind the layout from one in the clear
@MainActor
private func coverageByTiles(of windowId: UInt32, _ stacking: [(id: UInt32, frame: CGRect)]) -> CGFloat {
    guard let index = stacking.firstIndex(where: { $0.id == windowId }) else { return 0 }
    let frame = stacking[index].frame
    let above = stacking[..<index].filter { Window.get(byId: $0.id)?.parent is TilingContainer }.map(\.frame)
    if above.isEmpty || frame.isEmpty { return 0 }
    let steps = 12
    var covered = 0
    for i in 0 ..< steps {
        for j in 0 ..< steps {
            let point = CGPoint(x: frame.minX + frame.width * (CGFloat(i) + 0.5) / CGFloat(steps), y: frame.minY + frame.height * (CGFloat(j) + 0.5) / CGFloat(steps))
            if above.contains(where: { $0.contains(point) }) { covered += 1 }
        }
    }
    return CGFloat(covered) / CGFloat(steps * steps)
}
