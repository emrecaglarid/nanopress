import AppKit
import Common
import SwiftUI

/// What the overlay shows while a window is dragged with the mouse.
/// All rects are in global coordinates with the origin in the top left corner of the main monitor, same as Rect
struct DropPreview: Equatable {
    enum Action: Equatable {
        case split(CardinalDirection)
        case stack
        case swap
        case moveToWorkspace(String)
    }

    /// A tile that moves or resizes because of the drop, drawn where it ends up
    struct Ghost: Equatable, Identifiable {
        /// The window on top of the tile
        let id: UInt32
        let rect: CGRect
        let name: String
        let stackCount: Int
    }

    var action: Action
    var targetName: String?
    var monitorRect: CGRect
    /// Where the dragged window ends up. It's the whole stack if the window ends up in one
    var landingRect: CGRect
    var landingStackCount: Int
    var ghosts: [Ghost]
}

extension Rect {
    var cgRect: CGRect { CGRect(x: minX, y: minY, width: width, height: height) }
}

/// Transparent full monitor panel that previews where a window dragged with the mouse lands
@MainActor
final class DropZoneOverlay {
    static let shared = DropZoneOverlay()

    private let model = DropOverlayModel()
    private var hideTask: Task<(), any Error>? = nil
    private lazy var panel: NSPanel = {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false,
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.contentView = NSHostingView(rootView: DropOverlayView(model: model))
        return panel
    }()

    private init() {}

    func show(_ preview: DropPreview) {
        hideTask?.cancel()
        let monitor = preview.monitorRect
        let frame = NSRect(x: monitor.minX, y: mainMonitorInfo.height - monitor.maxY, width: monitor.width, height: monitor.height)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        model.preview = preview
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() {
        if model.preview == nil { return }
        model.preview = nil
        hideTask = Task.startUnstructured { @MainActor [panel] in
            try await Task.sleep(for: .milliseconds(200)) // Let the fade out finish
            panel.orderOut(nil)
        }
    }
}

private final class DropOverlayModel: ObservableObject {
    @Published var preview: DropPreview? = nil
}

private let regionInset: CGFloat = 4
private let regionRadius: CGFloat = 10
/// How far the card behind a stack peeks out
private let stackPeek: CGFloat = 12

private struct DropOverlayView: View {
    @ObservedObject var model: DropOverlayModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let preview = model.preview {
                DropPreviewView(preview: preview)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(reduceMotion ? nil : .timingCurve(0.2, 0, 0, 1, duration: 0.15), value: model.preview)
        .accessibilityHidden(true)
    }
}

private struct DropPreviewView: View {
    let preview: DropPreview

    var body: some View {
        let landing = local(preview.landingRect).insetBy(dx: regionInset, dy: regionInset)
        ZStack(alignment: .topLeading) {
            ForEach(preview.ghosts) { ghost in
                GhostTile(ghost: ghost)
                    .placed(in: local(ghost.rect).insetBy(dx: regionInset, dy: regionInset))
                    .transition(.opacity)
            }
            if preview.landingStackCount > 1 {
                // Only the top edge peeks out. The front card is translucent, so the rest would show through
                LandingRegion(isBackCard: true)
                    .mask(alignment: .top) { Rectangle().frame(height: stackPeek) }
                    .placed(in: CGRect(x: landing.minX + 2 * stackPeek, y: landing.minY, width: landing.width - 4 * stackPeek, height: landing.height - stackPeek))
                LandingRegion(isBackCard: false)
                    .placed(in: CGRect(x: landing.minX, y: landing.minY + stackPeek, width: landing.width, height: landing.height - stackPeek))
            } else {
                LandingRegion(isBackCard: false)
                    .placed(in: landing)
            }
            DropHoverCard(preview: preview)
                .position(x: landing.midX, y: landing.midY)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func local(_ rect: CGRect) -> CGRect {
        rect.offsetBy(dx: -preview.monitorRect.minX, dy: -preview.monitorRect.minY)
    }
}

private struct GhostTile: View {
    let ghost: DropPreview.Ghost

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: regionRadius, style: .continuous)
        shape
            .fill(Color.primary.opacity(0.06))
            .overlay(shape.strokeBorder(Color.primary.opacity(0.45), lineWidth: 1.5))
            .overlay {
                Text(ghost.stackCount > 1 ? "\(ghost.name) +\(ghost.stackCount - 1)" : ghost.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .fixedSize()
            }
    }
}

private struct LandingRegion: View {
    let isBackCard: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: regionRadius, style: .continuous)
        shape
            .fill(Color.accentColor.opacity(isBackCard ? 0.08 : 0.16))
            .overlay(shape.strokeBorder(Color.accentColor.opacity(isBackCard ? 0.4 : 0.9), lineWidth: 2))
    }
}

private struct DropHoverCard: View {
    let preview: DropPreview
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .id(icon)
                    .transition(reduceMotion ? .opacity : iconTransition)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }
            switch preview.action {
                case .stack: ModifierHint(before: "Hold", after: "to swap")
                case .swap: ModifierHint(before: "Release", after: "to stack")
                case .split, .moveToWorkspace: EmptyView()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
        .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
        .fixedSize()
    }

    private var targetName: String { preview.targetName ?? "window" }

    private var title: String {
        switch preview.action {
            case .split(.left): "Left of \(targetName)"
            case .split(.right): "Right of \(targetName)"
            case .split(.up): "Above \(targetName)"
            case .split(.down): "Below \(targetName)"
            case .stack: "Stack on \(targetName)"
            case .swap: "Swap with \(targetName)"
            case .moveToWorkspace(let workspace): "Move to workspace \(workspace)"
        }
    }

    private var icon: String {
        switch preview.action {
            case .split(.left): "rectangle.lefthalf.inset.filled"
            case .split(.right): "rectangle.righthalf.inset.filled"
            case .split(.up): "rectangle.tophalf.inset.filled"
            case .split(.down): "rectangle.bottomhalf.inset.filled"
            case .stack: "square.stack"
            case .swap: "arrow.left.arrow.right"
            case .moveToWorkspace: "macwindow.on.rectangle"
        }
    }

    private var iconTransition: AnyTransition {
        .modifier(active: BlurModifier(radius: 4), identity: BlurModifier(radius: 0))
            .combined(with: .scale(scale: 0.25))
            .combined(with: .opacity)
    }
}

private struct ModifierHint: View {
    let before: String
    let after: String

    var body: some View {
        HStack(spacing: 4) {
            Text(before)
            Text("⌥")
                .font(.system(size: 10, weight: .medium))
                .frame(minWidth: 16, minHeight: 16)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .accessibilityLabel("Option")
            Text(after)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
}

private struct BlurModifier: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View { content.blur(radius: radius) }
}

extension View {
    fileprivate func placed(in rect: CGRect) -> some View {
        frame(width: max(rect.width, 0), height: max(rect.height, 0))
            .offset(x: rect.minX, y: rect.minY)
    }
}
