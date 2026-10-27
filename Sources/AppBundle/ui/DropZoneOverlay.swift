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
    /// The zone under the cursor, drawn in blue: half of the window on that side, the whole window to stack or swap.
    /// Where the window ends up can differ once the layout settles, which is what landingRect is
    var zoneRect: CGRect?
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
    @ObservedObject private var settings = NanopressSettings.shared

    var body: some View {
        // The blue goes where the cursor is, so that it always matches the hints
        let landing = local(preview.zoneRect ?? preview.landingRect).insetBy(dx: regionInset, dy: regionInset)
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
                TargetScrim(dimming: settings.dragDimming, blur: settings.dragBlur)
                    .placed(in: target)
                ZoneArrows(target: target, color: hintColor)
            }
            LandingZone(landing: landing, hole: middle)
            if preview.action == .stack {
                // The dragged window takes the spot and gets a tab next to the window that was there, where the tabs go
                StackTabsPreview(count: preview.landingStackCount, atTop: settings.tabsPosition == .top)
                    .id("\(preview.landingRect)") // Plays again when the cursor moves to another window
                    .placed(in: landing)
            }
            if preview.action == .swap, let origin = preview.originRect {
                // The other half of a swap: where the window under the cursor goes
                SwapDestination(name: preview.targetName ?? "It")
                    .placed(in: local(origin).insetBy(dx: regionInset, dy: regionInset))
            }
            Text(preview.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                .fixedSize()
                .position(x: landing.midX, y: landing.minY + min(120, landing.height * 0.22))
            if let middle {
                MiddleZone(active: isMiddle ? preview.action : nil, color: hintColor, tabsAtTop: settings.tabsPosition == .top)
                    .placed(in: middle)
            }
            if preview.optionCount > 1 {
                HStack(spacing: 6) {
                    Text("\(preview.optionIndex + 1) of \(preview.optionCount)")
                    Keycap(label: "Tab")
                    Text("for the next")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                .fixedSize()
                .position(x: landing.midX, y: landing.minY + min(120, landing.height * 0.22) + 26)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Dark on a light scrim, white once it's dimmed enough to be dark
    private var hintColor: Color { settings.dragDimming > 0.35 ? .white : .primary }

    private func local(_ rect: CGRect) -> CGRect {
        rect.offsetBy(dx: -preview.monitorRect.minX, dy: -preview.monitorRect.minY)
    }
}

/// Mutes whatever the window shows, so that the hints on top read over any content
private struct TargetScrim: View {
    let dimming: Double
    let blur: Bool

    var body: some View {
        ZStack {
            if blur { BehindWindowBlur() }
            Color.black.opacity(dimming)
        }
        .clipShape(RoundedRectangle(cornerRadius: regionRadius, style: .continuous))
    }
}

/// The edge zones, one arrow each
private struct ZoneArrows: View {
    let target: CGRect
    let color: Color

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
            .foregroundStyle(color.opacity(0.75))
    }
}

/// Stack on the left half, swap on the right. The half under the cursor fills in, and its icon shows what it does
private struct MiddleZone: View {
    let active: DropPreview.Action?
    let color: Color
    let tabsAtTop: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        HStack(spacing: 0) {
            half("Stack", isActive: active == .stack) { StackGlyph(isAnimating: active == .stack, tabsAtTop: tabsAtTop) }
            Rectangle().fill(color.opacity(0.5)).frame(width: 1.5)
            half("Swap", isActive: active == .swap) { SwapGlyph(isAnimating: active == .swap) }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(color.opacity(0.5), lineWidth: 1.5))
    }

    private func half(_ title: String, isActive: Bool, @ViewBuilder glyph: () -> some View) -> some View {
        VStack(spacing: 6) {
            glyph()
            Text(title).font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(isActive ? Color.white : color.opacity(0.85))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isActive ? Color.accentColor.opacity(0.85) : .clear)
    }
}

/// Strong ease-out for things arriving, strong ease-in-out for things trading places on screen
private let arriveCurve = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.22)
private let tradeCurve = Animation.timingCurve(0.77, 0, 0.175, 1, duration: 0.25)

/// A window with its tabs. On hover, once: the window shrinks into a new tab, and a new window takes its place with its
/// own tab in front. The tabs are on the side the setting puts them
private struct StackGlyph: View {
    let isAnimating: Bool
    let tabsAtTop: Bool
    @State private var stacked = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let window = RoundedRectangle(cornerRadius: 2.5, style: .continuous)
        let tab = RoundedRectangle(cornerRadius: 1.5, style: .continuous)
        VStack(spacing: 2) {
            if tabsAtTop { tabs(tab) }
            ZStack {
                // The window that was there, shrinking toward its new tab
                window.strokeBorder(lineWidth: 1.5)
                    .scaleEffect(stacked && !reduceMotion ? 0.35 : 1, anchor: tabsAtTop ? .topLeading : .bottomLeading)
                    .opacity(stacked ? 0 : 1)
                // The dragged window, taking its place
                window.fill().opacity(stacked ? 0.9 : 0)
            }
            .frame(width: 22, height: 14)
            if !tabsAtTop { tabs(tab) }
        }
        .frame(width: 26, height: 22)
        .onChange(of: isAnimating) { isAnimating in playOnce(isAnimating) }
        .onAppear { playOnce(isAnimating) }
    }

    /// The window that was there keeps its tab; the new one's tab appears in front
    private func tabs(_ tab: RoundedRectangle) -> some View {
        HStack(spacing: 1.5) {
            tab.strokeBorder(lineWidth: 1).frame(width: 7, height: 4)
            tab.fill().frame(width: 7, height: 4)
                .opacity(stacked ? 1 : 0)
                .scaleEffect(x: stacked || reduceMotion ? 1 : 0.6, y: 1, anchor: .leading)
            Spacer(minLength: 0)
        }
        .frame(width: 22)
    }

    private func playOnce(_ isAnimating: Bool) {
        guard isAnimating else { return stacked = false }
        stacked = false
        DispatchQueue.main.async { withAnimation(arriveCurve) { stacked = true } }
    }
}

/// Two squares trading places, once, when Swap is hovered. Back where they started when the cursor leaves
private struct SwapGlyph: View {
    let isAnimating: Bool
    @State private var swapped = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        ZStack {
            shape.strokeBorder(lineWidth: 1.5).frame(width: 10, height: 13).offset(x: swapped ? 6 : -6)
            shape.fill().frame(width: 10, height: 13).offset(x: swapped ? -6 : 6)
        }
        .frame(width: 24, height: 20)
        .onChange(of: isAnimating) { isAnimating in playOnce(isAnimating) }
        .onAppear { playOnce(isAnimating) }
    }

    private func playOnce(_ isAnimating: Bool) {
        guard isAnimating else { return swapped = false }
        if reduceMotion { return swapped = true }
        withAnimation(tradeCurve) { swapped = true }
    }
}

/// On Stack: the tabs the stack will have, on the side the setting puts them. The dragged window's tab slides in last,
/// in front, once
private struct StackTabsPreview: View {
    /// Windows in the stack after the drop, the dragged one included
    let count: Int
    let atTop: Bool
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let tab = RoundedRectangle(cornerRadius: 6, style: .continuous)
        VStack(spacing: 0) {
            if !atTop { Spacer(minLength: 0) }
            HStack(spacing: 3) {
                ForEach(0 ..< max(count - 1, 1), id: \.self) { _ in
                    tab.fill(Color.white.opacity(0.35)).frame(width: 72, height: 22)
                }
                // The new one, in front
                tab.fill(Color.white.opacity(0.95)).frame(width: 72, height: 22)
                    .overlay(tab.strokeBorder(Color.accentColor, lineWidth: 1.5))
                    .opacity(shown ? 1 : 0)
                    .offset(x: shown || reduceMotion ? 0 : -12)
                Spacer(minLength: 0)
            }
            .padding(10)
            if atTop { Spacer(minLength: 0) }
        }
        .onAppear {
            withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.2)) { shown = true }
        }
    }
}

/// On Swap: the empty slot the dragged window came from, which the other window takes
private struct SwapDestination: View {
    let name: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: regionRadius, style: .continuous)
        shape
            .fill(Color.accentColor.opacity(0.18))
            .overlay(shape.strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 5])))
            .overlay {
                Text("\(name) moves here")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
            }
    }
}

/// A key, drawn like one
private struct Keycap: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 6)
            .frame(minHeight: 18)
            .background(Color.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.white.opacity(0.6), lineWidth: 1))
            .accessibilityLabel(label)
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
                .fill(Color.accentColor.opacity(0.55))
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
        view.material = .popover
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
