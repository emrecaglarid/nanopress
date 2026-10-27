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
    /// The window under the cursor, where it is now. It's dimmed, with the drop zones drawn on it
    var targetRect: CGRect?
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
        present(on: preview.monitorRect)
        model.preview = preview
    }

    /// Previews an Arrange option from the menu: every tile where it ends up
    func showArrangement(_ tiles: [ArrangedTile], monitorRect: CGRect) {
        present(on: monitorRect)
        model.arrangement = ArrangementPreview(monitorRect: monitorRect, tiles: tiles)
    }

    private func present(on monitor: CGRect) {
        hideTask?.cancel()
        let frame = NSRect(x: monitor.minX, y: mainMonitorInfo.height - monitor.maxY, width: monitor.width, height: monitor.height)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() {
        if model.preview == nil && model.arrangement == nil { return }
        model.preview = nil
        model.arrangement = nil
        hideTask = Task.startUnstructured { @MainActor [panel] in
            try await Task.sleep(for: .milliseconds(200)) // Let the fade out finish
            panel.orderOut(nil)
        }
    }
}

private final class DropOverlayModel: ObservableObject {
    @Published var preview: DropPreview? = nil
    @Published var arrangement: ArrangementPreview? = nil
}

private struct ArrangementPreview: Equatable {
    let monitorRect: CGRect
    let tiles: [ArrangedTile]
}

private let regionInset: CGFloat = 4
private let regionRadius: CGFloat = 10

private struct DropOverlayView: View {
    @ObservedObject var model: DropOverlayModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let preview = model.preview {
                DropPreviewView(preview: preview)
                    .transition(.opacity)
            }
            if let arrangement = model.arrangement {
                ArrangementPreviewView(arrangement: arrangement)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(reduceMotion ? nil : .timingCurve(0.2, 0, 0, 1, duration: 0.15), value: model.preview)
        .animation(reduceMotion ? nil : .timingCurve(0.2, 0, 0, 1, duration: 0.15), value: model.arrangement)
        .accessibilityHidden(true)
    }
}

/// Two layers: the window under the cursor dimmed and blurred, with its drop zones in white, and the zone under the
/// cursor in blue, drawn as where the window lands, with what it does written inside. The middle box is cut out of the
/// blue, so that it always keeps the window's tint
private struct DropPreviewView: View {
    let preview: DropPreview

    var body: some View {
        let landing = local(preview.landingRect).insetBy(dx: regionInset, dy: regionInset)
        let target = preview.targetRect.map { local($0).insetBy(dx: regionInset, dy: regionInset) }
        let middle = preview.targetRect.map { local(dropZoneMiddle(of: $0)) }
        let isMiddle = preview.action == .stack || preview.action == .swap
        ZStack(alignment: .topLeading) {
            if let origin = preview.originRect {
                OriginRegion()
                    .placed(in: local(origin).insetBy(dx: regionInset, dy: regionInset))
                    .transition(.opacity)
            }
            if let target {
                TargetScrim()
                    .placed(in: target)
                ZoneArrows(target: target)
            }
            if !isMiddle {
                LandingZone(landing: landing, hole: middle)
                Text(preview.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .fixedSize()
                    .position(x: landing.midX, y: landing.minY + min(120, landing.height * 0.22))
            }
            if let middle {
                MiddleZone(active: isMiddle ? preview.action : nil)
                    .placed(in: middle)
            }
            if preview.optionCount > 1 {
                Text("\(preview.optionIndex + 1) of \(preview.optionCount), Tab for the next")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .fixedSize()
                    .position(x: landing.midX, y: landing.minY + min(120, landing.height * 0.22) + 22)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func local(_ rect: CGRect) -> CGRect {
        rect.offsetBy(dx: -preview.monitorRect.minX, dy: -preview.monitorRect.minY)
    }
}

/// Mutes whatever the window shows, so that the hints on top read over any content
private struct TargetScrim: View {
    var body: some View {
        BehindWindowBlur()
            .overlay(Color.black.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: regionRadius, style: .continuous))
    }
}

/// The edge zones, one arrow each
private struct ZoneArrows: View {
    let target: CGRect

    var body: some View {
        let inset: CGFloat = 36
        ZStack(alignment: .topLeading) {
            arrow("arrow.up").position(x: target.midX, y: target.minY + inset)
            arrow("arrow.down").position(x: target.midX, y: target.maxY - inset)
            arrow("arrow.left").position(x: target.minX + inset, y: target.midY)
            arrow("arrow.right").position(x: target.maxX - inset, y: target.midY)
        }
    }

    private func arrow(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.white.opacity(0.85))
    }
}

/// Stack on the left half, swap on the right. The half under the cursor fills in
private struct MiddleZone: View {
    let active: DropPreview.Action?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        HStack(spacing: 0) {
            half("Stack", isActive: active == .stack)
            Rectangle().fill(.white.opacity(0.7)).frame(width: 1.5)
            half("Swap", isActive: active == .swap)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.7), lineWidth: 1.5))
    }

    private func half(_ title: String, isActive: Bool) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(isActive ? 1 : 0.9))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(isActive ? Color.accentColor.opacity(0.85) : .clear)
    }
}

/// Where the window lands, in blue, with the middle box cut out
private struct LandingZone: View {
    let landing: CGRect
    let hole: CGRect?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: regionRadius, style: .continuous)
        ZStack(alignment: .topLeading) {
            shape
                .fill(Color.accentColor.opacity(0.72))
                .placed(in: landing)
            shape
                .strokeBorder(.white.opacity(0.6), lineWidth: 1.5)
                .placed(in: landing)
        }
        // The whole overlay, so that the mask below is in the same coordinates as `hole`
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .mask {
            // Even-odd: the landing rect without the middle box
            Path { path in
                path.addRect(CGRect(x: -10_000, y: -10_000, width: 20_000, height: 20_000))
                if let hole { path.addRoundedRect(in: hole, cornerSize: CGSize(width: 12, height: 12), style: .continuous) }
            }
            .fill(style: FillStyle(eoFill: true))
        }
    }
}

/// A see-through blur of what's behind the overlay. SwiftUI's materials only blur what's inside the window
private struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Every tile in the landing style, with the app name as prominent as the hover card's title
private struct ArrangementPreviewView: View {
    let arrangement: ArrangementPreview

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(arrangement.tiles) { tile in
                LandingRegion(isBackCard: false)
                    .overlay {
                        Text(tile.stackCount > 1 ? "\(tile.name) +\(tile.stackCount - 1)" : tile.name)
                            .font(.system(size: 16, weight: .semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 11)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                            .fixedSize()
                    }
                    .placed(in: tile.rect
                        .offsetBy(dx: -arrangement.monitorRect.minX, dy: -arrangement.monitorRect.minY)
                        .insetBy(dx: regionInset, dy: regionInset))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The empty tile the window was dragged out of
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

extension DropPreview {
    /// What the drop does, in words
    var title: String {
        let target = targetName ?? "window"
        switch action {
            case .split(.left, .screen): return "Left side of screen"
            case .split(.right, .screen): return "Right side of screen"
            case .split(.up, .screen): return "Top of screen"
            case .split(.down, .screen): return "Bottom of screen"
            case .split(let direction, let group):
                let anchor = switch group {
                    case .row: "\(target)'s row"
                    case .column: "\(target)'s column"
                    case .screen, nil: target
                }
                return switch direction {
                    case .left: "Left of \(anchor)"
                    case .right: "Right of \(anchor)"
                    case .up: "Above \(anchor)"
                    case .down: "Below \(anchor)"
                }
            case .stack: return "Stack on \(target)"
            case .swap: return "Swap with \(target)"
            case .moveToWorkspace(let workspace): return "Move to workspace \(workspace)"
        }
    }
}

extension View {
    fileprivate func placed(in rect: CGRect) -> some View {
        frame(width: max(rect.width, 0), height: max(rect.height, 0))
            .offset(x: rect.minX, y: rect.minY)
    }
}
