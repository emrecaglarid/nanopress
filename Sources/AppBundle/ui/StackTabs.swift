import AppKit
import Common
import SwiftUI

/// Room above a stack for its tabs, including the gap between the tabs and the windows
let stackTabsHeight: CGFloat = 32
private let tabsGap: CGFloat = 4
/// Around the tabs, inside the strip
private let stripPadding: CGFloat = 3
private let pillRadius: CGFloat = 7
/// Concentric with the pills inside it
private let stripRadius: CGFloat = pillRadius + stripPadding

/// Every stack on screen gets a row of tabs above it, one per window, like browser tabs. A stack otherwise looks like a
/// single window, and the windows behind it are easy to forget.
/// Click a tab to bring its window forward, scroll over the tabs to flip through them, drag a tab to take its window out
/// of the stack: onto another window to split it, or onto another stack's tabs to join it. "+" at the end lists the windows
/// outside the stack, to bring one in
@MainActor
final class StackTabs {
    static let shared = StackTabs()

    private var strips: [ObjectIdentifier: TabStrip] = [:]
    private var titles: [UInt32: String] = [:]
    private var titlesTask: Task<(), Never>? = nil
    /// Where the tab being dragged would go
    private var tabDrop: PendingDrop? = nil
    /// Minimized windows and windows of hidden apps that were picked from "+", by window id. They join the stack once
    /// they're back on screen. See takePendingJoin
    private var pendingJoins: [UInt32: TilingContainer] = [:]

    private init() {}

    /// Called after every layout
    func update() {
        let stacks = TrayMenuModel.shared.isEnabled && !isUnitTest
            ? monitorInfos.flatMap { visibleStacks($0.activeWorkspace.rootTilingContainer) }
            : []
        var alive: Set<ObjectIdentifier> = []
        for stack in stacks {
            guard let rect = stack.lastAppliedLayoutPhysicalRect else { continue }
            let id = ObjectIdentifier(stack)
            alive.insert(id)
            let strip = strips[id] ?? TabStrip(stack: stack)
            strips[id] = strip
            strip.stack = stack
            strip.update(tabs: tabs(of: stack), front: stack.mostRecentChild?.mostRecentWindowRecursive?.windowId, frame: stripFrame(rect))
        }
        for (id, strip) in strips where !alive.contains(id) {
            strip.close()
            strips[id] = nil
        }
        DockBadges.shared.isWatching = !strips.isEmpty
        fetchTitles(stacks.flatMap { $0.children.compactMap(\.mostRecentWindowRecursive) })
    }

    // MARK: Tabs

    private func visibleStacks(_ node: TilingContainer) -> [TilingContainer] {
        let own = node.layout == .accordion && node.children.count > 1 ? [node] : []
        return own + node.children.compactMap { $0 as? TilingContainer }.flatMap(visibleStacks)
    }

    /// In the order of the stack, which stays put as windows come forward
    private func tabs(of stack: TilingContainer) -> [StackTab] {
        stack.children.compactMap(\.mostRecentWindowRecursive).map { window in
            let app = window.app.name ?? "Window"
            return StackTab(windowId: window.windowId, app: app, title: titles[window.windowId].flatMap { $0.isEmpty ? nil : $0 } ?? app)
        }
    }

    /// The room for the tabs at the top or bottom of the stack's rect, in AppKit coordinates
    private func stripFrame(_ stack: Rect) -> NSRect {
        let height = stackTabsHeight - tabsGap
        let top = NanopressSettings.shared.tabsPosition == .top ? stack.minY : stack.maxY - height
        return NSRect(x: stack.minX, y: mainMonitorInfo.height - top - height, width: stack.width, height: height)
    }

    private func fetchTitles(_ windows: [Window]) {
        titlesTask?.cancel()
        titlesTask = Task { @MainActor in
            var changed = false
            for window in windows {
                guard let title = try? await window.getTitle(.cancellable), !Task.isCancelled else { return }
                if titles[window.windowId] != title {
                    titles[window.windowId] = title
                    changed = true
                }
            }
            if changed {
                for strip in strips.values {
                    if let stack = strip.stack { strip.update(tabs: tabs(of: stack)) }
                }
            }
        }
    }

    func bringForward(_ windowId: UInt32) {
        guard let token: RunSessionGuard = .isServerEnabled else { return }
        Task.startUnstructured {
            try await runLightSession(.menuBarButton, token) { _ = Window.get(byId: windowId)?.focusWindow() }
        }
    }

    // MARK: Bringing a window into a stack

    /// Every window outside `stack`: the stack's workspace first, then the other workspaces, then minimized windows
    /// and windows of hidden apps. Where a window is shows quietly after its name. Picking one moves it into the stack
    fileprivate func addMenu(for stack: TilingContainer) async -> NSMenu {
        let inStack = Set(stack.allLeafWindowsRecursive.map(\.windowId))
        let here = stack.nodeWorkspace
        let windows = MacWindow.allWindows.filter { !inStack.contains($0.windowId) }.sorted { $0.windowId < $1.windowId }
        var entries: [(window: Window, place: String?)] = []
        for workspace in [here].compactMap(\.self) + Workspace.all.filter({ $0 != here }) {
            for window in windows where (window.parent is TilingContainer || window.parent is FloatingWindowsContainer) && window.nodeWorkspace == workspace {
                entries.append((window, workspace == here ? nil : "Workspace \(workspace.name)"))
            }
        }
        for window in windows where window.parent is MacosMinimizedWindowsContainer {
            entries.append((window, "Minimized"))
        }
        for window in windows where window.parent is MacosHiddenAppsWindowsContainer {
            entries.append((window, "Hidden"))
        }

        let menu = NSMenu()
        menu.autoenablesItems = false
        if #available(macOS 14, *) {
            menu.addItem(.sectionHeader(title: "Bring here"))
        } else {
            let header = NSMenuItem(title: "Bring here", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
        }
        if entries.isEmpty {
            let item = NSMenuItem(title: "No other windows", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        for (window, place) in entries {
            let item = NSMenuItem(title: "", action: #selector(AddMenuTarget.pick(_:)), keyEquivalent: "")
            item.attributedTitle = menuTitle(await windowName(window), place: place)
            item.target = AddMenuTarget.shared
            item.representedObject = AddMenuChoice(windowId: window.windowId, stack: stack)
            if let icon = (window as? MacWindow)?.macApp.nsApp.icon?.copy() as? NSImage {
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
            }
            menu.addItem(item)
        }
        return menu
    }

    private func windowName(_ window: Window) async -> String {
        let app = window.app.name ?? "Window"
        let title = (try? await window.getTitle(.cancellable)) ?? ""
        let text = title.isEmpty || title == app ? app : "\(app): \(title)"
        return text.count > 60 ? String(text.prefix(59)) + "…" : text
    }

    /// "Slack: #design  Workspace 2", the place in a quieter color
    private func menuTitle(_ name: String, place: String?) -> NSAttributedString {
        let font = NSFont.menuFont(ofSize: 0)
        let title = NSMutableAttributedString(string: name, attributes: [.font: font])
        if let place {
            title.append(NSAttributedString(string: "  \(place)", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        return title
    }

    fileprivate func bring(_ windowId: UInt32, into stack: TilingContainer) {
        guard let token: RunSessionGuard = .isServerEnabled else { return }
        Task.startUnstructured {
            try await runLightSession(.menuBarButton, token) {
                guard let window = Window.get(byId: windowId) as? MacWindow, stack.parent != nil else { return }
                switch window.parent {
                    case is MacosMinimizedWindowsContainer:
                        // It comes back through relayoutWindow, which asks takePendingJoin
                        StackTabs.shared.pendingJoins[windowId] = stack
                        window.setNativeMinimized(false)
                    case is MacosHiddenAppsWindowsContainer:
                        StackTabs.shared.pendingJoins[windowId] = stack
                        window.macApp.nsApp.unhide()
                    default:
                        window.bind(to: stack, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
                        _ = window.focusWindow()
                }
            }
        }
    }

    /// Where a minimized or hidden window that was picked from "+" goes now that it's back
    func takePendingJoin(_ windowId: UInt32) -> BindingData? {
        guard let stack = pendingJoins.removeValue(forKey: windowId), stack.parent != nil, stack.layout == .accordion else { return nil }
        return BindingData(parent: stack, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    }

    // MARK: Dragging a tab

    func dragTab(_ windowId: UInt32) {
        guard let window = Window.get(byId: windowId) else { return }
        let point = mouseLocation
        tabDrop = tabDropTarget(window, at: point, on: point.monitorApproximation.activeWorkspace)
        if let drop = tabDrop, let preview = previewDrop(drop, group: nil, optionIndex: 0, optionCount: 1) {
            DropZoneOverlay.shared.show(preview)
        } else {
            DropZoneOverlay.shared.hide()
        }
    }

    func endTabDrag() {
        DropZoneOverlay.shared.hide()
        guard let drop = tabDrop, let token: RunSessionGuard = .isServerEnabled else { return }
        tabDrop = nil
        Task.startUnstructured {
            try await runLightSession(.menuBarButton, token) { applyDrop(drop) }
        }
    }

    /// The same zones as dragging a window by its title bar. Another stack's tabs take the window in, its own stack
    /// only lets it out at the edges
    private func tabDropTarget(_ window: Window, at point: CGPoint, on workspace: Workspace) -> PendingDrop? {
        let tiles = arrangedTiles(SimNode.snapshot(workspace), on: workspace)
        guard let tile = tiles.first(where: { $0.rect.contains(point) }),
              let target = tile.windowIds.first(where: { $0 != window.windowId }) else { return nil }
        let isOwnStack = tile.windowIds.contains(window.windowId)
        let isOnTabs = tile.stackCount > 1 && (NanopressSettings.shared.tabsPosition == .top
            ? point.y < tile.rect.minY + stackTabsHeight
            : point.y > tile.rect.maxY - stackTabsHeight)
        let zone: DropZone
        if isOnTabs {
            if isOwnStack { return nil }
            zone = .stack
        } else {
            zone = dropZone(for: point, in: Rect(topLeftX: tile.rect.minX, topLeftY: tile.rect.minY, width: tile.rect.width, height: tile.rect.height))
            if isOwnStack && (zone == .stack || zone == .swap) { return nil }
        }
        let drop = PendingDrop(window: window, workspace: workspace, op: .tile(targetWindowId: target, zone))
        return simulate(drop) != nil ? drop : nil
    }

    /// One step through the stack per notch, wrapping around
    func flip(_ stack: TilingContainer, by step: Int) {
        let windows = stack.children.compactMap(\.mostRecentWindowRecursive)
        guard let front = stack.mostRecentChild?.mostRecentWindowRecursive,
              let index = windows.firstIndex(where: { $0 === front }), windows.count > 1 else { return }
        bringForward(windows[(index + step + windows.count) % windows.count].windowId)
    }
}

struct StackTab: Identifiable, Equatable {
    let windowId: UInt32
    let app: String
    let title: String

    var id: UInt32 { windowId }
}

@MainActor
final class StackTabsModel: ObservableObject {
    @Published var tabs: [StackTab] = []
    @Published var front: UInt32? = nil
    @Published var isHovered = false
    /// Which side of the stack the tabs are on. The window's side is where the front tab tucks under it
    @Published var atTop = false
    /// More tabs than fit at their natural width: they share the whole bar. See TabStrip.update
    @Published var fillsWidth = false
}

/// The panel with the tabs of one stack
@MainActor
private final class TabStrip {
    weak var stack: TilingContainer?
    private let model = StackTabsModel()
    /// The same tabs, laid out off screen to measure how wide they want to be, so that the bar on screen isn't laid
    /// out twice per change
    private let measureModel = StackTabsModel()
    private let measureView: NSHostingView<StackTabsView>
    private let panel: NSPanel
    private var scrolled: CGFloat = 0
    private var room: NSRect? = nil
    private var switchTask: Task<(), Never>? = nil

    init(stack: TilingContainer) {
        self.stack = stack
        measureView = NSHostingView(rootView: StackTabsView(model: measureModel, addWindow: {}, select: { _ in }))
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .normal
        // Dark glass in either mode: light glass glares on a dark wallpaper, and the white pill stands out on dark
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.ignoresCycle, .fullScreenNone]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        // A label for the stack rather than a window of its own: no shadow
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        var showAddMenu: () -> Void = {}
        var holdAbove: () -> Void = {}
        let model = model
        let view = TabStripHostingView(rootView: StackTabsView(model: model, addWindow: { showAddMenu() }) { windowId in
            // Right away, rather than once the window has come forward
            model.front = windowId
            holdAbove()
            StackTabs.shared.bringForward(windowId)
        })
        // The bar sets its own size. Otherwise the view resizes the window too whenever the tabs change, and the two fight
        view.sizingOptions = []
        view.onScroll = { [weak self] event in self?.scroll(event) }
        view.onHover = { [weak self] hovering in self?.model.isHovered = hovering }
        panel.contentView = view
        showAddMenu = { [weak self] in self?.showAddMenu() }
        holdAbove = { [weak self] in self?.holdAboveWhileSwitching() }
    }

    private func showAddMenu() {
        guard let stack, let view = panel.contentView else { return }
        let panel = panel
        Task { @MainActor in
            let menu = await StackTabs.shared.addMenu(for: stack)
            let location = view.convert(panel.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            menu.popUp(positioning: nil, at: location, in: view)
        }
    }

    /// `frame` is the room above the stack. The bar takes only as much of it as its tabs need, from the leading edge
    func update(tabs: [StackTab], front: UInt32? = nil, frame room: NSRect? = nil) {
        if model.tabs != tabs { model.tabs = tabs }
        if let front, model.front != front { model.front = front }
        let atTop = NanopressSettings.shared.tabsPosition == .top
        if model.atTop != atTop { model.atTop = atTop }
        if let room { self.room = room }
        guard let room = self.room else { return }
        if measureModel.tabs != model.tabs { measureModel.tabs = model.tabs }
        if measureModel.front != model.front { measureModel.front = model.front }
        if measureModel.atTop != atTop { measureModel.atTop = atTop }
        measureView.layoutSubtreeIfNeeded() // So that the size is measured with the tabs just set
        let width = measureView.fittingSize.width
        // Too many tabs to hug: they share the whole width instead
        let fillsWidth = width > room.width
        if model.fillsWidth != fillsWidth { model.fillsWidth = fillsWidth }
        // In whole points, the way the window server keeps it, so that an unchanged frame compares equal and the bar
        // isn't resized and redrawn after every layout
        let frame = NSRect(x: room.minX.rounded(), y: room.minY.rounded(), width: min(width, room.width).rounded(), height: room.height.rounded())
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
        // Right above the stack's front window, and below whatever is above that, like a Finder window over the stack.
        // A window coming forward otherwise covers the strip and drops its shadow on it
        orderAboveFront()
    }

    private func orderAboveFront() {
        guard panel.level == .normal, let front = model.front else { return }
        panel.order(.above, relativeTo: Int(front))
    }

    /// The window picked comes forward a moment later, over the strip, until the next layout puts the strip back on
    /// top. Meanwhile its shadow darkens the strip. Above every window for that moment instead
    private func holdAboveWhileSwitching() {
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 1)
        switchTask?.cancel()
        switchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled else { return }
            panel.level = .normal
            orderAboveFront()
        }
    }

    func close() {
        panel.orderOut(nil)
    }

    private func scroll(_ event: NSEvent) {
        guard let stack else { return }
        // A mouse wheel moves in notches, a trackpad in small steps that add up
        guard event.hasPreciseScrollingDeltas else {
            if event.scrollingDeltaY != 0 { StackTabs.shared.flip(stack, by: event.scrollingDeltaY < 0 ? 1 : -1) }
            return
        }
        if event.phase == .began { scrolled = 0 }
        scrolled += event.scrollingDeltaY
        if abs(scrolled) >= 40 {
            StackTabs.shared.flip(stack, by: scrolled < 0 ? 1 : -1)
            scrolled = 0
        }
    }
}

/// Takes the first click without the panel becoming key, and reports scrolling and hovering, which SwiftUI doesn't
/// for a panel of an app in the background
private final class TabStripHostingView: NSHostingView<StackTabsView> {
    var onScroll: ((NSEvent) -> Void)? = nil
    var onHover: ((Bool) -> Void)? = nil
    private var trackingArea: NSTrackingArea? = nil

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event)
    }

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

struct StackTabsView: View {
    @ObservedObject var model: StackTabsModel
    @ObservedObject private var dock = DockBadges.shared
    let addWindow: () -> Void
    let select: (UInt32) -> Void

    var body: some View {
        // One strip of glass, as wide as its tabs. The window in front gets a pill; the rest are just their names
        HStack(spacing: 2) {
            ForEach(model.tabs) { tab in
                let isFront = tab.windowId == model.front
                // The window in front is in plain sight already
                StackTabButton(tab: tab, isFront: isFront, badge: isFront ? nil : dock.badges[tab.app], fillsWidth: model.fillsWidth) { select(tab.windowId) }
            }
            // Out of sight until the strip is hovered
            AddWindowButton(action: addWindow)
                .opacity(model.isHovered ? 1 : 0)
        }
        .padding(stripPadding)
        .frame(maxWidth: model.fillsWidth ? .infinity : nil, maxHeight: .infinity, alignment: .leading)
        .modifier(StripGlass())
        .fixedSize(horizontal: !model.fillsWidth, vertical: false)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A window picked from the "+" menu
private final class AddMenuChoice: NSObject {
    let windowId: UInt32
    let stack: TilingContainer

    init(windowId: UInt32, stack: TilingContainer) {
        self.windowId = windowId
        self.stack = stack
    }
}

@MainActor
private final class AddMenuTarget: NSObject {
    static let shared = AddMenuTarget()

    @objc func pick(_ item: NSMenuItem) {
        guard let choice = item.representedObject as? AddMenuChoice else { return }
        StackTabs.shared.bring(choice.windowId, into: choice.stack)
    }
}

/// "+" at the end of the tabs, to bring another window into the stack
private struct AddWindowButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26)
                .frame(maxHeight: .infinity)
                .background(tabFill(isFront: false, isHovered: isHovered), in: RoundedRectangle(cornerRadius: pillRadius, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Bring a window here")
        .accessibilityLabel("Bring a window here")
    }
}

private struct StackTabButton: View {
    let tab: StackTab
    let isFront: Bool
    /// The app's Dock badge, like an unread count
    let badge: String?
    /// The tabs share the bar's width instead of taking what their titles need
    let fillsWidth: Bool
    let select: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: select) {
            // A narrow tab is just the icon
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    icon
                    // The app in bold, then the window in a quieter weight: "Dia  Kytöniitty listing"
                    (Text(tab.app).font(.system(size: 12, weight: .semibold)) + Text(detail).font(.system(size: 12)).foregroundColor(isFront ? .black.opacity(0.55) : .secondary))
                        .foregroundColor(isFront ? .black : .secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 220, alignment: .leading)
                        .fixedSize(horizontal: !fillsWidth, vertical: false)
                }
                .frame(minWidth: 64, alignment: .leading)
                icon
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: fillsWidth ? 260 : nil, maxHeight: .infinity, alignment: .leading)
            .background(tabFill(isFront: isFront, isHovered: isHovered), in: pill)
            .shadow(color: .black.opacity(isFront ? 0.12 : 0), radius: 1.5, y: 0.5)
            .contentShape(pill)
        }
        .buttonStyle(.plain)
        .highPriorityGesture(
            DragGesture(minimumDistance: 5)
                .onChanged { _ in StackTabs.shared.dragTab(tab.windowId) }
                .onEnded { _ in StackTabs.shared.endTabDrag() },
        )
        .onHover { isHovered = $0 }
        .help(helpText)
        .accessibilityLabel(helpText)
        .accessibilityAddTraits(isFront ? [.isButton, .isSelected] : .isButton)
    }

    private var pill: RoundedRectangle { RoundedRectangle(cornerRadius: pillRadius, style: .continuous) }

    private var helpText: String {
        let name = tab.title == tab.app ? tab.app : "\(tab.app): \(tab.title)"
        guard let badge else { return name }
        return Int(badge) != nil ? "\(name), \(badge) new" : "\(name), wants attention"
    }

    private var icon: some View {
        AppIcon(windowId: tab.windowId, size: 16)
            .overlay(alignment: .topTrailing) {
                if badge != nil {
                    Circle()
                        .fill(Color.red)
                        .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
                        .frame(width: 8, height: 8)
                        .offset(x: 3, y: -3)
                }
            }
    }

    /// The window title without the app's name, which the tab already shows
    private var detail: String {
        guard tab.title != tab.app else { return "" }
        var title = tab.title
        for separator in [" — ", " - ", ": "] where title.hasSuffix(separator + tab.app) {
            title = String(title.dropLast(separator.count + tab.app.count))
        }
        return "  " + title
    }
}

/// The front tab is a solid pill on the glass, the others show only when pointed at
@MainActor
private func tabFill(isFront: Bool, isHovered: Bool) -> Color {
    if isFront {
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.96, alpha: 1) : .white
        })
    }
    return isHovered ? Color.primary.opacity(0.07) : .clear
}

/// Liquid Glass where there is, a blur of what's behind before macOS 26
private struct StripGlass: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: stripRadius, style: .continuous)
        if #available(macOS 26, *) {
            content.glassEffect(.regular.tint(.black.opacity(0.25)), in: shape)
        } else {
            content
                .background(StripBlur().clipShape(shape))
                .overlay(shape.strokeBorder(Color.primary.opacity(0.08)))
        }
    }
}

private struct StripBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// A rectangle with one corner radius on its leading side and another on its trailing side.
/// UnevenRoundedRectangle needs macOS 14
struct TabShape: Shape {
    let leading: CGFloat
    let trailing: CGFloat

    func path(in rect: CGRect) -> Path {
        let leading = min(leading, rect.height / 2, rect.width / 2)
        let trailing = min(trailing, rect.height / 2, rect.width / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + leading, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - trailing, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: trailing)
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: trailing)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: leading)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: leading)
        path.closeSubpath()
        return path
    }
}


