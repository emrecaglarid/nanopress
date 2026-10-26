import AppKit
import Common
import SwiftUI

/// A note that says what nanopress just did to the layout on its own, with a way to take it back. Guessing what the
/// user wants is only pleasant if a wrong guess costs one click
@MainActor
final class LayoutToast {
    static let shared = LayoutToast()

    private let model = LayoutToastModel()
    private var hideTask: Task<(), any Error>? = nil
    private var undo: (@MainActor () -> Void)? = nil
    private lazy var panel: NSPanel = {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.ignoresCycle, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        let view = LayoutToastHostingView(rootView: LayoutToastView(model: model) { LayoutToast.shared.takeBack() })
        view.onHover = { hovering in LayoutToast.shared.hover(hovering) }
        panel.contentView = view
        return panel
    }()

    /// How long the note stays when the pointer isn't on it
    private static let duration: Duration = .seconds(5)
    /// Room for the shadow
    private static let margin: CGFloat = 16

    private init() {}

    /// `near` is the tile the change is about, in screen coordinates. The note sits at its bottom
    func show(_ message: String, action: String = "Undo", near tile: CGRect?, on monitor: any MonitorInfo, undo: @escaping @MainActor () -> Void) {
        if isUnitTest { return }
        self.undo = undo
        LastChange.shared.record(message, action: action, undo: undo)
        model.message = message
        model.action = action
        let size = panel.contentView.orDie().fittingSize
        let area = tile ?? monitor.visibleRect.cgRect
        let top = area.maxY - size.height - 24 + Self.margin
        let frame = NSRect(x: area.midX - size.width / 2, y: mainMonitorInfo.height - top - size.height, width: size.width, height: size.height)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        scheduleHide()
    }

    func hide() {
        hideTask?.cancel()
        undo = nil
        panel.orderOut(nil)
    }

    private func takeBack() {
        let undo = undo
        hide()
        LastChange.shared.clear()
        undo?()
    }

    private func hover(_ hovering: Bool) {
        if hovering { hideTask?.cancel() } else { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try await Task.sleep(for: Self.duration)
            LayoutToast.shared.hide()
        }
    }
}

// MARK: Undo

/// The last change nanopress made on its own, so that the menu panel can still undo it after the note is gone. A newer
/// change replaces it
@MainActor
final class LastChange: ObservableObject {
    static let shared = LastChange()

    struct Entry {
        let message: String
        let action: String
        let undo: @MainActor () -> Void
    }

    @Published private(set) var entry: Entry? = nil

    private init() {}

    func record(_ message: String, action: String, undo: @escaping @MainActor () -> Void) {
        entry = Entry(message: message, action: action, undo: undo)
    }

    func clear() {
        entry = nil
    }

    func undo() {
        guard let entry else { return }
        self.entry = nil
        LayoutToast.shared.hide()
        entry.undo()
    }
}

/// Shows the note for a change nanopress made to `workspace`. Undo puts back `before`, a snapshot taken right before
@MainActor
func offerUndo(_ message: String, action: String = "Undo", workspace: Workspace, before: SimNode, near windowId: UInt32?) {
    let sim = SimNode.snapshot(workspace)
    let tile = windowId.flatMap { id in arrangedTiles(sim, on: workspace).first { $0.windowIds.contains(id) }?.rect }
    LayoutToast.shared.show(message, action: action, near: tile, on: workspace.workspaceMonitor) {
        guard let token: RunSessionGuard = .isServerEnabled else { return }
        Task.startUnstructured {
            try await runLightSession(.menuBarButton, token) { restoreLayout(before, into: workspace) }
        }
    }
}

/// Rebuilds `workspace` from a snapshot taken earlier. Windows that closed meanwhile are left out, windows that
/// appeared meanwhile get a tile of their own
@MainActor
func restoreLayout(_ before: SimNode, into workspace: Workspace) {
    let current = workspace.rootTilingContainer.allLeafWindowsRecursive
    for simWindow in before.allWindows where !current.contains(where: { $0.windowId == simWindow.windowId }) {
        simWindow.unbind()
    }
    before.normalizeContainers()
    var windows: [UInt32: Window] = [:]
    for window in current { windows[window.windowId] = window }
    let kept = Set(before.allWindows.compactMap(\.windowId))
    before.materialize(into: workspace, windows: windows)
    for window in current where !kept.contains(window.windowId) {
        window.bind(to: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    }
}

/// "Mail", "Mail and Notes", "3 windows"
@MainActor
func windowNames(_ ids: [UInt32]) -> String {
    let names = ids.map { Window.get(byId: $0)?.app.name ?? "Window" }
    return switch names.count {
        case 1: names[0]
        case 2: "\(names[0]) and \(names[1])"
        default: "\(names.count) windows"
    }
}

// MARK: View

@MainActor
private final class LayoutToastModel: ObservableObject {
    @Published var message = ""
    @Published var action = "Undo"
}

private struct LayoutToastView: View {
    @ObservedObject var model: LayoutToastModel
    let takeBack: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(model.message)
                .font(.system(size: 13))
                .lineLimit(1)
            Button(action: takeBack) {
                Text(model.action)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
        .padding(16)
        .fixedSize()
    }
}

/// Takes the first click without the panel becoming key, and pauses the note while the pointer is on it
private final class LayoutToastHostingView: NSHostingView<LayoutToastView> {
    var onHover: ((Bool) -> Void)? = nil
    private var trackingArea: NSTrackingArea? = nil

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(false)
    }
}
