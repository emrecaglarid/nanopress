import AppKit
import Common
import SwiftUI

/// Preferences, in a window of their own: a menu has no room to say what each option does
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow? = nil

    private init() {}

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        // nanopress has no Dock icon, so it has to come forward for its window to. Once the window is key, the menu
        // panel closes by itself
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// Icon tabs in the toolbar, like the settings of any Mac app. The window takes the height of the tab shown
    private func makeWindow() -> NSWindow {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        // The window keeps the app's name, whichever tab is shown
        tabs.canPropagateSelectedChildViewControllerTitle = false
        // Resizes in one step when a tab, or Advanced, changes height. Animated, the window trails behind the content
        tabs.transitionOptions = []
        for tab in SettingsTab.allCases {
            let controller = NSHostingController(rootView: SettingsView(tab: tab))
            controller.sizingOptions = .preferredContentSize
            let item = NSTabViewItem(viewController: controller)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.title = "nanopress"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}

private enum SettingsTab: CaseIterable {
    case appearance, floatingApps, agents, advanced, about

    var title: String {
        switch self {
            case .appearance: "Appearance"
            case .floatingApps: "Floating Apps"
            case .agents: "Agents"
            case .advanced: "Advanced"
            case .about: "About"
        }
    }

    var symbol: String {
        switch self {
            case .appearance: "paintbrush"
            case .floatingApps: "macwindow.on.rectangle"
            case .agents: "sparkles"
            case .advanced: "gearshape.2"
            case .about: "info.circle"
        }
    }
}

private struct SettingsView: View {
    let tab: SettingsTab
    @ObservedObject private var settings = NanopressSettings.shared
    @StateObject private var updates = UpdateChecker()

    var body: some View {
        Form {
            switch tab {
                case .appearance:
                    Section("Tab position") {
                        SettingRow(nil, "Every window in a stack gets a tab. Choose which side of the stack they sit on.") {
                            HStack(spacing: 12) {
                                ForEach(TabsPosition.allCases) { position in
                                    ChoiceCard(title: position.title, isSelected: settings.tabsPosition == position) {
                                        settings.tabsPosition = position
                                    } preview: {
                                        TabsPreview(position: position)
                                    }
                                }
                            }
                        }
                    }

                    Section("Spacing") {
                        SettingRow(nil, spacingDetail) {
                            HStack(alignment: .center, spacing: 16) {
                                SpacingPreview(points: settings.spacing.points(on: mainMonitorInfo))
                                Picker("Spacing", selection: $settings.spacing) {
                                    ForEach(Spacing.allCases) { Text($0.title).tag($0) }
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                            }
                        }
                    }

                    Section("Background") {
                        SettingRow(nil, backgroundDetail) {
                            LazyVGrid(columns: Array(repeating: GridItem(.fixed(56), spacing: 10), count: 6), alignment: .leading, spacing: 12) {
                                ChoiceCard(title: "Auto", isSelected: settings.backgroundMode == .auto) {
                                    settings.backgroundMode = .auto
                                } preview: {
                                    AutoBackgroundPreview()
                                }
                                ChoiceCard(title: "None", isSelected: settings.backgroundMode == .none) {
                                    settings.backgroundMode = .none
                                } preview: {
                                    WallpaperPreview()
                                }
                                ForEach(Background.allCases) { background in
                                    ChoiceCard(title: background.title, isSelected: settings.backgroundMode == .custom && settings.customBackground == background) {
                                        settings.customBackground = background
                                        settings.backgroundMode = .custom
                                    } preview: {
                                        Rectangle().fill(background.fill).frame(width: 50, height: 32)
                                    }
                                }
                            }
                        }
                    }

                case .floatingApps:
                    Section {
                        SettingRow(nil, "Windows of these apps aren't tiled. They open where the app puts them and stay there.") {
                            EmptyView()
                        }
                        ForEach(settings.floatingApps, id: \.self) { bundleId in
                            FloatingAppRow(app: InstalledApp(bundleId: bundleId)) { settings.setFloating(bundleId, false) }
                        }
                        addFloatingApp
                    }

                case .agents:
                    AgentsSettings(settings: settings)

                case .advanced:
                    Section("Drag preview") {
                        SettingRow(nil, "How the window under a dragged window looks. These are for trying out values and will go once they're settled.") {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Dimming").font(.system(size: 13))
                                    Slider(value: $settings.dragDimming, in: 0 ... 0.6)
                                    Text("\(Int(settings.dragDimming * 100))%").font(.system(size: 12)).monospacedDigit().frame(width: 36, alignment: .trailing)
                                }
                                Toggle("Blur", isOn: $settings.dragBlur).font(.system(size: 13))
                            }
                        }
                    }

                    Section("Config file") {
                        SettingRow(nil, "Keyboard shortcuts and window rules live here. Reload after you edit it.") {
                            HStack {
                                Button("Open Config") { openConfigFile() }
                                reloadButton
                            }
                        }
                    }

                case .about:
                    Section {
                        about
                    }

            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var spacingDetail: String {
        switch settings.spacing {
            case .auto: "Room between windows and at the screen's edges. Auto gives bigger screens more."
            case .none: "Windows touch each other and the screen's edges."
            case .small, .medium, .large: "Room between windows and at the screen's edges."
        }
    }

    private var backgroundDetail: String {
        switch settings.backgroundMode {
            case .auto: "Shown behind all windows. Auto is light in dark mode and dark in light mode, so windows stand out."
            case .none: "Shown behind all windows. None shows your wallpaper."
            case .custom: "Shown behind all windows, instead of your wallpaper."
        }
    }

    private var addFloatingApp: some View {
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .filter { !settings.floatingApps.contains($0.bundleIdentifier.orDie()) }
            .sorted { ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }
        return Menu("Add App…") {
            ForEach(running, id: \.processIdentifier) { app in
                Button {
                    settings.setFloating(app.bundleIdentifier.orDie(), true)
                } label: {
                    Label { Text(app.localizedName ?? "App") } icon: { Image(nsImage: menuIcon(app.icon)) }
                }
            }
            if !running.isEmpty { Divider() }
            Button("Choose from Applications…") { chooseFloatingApp() }
        }
        .fixedSize()
    }

    private func chooseFloatingApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add App"
        guard panel.runModal() == .OK, let url = panel.url, let bundleId = Bundle(url: url)?.bundleIdentifier else { return }
        settings.setFloating(bundleId, true)
    }

    @ViewBuilder
    private var reloadButton: some View {
        if let token: RunSessionGuard = .isServerEnabled {
            Button("Reload Config") {
                Task.startUnstructured {
                    try await runLightSession(.menuBarButton, token) {
                        _ = await reloadConfig_nonCancellable(args: ReloadConfigCmdArgs(rawArgs: []))
                    }
                }
            }
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(aeroSpaceAppName) \(aeroSpaceAppVersion)")
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                Text("Tiling for the rest of us. A mouse-first take on AeroSpace, made by Emre Caglar.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button("Check for Updates") { Task { await updates.check() } }
                    .disabled(updates.state == .checking)
                updateStatus
            }
            HStack(spacing: 16) {
                Link("nanopress on GitHub", destination: nanopressRepo)
                Link("Sponsor AeroSpace", destination: URL(string: "https://github.com/sponsors/nikitabobko").orDie())
            }
            .font(.system(size: 11))
        }
    }

    @ViewBuilder
    private var updateStatus: some View {
        switch updates.state {
            case .idle: EmptyView()
            case .checking: ProgressView().controlSize(.small)
            case .upToDate: Text("You're up to date.").font(.system(size: 11)).foregroundStyle(.secondary)
            case .available(let version, let url):
                Link("Download \(version)", destination: url).font(.system(size: 11))
            case .failed(let reason): Text(reason).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

private let nanopressRepo = URL(string: "https://github.com/emrecaglarid/nanopress").orDie()

/// Asks GitHub for the latest release of the fork. There's no updater: a newer release links to its download page
@MainActor
private final class UpdateChecker: ObservableObject {
    enum State: Equatable {
        case idle, checking, upToDate
        case available(String, URL)
        case failed(String)
    }

    @Published private(set) var state = State.idle

    private struct Release: Decodable {
        let tag_name: String
        let html_url: URL
    }

    func check() async {
        state = .checking
        let api = URL(string: "https://api.github.com/repos/emrecaglarid/nanopress/releases/latest").orDie()
        do {
            let (data, response) = try await URLSession.shared.data(from: api)
            if (response as? HTTPURLResponse)?.statusCode == 404 {
                state = .failed("No releases published yet.")
                return
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            let latest = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
            state = isNewer(latest, than: aeroSpaceAppVersion) ? .available(latest, release.html_url) : .upToDate
        } catch {
            state = .failed("Couldn't reach GitHub. Check your connection and try again.")
        }
    }

    /// Compares the numbers of "1.2.3". A snapshot build counts as older than any release
    private func isNewer(_ latest: String, than current: String) -> Bool {
        func numbers(_ version: String) -> [Int] {
            version.split(separator: "-")[0].split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = numbers(latest)
        let b = numbers(current)
        for index in 0 ..< max(a.count, b.count) {
            let x = a.getOrNil(atIndex: index) ?? 0
            let y = b.getOrNil(atIndex: index) ?? 0
            if x != y { return x > y }
        }
        return current.contains("SNAPSHOT") && !latest.contains("SNAPSHOT")
    }
}

/// Lets an AI agent arrange windows through `nanopress mcp`, and helps set that up
private struct AgentsSettings: View {
    @ObservedObject var settings: NanopressSettings
    @State private var setup = AgentSetup.prompt
    @State private var copied = false

    enum AgentSetup: String, CaseIterable, Identifiable {
        case prompt = "Prompt"
        case command = "Command"

        var id: String { rawValue }
    }

    var body: some View {
        Section("AI agents") {
            Toggle(isOn: $settings.allowsAgents) {
                SettingRow("Let AI agents arrange windows", "Agents like Claude connect over MCP. They can see your windows and arrange them, and every change shows an undo note.") {
                    EmptyView()
                }
            }
            Toggle(isOn: $settings.sharesTitlesWithAgents) {
                SettingRow("Share window titles", "Titles can show email subjects and page names. Without them, agents only see app names.") {
                    EmptyView()
                }
            }
            .disabled(!settings.allowsAgents)
        }

        Section("Connect your agent") {
            SettingRow(nil, setup == .prompt
                ? "Paste this into a chat with your agent. It sets up the connection itself."
                : "For Claude Code. Run this in Terminal.")
            {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Setup", selection: $setup) {
                        ForEach(AgentSetup.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Text(setupText)
                        .font(setup == .command ? .system(size: 12, design: .monospaced) : .system(size: 12))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(setupText, forType: .string)
                        copied = true
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(1.5))
                            copied = false
                        }
                    }
                }
            }
        }
    }

    private var setupText: String {
        let path = nanopressCliPath
        let quoted = path.contains(" ") ? "'\(path)'" : path
        switch setup {
            case .prompt:
                return """
                    Please connect to nanopress, the window manager on my Mac, so you can arrange my windows. Add an MCP \
                    server named "nanopress" that runs locally over stdio, with the command \(path) and the argument mcp. \
                    Once it's connected, use its tools when I ask you to arrange, find or switch between my windows.
                    """
            case .command:
                return "claude mcp add nanopress -- \(quoted) mcp"
        }
    }
}

/// The nanopress CLI, which serves MCP. Next to the app in a debug build, wherever Homebrew put it otherwise
@MainActor
private var nanopressCliPath: String {
    let candidates: [String?] = [
        Bundle.main.executableURL?.deletingLastPathComponent().appending(path: "nanopress").path,
        Bundle.main.resourceURL?.appending(path: "bin/nanopress").path,
        "/opt/homebrew/bin/nanopress",
        "/usr/local/bin/nanopress",
    ]
    return candidates.compactMap(\.self)
        .first { $0 != Bundle.main.executablePath && FileManager.default.isExecutableFile(atPath: $0) } ?? "nanopress"
}

/// A setting: its name, one sentence on what it does, then the control. Every description reads the same way
private struct SettingRow<Control: View>: View {
    let title: String?
    let detail: String
    let control: Control

    init(_ title: String?, _ detail: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                if let title { Text(title).font(.system(size: 13)) }
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            control
        }
        .padding(.vertical, 2)
    }
}

/// A choice shown as a picture with its name under it, like the Appearance choices in System Settings
private struct ChoiceCard<Preview: View>: View {
    let title: String
    let isSelected: Bool
    let select: () -> Void
    let preview: Preview

    init(title: String, isSelected: Bool, select: @escaping () -> Void, @ViewBuilder preview: () -> Preview) {
        self.title = title
        self.isSelected = isSelected
        self.select = select
        self.preview = preview()
    }

    var body: some View {
        Button(action: select) {
            VStack(spacing: 5) {
                preview
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                    .padding(3)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2))
                Text(title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A stack with its tabs on one side
private struct TabsPreview: View {
    let position: TabsPosition

    var body: some View {
        VStack(spacing: 3) {
            if position == .top { tabs }
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 6) }
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            if position == .bottom { tabs }
        }
        .padding(6)
        .frame(width: 96, height: 64)
        .background(Color.primary.opacity(0.06))
    }

    private var tabs: some View {
        HStack(spacing: 2) {
            Capsule().fill(Color.accentColor.opacity(0.35)).frame(width: 26)
            Capsule().fill(Color.primary.opacity(0.15)).frame(width: 20)
            Spacer(minLength: 0)
        }
        .frame(height: 6)
    }
}

/// Three tiles with the gap, drawn larger than life so that the steps are easy to tell apart
private struct SpacingPreview: View {
    let points: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let gap = CGFloat(points) * 0.35
        HStack(spacing: gap) {
            tile
            VStack(spacing: gap) {
                tile
                tile
            }
        }
        .padding(gap)
        .frame(width: 96, height: 56)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: points)
        .accessibilityHidden(true)
    }

    private var tile: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Color.accentColor.opacity(0.35))
    }
}

/// Light on one half and dark on the other: it follows the system appearance
private struct AutoBackgroundPreview: View {
    var body: some View {
        ZStack {
            Rectangle().fill(Background.dusk.fill)
            Rectangle().fill(Background.dawn.fill)
                .mask(GeometryReader { geometry in
                    Path { path in
                        path.move(to: .zero)
                        path.addLine(to: CGPoint(x: geometry.size.width, y: 0))
                        path.addLine(to: CGPoint(x: 0, y: geometry.size.height))
                    }
                })
        }
        .frame(width: 50, height: 32)
    }
}

/// The real wallpaper of the main screen
private struct WallpaperPreview: View {
    var body: some View {
        Group {
            if let image = wallpaper {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(Color.primary.opacity(0.1))
                    .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
            }
        }
        .frame(width: 50, height: 32)
    }

    /// Wallpapers are big files, so the image is read once
    @MainActor private static var cached: NSImage?? = nil

    private var wallpaper: NSImage? {
        if let cached = Self.cached { return cached }
        let image = NSScreen.main.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }.flatMap { NSImage(contentsOf: $0) }
        Self.cached = image
        return image
    }
}

private struct FloatingAppRow: View {
    let app: InstalledApp
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: app.icon).resizable().frame(width: 20, height: 20)
            Text(app.name).font(.system(size: 13))
            Spacer()
            Button("Remove", action: remove)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Tile \(app.name)'s windows like any other app's")
                .accessibilityLabel("Remove \(app.name)")
        }
    }
}

/// An app by bundle id, running or not
private struct InstalledApp {
    let name: String
    let icon: NSImage

    init(bundleId: String) {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first, let icon = running.icon {
            name = running.localizedName ?? bundleId
            self.icon = icon
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            name = bundleId
            icon = NSWorkspace.shared.icon(for: .application)
        }
    }
}

private func menuIcon(_ icon: NSImage?) -> NSImage {
    let copy = (icon ?? NSWorkspace.shared.icon(for: .application)).copy() as! NSImage
    copy.size = NSSize(width: 16, height: 16)
    return copy
}
