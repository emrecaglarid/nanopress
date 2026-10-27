import AppKit
import Common
import SwiftUI

/// Settings changed from the menu panel, as opposed to the config file. Stored in UserDefaults
@MainActor
final class NanopressSettings: ObservableObject {
    static let shared = NanopressSettings()

    @Published var spacing: Spacing { didSet { store(spacing.rawValue, "spacing"); relayout() } }
    /// How much the window under a dragged window is dimmed, 0 to 0.6. Being tuned: see Settings, Advanced
    @Published var dragDimming: Double { didSet { defaults?.set(dragDimming, forKey: "dragDimming") } }
    /// Whether the window under a dragged window is blurred
    @Published var dragBlur: Bool { didSet { defaults?.set(dragBlur, forKey: "dragBlur") } }
    /// Which side of a stack its tabs are on
    @Published var tabsPosition: TabsPosition { didSet { store(tabsPosition.rawValue, "tabsPosition"); relayout() } }
    @Published var backgroundMode: BackgroundMode { didSet { store(backgroundMode.rawValue, "backgroundMode"); BackdropPanels.shared.refresh() } }
    /// Shown when backgroundMode is custom
    @Published var customBackground: Background { didSet { store(customBackground.rawValue, "customBackground"); BackdropPanels.shared.refresh() } }
    /// Window widths the user picked by resizing, keyed by bundle id. See preferredWidth(of:)
    private(set) var learnedWidths: [String: CGFloat] { didSet { defaults?.set(learnedWidths, forKey: "learnedWidths") } }
    /// Apps whose windows float where they open instead of being tiled, by bundle id
    @Published private(set) var floatingApps: [String] { didSet { defaults?.set(floatingApps, forKey: "floatingApps") } }
    /// Whether `nanopress mcp` may answer: an AI agent can then see and arrange windows. Off until the user turns it on
    @Published var allowsAgents: Bool { didSet { defaults?.set(allowsAgents, forKey: "allowsAgents") } }
    /// Window titles can show email subjects and page names. Without them, agents only see app names
    @Published var sharesTitlesWithAgents: Bool { didSet { defaults?.set(sharesTitlesWithAgents, forKey: "sharesTitlesWithAgents") } }
    /// Layouts an agent saved by name, like "coding", as JSON
    private var namedLayouts: [String: Data] { didSet { defaults?.set(namedLayouts, forKey: "namedLayouts") } }
    /// Where the user last put a window of each app, keyed by bundle id: the center of its tile as a share of the screen
    private var learnedPlaces: [String: [Double]] { didSet { defaults?.set(learnedPlaces, forKey: "learnedPlaces") } }

    private let defaults: UserDefaults? = isUnitTest ? nil : UserDefaults(suiteName: aeroSpaceAppId)

    private init() {
        spacing = (defaults?.string(forKey: "spacing")).flatMap(Spacing.init(rawValue:)) ?? .auto
        tabsPosition = (defaults?.string(forKey: "tabsPosition")).flatMap(TabsPosition.init(rawValue:)) ?? .bottom
        dragDimming = defaults?.object(forKey: "dragDimming") as? Double ?? 0.12
        dragBlur = defaults?.object(forKey: "dragBlur") as? Bool ?? true
        // "background" is from before the modes: the wallpaper, or one of the colors
        let legacyBackground = defaults?.string(forKey: "background")
        backgroundMode = (defaults?.string(forKey: "backgroundMode")).flatMap(BackgroundMode.init(rawValue:))
            ?? (legacyBackground.flatMap(Background.init(rawValue:)) != nil ? .custom : .none)
        customBackground = (defaults?.string(forKey: "customBackground") ?? legacyBackground).flatMap(Background.init(rawValue:)) ?? .ocean
        learnedWidths = defaults?.dictionary(forKey: "learnedWidths") as? [String: CGFloat] ?? [:]
        learnedPlaces = defaults?.dictionary(forKey: "learnedPlaces") as? [String: [Double]] ?? [:]
        allowsAgents = defaults?.bool(forKey: "allowsAgents") ?? false
        sharesTitlesWithAgents = defaults?.bool(forKey: "sharesTitlesWithAgents") ?? false
        namedLayouts = defaults?.dictionary(forKey: "namedLayouts") as? [String: Data] ?? [:]
        // Finder windows come and go too often to be worth a tile. Tests tile everything, like AeroSpace
        floatingApps = isUnitTest ? [] : defaults?.stringArray(forKey: "floatingApps") ?? ["com.apple.finder"]
    }

    func saveNamedLayout(_ layout: SavedLayout, as name: String) {
        namedLayouts[name] = try? JSONEncoder().encode(layout)
    }

    func namedLayout(_ name: String) -> SavedLayout? {
        namedLayouts[name].flatMap { try? JSONDecoder().decode(SavedLayout.self, from: $0) }
    }

    var namedLayoutNames: [String] { namedLayouts.keys.sorted() }

    func isFloatingApp(_ bundleId: String?) -> Bool {
        bundleId.map(floatingApps.contains) ?? false
    }

    /// Takes effect on the app's open windows too
    func setFloating(_ bundleId: String, _ isFloating: Bool) {
        if isFloating == floatingApps.contains(bundleId) { return }
        if isFloating { floatingApps.append(bundleId) } else { floatingApps.removeAll { $0 == bundleId } }
        guard let token: RunSessionGuard = .isServerEnabled else { return }
        Task.startUnstructured {
            try await runLightSession(.menuBarButton, token) {
                for window in MacWindow.allWindows where window.app.rawAppBundleId == bundleId {
                    guard let workspace = window.nodeWorkspace else { continue }
                    if isFloating && window.parent is TilingContainer {
                        window.bindAsFloatingWindow(to: workspace)
                    } else if !isFloating && window.parent is FloatingWindowsContainer,
                              try await window.macApp.getAxUiElementWindowType(window.windowId, getWindowLevel(for: window.windowId), .cancellable) == .window
                    {
                        // Dialogs keep floating, like dialogs of any other app
                        let data = bindingDataForNewWindowSplittingBiggestTile(workspace, app: bundleId)
                            ?? BindingData(parent: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
                        window.bind(to: data.parent, adaptiveWeight: data.adaptiveWeight, index: data.index)
                    }
                }
            }
        }
    }

    func learnWidth(_ width: CGFloat, for bundleId: String) {
        learnedWidths[bundleId] = width
    }

    func learnPlace(_ place: CGPoint, for bundleId: String) {
        learnedPlaces[bundleId] = [place.x, place.y]
    }

    func place(of bundleId: String) -> CGPoint? {
        guard let place = learnedPlaces[bundleId], place.count == 2 else { return nil }
        return CGPoint(x: place[0], y: place[1])
    }

    /// What's drawn behind the windows. Nil shows the wallpaper
    var backdrop: Background? {
        switch backgroundMode {
            case .none: nil
            // The opposite of the system appearance, so that windows stand out against it
            case .auto: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dawn : .dusk
            case .custom: customBackground
        }
    }

    private func store(_ value: String?, _ key: String) {
        defaults?.set(value, forKey: key)
    }

    private func relayout() {
        guard let token: RunSessionGuard = .isServerEnabled else { return }
        Task.startUnstructured { try await runLightSession(.menuBarButton, token) {} }
    }
}

enum Spacing: String, CaseIterable, Identifiable {
    case auto, none, small, medium, large

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    /// For the menu
    var detail: String? {
        switch self {
            case .auto: "More room on bigger screens"
            case .none: "Windows touch"
            case .small, .medium, .large: nil
        }
    }

    @MainActor func points(on monitor: any MonitorInfo) -> Int {
        switch self {
            // Roomier on bigger screens: 9 on a 13" laptop, 14 on a 27" display
            case .auto: min(max(Int((monitor.rect.height / 100).rounded()), 4), 16)
            case .none: 0
            case .small: 6
            case .medium: 12
            case .large: 20
        }
    }
}

/// The gaps used for layout, from the spacing picked in the menu. Tests set the gaps through the config
@MainActor func effectiveGaps(on monitor: any MonitorInfo) -> Gaps {
    if isUnitTest { return config.gaps }
    let p = NanopressSettings.shared.spacing.points(on: monitor)
    return Gaps(inner: .init(vertical: p, horizontal: p), outer: .init(left: p, bottom: p, top: p, right: p))
}

/// Below the stack by default: the window's title bar stays the first thing at its top, as with a window on its own
enum TabsPosition: String, CaseIterable, Identifiable {
    case bottom, top

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// Where the windows of a stack go in its rect, leaving room for the tabs. See StackTabs
@MainActor
func stackWindowsOffset() -> CGFloat {
    NanopressSettings.shared.tabsPosition == .top ? stackTabsHeight : 0
}

enum BackgroundMode: String, CaseIterable, Identifiable {
    /// A gradient opposite to the system appearance
    case auto
    /// The wallpaper
    case none
    case custom

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// Drawn behind all windows instead of the wallpaper
enum Background: String, CaseIterable, Identifiable {
    case graphite, slate, mist, sand, dusk, ocean, dawn

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    /// Top to bottom
    var colors: [Color] {
        switch self {
            case .graphite: [Color(hex: 0x1C1C1E)]
            case .slate: [Color(hex: 0x2B3340)]
            case .mist: [Color(hex: 0xDDE3EA)]
            case .sand: [Color(hex: 0xE8E1D5)]
            case .dusk: [Color(hex: 0x2B3340), Color(hex: 0x5B4B6B)]
            case .ocean: [Color(hex: 0x0F2A44), Color(hex: 0x1F6F8B)]
            case .dawn: [Color(hex: 0xF3D9C4), Color(hex: 0xC9D3DE)]
        }
    }

    var fill: AnyShapeStyle {
        colors.count == 1
            ? AnyShapeStyle(colors[0])
            : AnyShapeStyle(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
        )
    }
}

/// One borderless panel per monitor, above the wallpaper and below the desktop icons and windows
@MainActor
final class BackdropPanels {
    static let shared = BackdropPanels()
    private var panels: [NSPanel] = []
    private var appearanceObservation: NSKeyValueObservation? = nil

    private init() {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            Task.startUnstructured { @MainActor in BackdropPanels.shared.refresh() }
        }
        // Auto follows the system appearance
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { _, _ in
            Task.startUnstructured { @MainActor in BackdropPanels.shared.refresh() }
        }
    }

    func refresh() {
        for panel in panels { panel.orderOut(nil) }
        panels = []
        guard let fill = NanopressSettings.shared.backdrop?.fill, !isUnitTest else { return }
        for screen in NSScreen.screens {
            let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            panel.ignoresMouseEvents = true
            panel.isReleasedWhenClosed = false
            panel.hasShadow = false
            panel.contentView = NSHostingView(rootView: Rectangle().fill(fill).ignoresSafeArea())
            panel.setFrame(screen.frame, display: true)
            panel.orderFrontRegardless()
            panels.append(panel)
        }
    }
}
