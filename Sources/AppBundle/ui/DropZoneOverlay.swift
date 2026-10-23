import AppKit
import Common
import SwiftUI

/// What the overlay shows while a window is dragged with the mouse.
/// All rects are in global coordinates with the origin in the top left corner of the main monitor, same as Rect
struct DropPreview: Equatable {
    /// A split can target a group the hovered tile is at the edge of, instead of the tile itself
    enum Group: Equatable {
        case row, column, screen
    }

    enum Action: Equatable {
        case split(CardinalDirection, Group?)
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
    /// The empty tile the window was dragged out of
    var originRect: CGRect?
    /// Where the dragged window ends up. It's the whole stack if the window ends up in one
    var landingRect: CGRect
    var landingStackCount: Int
    var ghosts: [Ghost]
    /// Tab steps through the options when the cursor is where several drops are possible
    var optionIndex: Int
    var optionCount: Int
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
            if let origin = preview.originRect {
                OriginRegion()
                    .placed(in: local(origin).insetBy(dx: regionInset, dy: regionInset))
                    .transition(.opacity)
            }
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
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                    .fixedSize()
            }
    }
}

/// Below the ghosts: the tiles that fill the gap are drawn on top of it
private struct OriginRegion: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: regionRadius, style: .continuous)
        shape
            .fill(Color.primary.opacity(0.04))
            .overlay(shape.strokeBorder(Color.primary.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
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
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .id(icon)
                    .transition(reduceMotion ? .opacity : iconTransition)
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
            }
            switch preview.action {
                case .stack: KeyHint(before: "Hold", key: "⌥", keyName: "Option", after: "to swap")
                case .swap: KeyHint(before: "Release", key: "⌥", keyName: "Option", after: "to stack")
                case .split, .moveToWorkspace: EmptyView()
            }
            if preview.optionCount > 1 {
                HStack(spacing: 6) {
                    Text("\(preview.optionIndex + 1) of \(preview.optionCount)")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    KeyHint(before: nil, key: "Tab", keyName: "Tab", after: "next")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
        .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
        .fixedSize()
    }

    private var targetName: String { preview.targetName ?? "window" }

    private var title: String {
        switch preview.action {
            case .split(.left, .screen): "Left side of screen"
            case .split(.right, .screen): "Right side of screen"
            case .split(.up, .screen): "Top of screen"
            case .split(.down, .screen): "Bottom of screen"
            case .split(let direction, let group): splitTitle(direction, group)
            case .stack: "Stack on \(targetName)"
            case .swap: "Swap with \(targetName)"
            case .moveToWorkspace(let workspace): "Move to workspace \(workspace)"
        }
    }

    private func splitTitle(_ direction: CardinalDirection, _ group: DropPreview.Group?) -> String {
        let anchor = switch group {
            case .row: "\(targetName)'s row"
            case .column: "\(targetName)'s column"
            case .screen, nil: targetName
        }
        return switch direction {
            case .left: "Left of \(anchor)"
            case .right: "Right of \(anchor)"
            case .up: "Above \(anchor)"
            case .down: "Below \(anchor)"
        }
    }

    private var icon: String {
        switch preview.action {
            case .split(.left, _): "rectangle.lefthalf.inset.filled"
            case .split(.right, _): "rectangle.righthalf.inset.filled"
            case .split(.up, _): "rectangle.tophalf.inset.filled"
            case .split(.down, _): "rectangle.bottomhalf.inset.filled"
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

private struct KeyHint: View {
    let before: String?
    let key: String
    let keyName: String
    let after: String

    var body: some View {
        HStack(spacing: 4) {
            if let before { Text(before) }
            Text(key)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .frame(minWidth: 18, minHeight: 18)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .accessibilityLabel(keyName)
            Text(after)
        }
        .font(.system(size: 12, weight: .medium, design: .rounded))
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
