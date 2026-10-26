import AppKit
import ApplicationServices
import Common

/// The badges apps show on their Dock icons, like unread counts, by app name. A tab of a window behind a stack shows
/// its app's badge, so that a hidden app that wants attention doesn't go unnoticed
@MainActor
final class DockBadges: ObservableObject {
    static let shared = DockBadges()

    @Published private(set) var badges: [String: String] = [:]
    private var timer: Timer? = nil

    private init() {}

    /// Only while there are tabs to show them on
    var isWatching: Bool {
        get { timer != nil }
        set {
            guard newValue != isWatching else { return }
            timer?.invalidate()
            timer = nil
            if newValue {
                refresh()
                timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
                    Task { @MainActor in DockBadges.shared.refresh() }
                }
            }
        }
    }

    private func refresh() {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var result: [String: String] = [:]
        for list in children(app) where string(list, kAXRoleAttribute) == kAXListRole {
            for item in children(list) {
                if let title = string(item, kAXTitleAttribute), let badge = string(item, "AXStatusLabel"), !badge.isEmpty {
                    result[title] = badge
                }
            }
        }
        if result != badges { badges = result }
    }

    private func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef? = nil
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef? = nil
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
