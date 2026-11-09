import AppKit
import Common
import SwiftUI

/// A ring in the accent color around the stack a visitor just went into, so that the eye follows it there. It fades
/// in, holds for a moment and fades out. See Visitors
@MainActor
final class VisitorHighlight {
    static let shared = VisitorHighlight()

    private let model = VisitorHighlightModel()
    private var hideTask: Task<(), any Error>? = nil
    private lazy var panel: NSPanel = {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.contentView = NSHostingView(rootView: VisitorHighlightView(model: model))
        return panel
    }()

    /// Room outside the stack for the ring, so that it doesn't cover the window's edge
    private static let outset: CGFloat = 4

    private init() {}

    /// `rect` is in global coordinates with the origin in the top left corner of the main monitor, like Rect
    func show(around rect: CGRect) {
        if isUnitTest { return }
        hideTask?.cancel()
        let o = Self.outset
        let frame = NSRect(x: rect.minX - o, y: mainMonitorInfo.height - rect.maxY - o, width: rect.width + 2 * o, height: rect.height + 2 * o)
        model.isShown = false
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        withAnimation(.easeOut(duration: 0.18)) { model.isShown = true }
        hideTask = Task.startUnstructured { @MainActor [model, panel] in
            try await Task.sleep(for: .milliseconds(1400))
            withAnimation(.easeIn(duration: 0.5)) { model.isShown = false }
            try await Task.sleep(for: .milliseconds(500))
            panel.orderOut(nil)
        }
    }
}

@MainActor
private final class VisitorHighlightModel: ObservableObject {
    @Published var isShown = false
}

private struct VisitorHighlightView: View {
    @ObservedObject var model: VisitorHighlightModel

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        shape
            .fill(Color.accentColor.opacity(0.08))
            .overlay(shape.strokeBorder(Color.accentColor, lineWidth: 3))
            .opacity(model.isShown ? 1 : 0)
            // Settles onto the stack from a little further out
            .scaleEffect(model.isShown ? 1 : 1.015)
    }
}
