import AppKit
import Common
import SwiftUI

/// The panel that opens from the menu bar icon. A panel rather than a menu, so that hovering an Arrange option can
/// preview it on screen
private let panelWidth: CGFloat = 480
/// Left and right margin of everything in the panel. Rows that highlight on hover bleed into it by rowInset
private let panelMargin: CGFloat = 16
private let rowInset: CGFloat = 8
private let sectionSpacing: CGFloat = 20

@MainActor
struct MenuPanel: View {
    @ObservedObject var viewModel: TrayMenuModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var lastChange = LastChange.shared
    @ObservedObject private var settings = NanopressSettings.shared
    @State private var contentHeight: CGFloat = 0
    /// Nil until picked: the number of tiles on screen right now
    @State private var arrangeCount: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, panelMargin)
                .padding(.vertical, 10)
            Divider()
            VStack(alignment: .leading, spacing: sectionSpacing) {
                if viewModel.axPermissionStatus == .granted {
                    if viewModel.lastReloadConfigContainedWarnings { configWarning }
                    if viewModel.isEnabled {
                        if let change = lastChange.entry { lastChangeRow(change) }
                        layoutMap
                        arrange
                    }
                } else {
                    Text("nanopress needs Accessibility access to move windows")
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open System Settings") { viewModel.axPermissionStatus = .waitingWithPrompt }
                }
            }
            .padding(.horizontal, panelMargin)
            .padding(.vertical, 16)
            Divider()
            footer
                .padding(.horizontal, panelMargin - rowInset)
                .padding(.vertical, 6)
        }
        .frame(width: panelWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { Color.clear.preference(key: PanelHeightKey.self, value: $0.size.height) })
        .onPreferenceChange(PanelHeightKey.self) { contentHeight = $0 }
        .background(PanelWindowSizer(height: contentHeight))
        .frame(maxHeight: .infinity, alignment: .top)
        .onDisappear {
            DropZoneOverlay.shared.hide()
            LiveArrangement.shared.revert()
        }
    }

    /// The switch says on or off by itself. Workspaces sit in the middle, where they're always in reach
    private var header: some View {
        HStack {
            Text("nanopress").font(.system(size: 13, weight: .semibold))
            Spacer()
            if viewModel.axPermissionStatus == .granted {
                Toggle("Tiling", isOn: Binding(get: { viewModel.isEnabled }, set: { _ in toggleTiling() }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
        }
        .overlay {
            if viewModel.axPermissionStatus == .granted && viewModel.isEnabled {
                WorkspaceChips(revision: viewModel.layoutRevision)
            }
        }
    }

    private var configWarning: some View {
        Button {
            guard let token: RunSessionGuard = .isServerEnabled else { return }
            Task.startUnstructured {
                try await runLightSession(.menuBarButton, token) {
                    let args: ReloadConfigCmdArgs = ReloadConfigCmdArgs(rawArgs: []).copy(\.warningsAsErrors, true)
                    _ = await reloadConfig_nonCancellable(args: args)
                }
            }
        } label: {
            Label("Config contains warnings", systemImage: "exclamationmark.triangle.fill")
        }
        .buttonStyle(.link)
    }

    // MARK: Arrange

    @ViewBuilder
    private var arrange: some View {
        let workspace = focus.workspace
        let counts = arrangeCounts(of: workspace)
        if let maxCount = counts.last {
            let tilesOnScreen = workspace.rootTilingContainer.allLeafWindowsRecursive.map(\.stackOrSelf).uniqueByIdentity().count
            let frozen = LiveArrangement.shared.frozenOptions(of: workspace)
            let count = frozen?.count ?? min(arrangeCount ?? tilesOnScreen, maxCount)
            let options = frozen?.options ?? arrangements(of: workspace, showing: count, limit: 3)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    sectionTitle("Auto-arrange")
                    Spacer()
                    // Neutral when selected, like a native segmented control: accent stays for what's current
                    HStack(spacing: 0) {
                        ForEach(counts, id: \.self) { option in
                            CountChip(count: option, isSelected: option == count) {
                                LiveArrangement.shared.revert()
                                arrangeCount = option
                            }
                        }
                    }
                    .padding(2)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                HStack(spacing: arrangeSpacing) {
                    ForEach(Array(options.enumerated()), id: \.offset) { rank, sim in
                        ArrangeOption(
                            key: LiveArrangement.Key(workspaceName: workspace.name, count: count, rank: rank),
                            options: options,
                            tiles: arrangedTiles(sim, on: workspace),
                            monitorRect: workspace.workspaceMonitor.rect.cgRect,
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Layout

    /// What nanopress last did on its own, with a way back that outlasts the note on screen
    private func lastChangeRow(_ change: LastChange.Entry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(change.message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(change.message)
            Spacer(minLength: 8)
            Button(change.action) { lastChange.undo() }
                .controlSize(.small)
                .keyboardShortcut("z", modifiers: .command)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// No title: the map is what the panel is for
    private var layoutMap: some View {
        LayoutEditor(workspace: focus.workspace, width: panelWidth - 2 * panelMargin, revision: viewModel.layoutRevision)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            FooterButton(title: "Settings…") { openSettings() }
                .keyboardShortcut(",", modifiers: .command)
            Spacer()
            FooterButton(title: "Quit") {
                Task.startUnstructured {
                    terminationHandler?.beforeTermination()
                    terminateApp()
                }
            }
            .keyboardShortcut("Q", modifiers: .command)
        }
    }

    /// The panel sits above every window, so it goes first
    private func openSettings() {
        dismiss()
        panelWindow?.orderOut(nil)
        DispatchQueue.main.async { SettingsWindow.shared.show() }
    }

    private func toggleTiling() {
        Task.startUnstructured {
            try await runLightSession(.menuBarButton, .forceRun) {
                _ = await EnableCommand(args: EnableCmdArgs(rawArgs: [], targetState: .toggle))
                    .run(.defaultEnv, .emptyStdin)
            }
        }
    }
}

private func sectionTitle(_ title: String) -> some View {
    Text(title).font(.system(size: 13, weight: .semibold))
}

/// A thumbnail of one Arrange option. Hovering previews it full size, clicking applies it
private struct CountChip: View {
    let count: Int
    let isSelected: Bool
    let select: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: select) {
            // The selected segment spells out what the number counts
            Text(isSelected ? (count == 1 ? "1 window" : "\(count) windows") : "\(count)")
                .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                .monospacedDigit()
                .padding(.horizontal, isSelected ? 10 : 0)
                .frame(minWidth: 28, minHeight: 20)
                .background(
                    isSelected ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor)) : AnyShapeStyle(Color.primary.opacity(isHovered ? 0.06 : 0)),
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous),
                )
                .shadow(color: .black.opacity(isSelected ? 0.15 : 0), radius: 0.5, y: 0.5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(count == 1 ? "1 window" : "\(count) windows")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ArrangeOption: View {
    let key: LiveArrangement.Key
    let options: [SimNode]
    let tiles: [ArrangedTile]
    let monitorRect: CGRect
    @ObservedObject private var live = LiveArrangement.shared
    @State private var isHovered = false
    @State private var tryTask: Task<(), any Error>? = nil

    /// How long the cursor rests on an option before the windows move there
    private static let tryDelay: Duration = .milliseconds(600)

    var body: some View {
        let isTried = live.tried == key
        Button(action: apply) {
            VStack(spacing: 6) {
                thumbnail
                Text(key.rank == 0 ? "Best fit" : "Option \(key.rank + 1)")
                    .font(.system(size: 11, weight: key.rank == 0 ? .semibold : .regular))
                    .foregroundStyle(isHovered || isTried ? Color.accentColor : .secondary)
            }
            .padding(.top, 8)
            .padding(.bottom, 6)
            .frame(width: arrangeCardWidth)
            .background(
                // No card at rest: the thumbnail carries it, and one gray box less on the panel
                Color.primary.opacity(isHovered ? 0.08 : 0),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous),
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover(perform: hover)
        .onDisappear { tryTask?.cancel() }
    }

    /// Outlines first, then the real windows if the cursor stays
    private func hover(_ hovering: Bool) {
        isHovered = hovering
        tryTask?.cancel()
        let live = live
        guard hovering else {
            DropZoneOverlay.shared.hide()
            live.scheduleRevert()
            return
        }
        live.cancelRevert()
        if live.tried == key { return }
        DropZoneOverlay.shared.showArrangement(tiles, monitorRect: monitorRect)
        let key = key
        let options = options
        tryTask = Task { @MainActor in
            try await Task.sleep(for: Self.tryDelay)
            DropZoneOverlay.shared.hide()
            live.tryOption(key, options: options)
        }
    }

    private var thumbnail: some View {
        let thumbnailWidth = arrangeCardWidth - 16
        let size = CGSize(width: thumbnailWidth, height: thumbnailWidth * monitorRect.height / max(monitorRect.width, 1))
        let scale = size.width / max(monitorRect.width, 1)
        let highlighted = isHovered || live.tried == key
        return ZStack(alignment: .topLeading) {
            ForEach(tiles) { tile in
                let rect = tile.rect.offsetBy(dx: -monitorRect.minX, dy: -monitorRect.minY)
                let scaled = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
                    .insetBy(dx: 1.5, dy: 1.5)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(highlighted ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.07))
                    .overlay(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(highlighted ? Color.accentColor : Color.primary.opacity(0.3), lineWidth: 1),
                    )
                    .overlay { StackIcons(tile: tile, fitting: CGSize(width: scaled.width - 4, height: scaled.height - 4), maxSize: 24) }
                    .frame(width: max(scaled.width, 0), height: max(scaled.height, 0))
                    .offset(x: scaled.minX, y: scaled.minY)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func apply() {
        tryTask?.cancel()
        DropZoneOverlay.shared.hide()
        LiveArrangement.shared.apply(key, options: options)
    }
}

struct AppIcon: View {
    let windowId: UInt32
    let size: CGFloat

    var body: some View {
        if size >= 10, let icon = (Window.get(byId: windowId) as? MacWindow)?.macApp.nsApp.icon {
            Image(nsImage: icon).resizable().frame(width: size, height: size)
        }
    }
}

/// The icon of the window on top of a tile, with the windows stacked behind it fanned out behind the icon, so that
/// it's clear which windows a stack holds
struct StackIcons: View {
    let tile: ArrangedTile
    let size: CGFloat

    /// Behind icons past this are left out
    private static let maxBehind = 3
    /// How far each icon behind peeks out, as a share of the icon size
    private static let step: CGFloat = 0.3

    init(tile: ArrangedTile, fitting space: CGSize, maxSize: CGFloat) {
        self.tile = tile
        let fan = 1 + Self.step * CGFloat(min(tile.behind.count, Self.maxBehind))
        size = min(maxSize, space.height / fan, space.width / fan).rounded(.down)
    }

    var body: some View {
        let behind = Array(tile.behind.prefix(Self.maxBehind))
        let offset = size * Self.step
        ZStack(alignment: .bottomLeading) {
            ForEach(Array(behind.enumerated()).reversed(), id: \.element) { index, windowId in
                AppIcon(windowId: windowId, size: size)
                    .opacity(0.75 - 0.15 * Double(index))
                    .offset(x: offset * CGFloat(index + 1), y: -offset * CGFloat(index + 1))
            }
            AppIcon(windowId: tile.id, size: size)
        }
        .frame(width: size + offset * CGFloat(behind.count), height: size + offset * CGFloat(behind.count), alignment: .bottomLeading)
    }
}

private let arrangeSpacing: CGFloat = 8
/// Three cards fill the panel width
private let arrangeCardWidth: CGFloat = (panelWidth - 2 * panelMargin - 2 * arrangeSpacing) / 3

private struct FooterButton: View {
    let title: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.horizontal, rowInset)
                .frame(height: 28)
                .background(Color.primary.opacity(isHovered ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct PanelHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// MenuBarExtra doesn't resize its window when the content changes. This keeps the window as tall as the content,
/// anchored to its top edge under the menu bar
/// The panel's window, to close it when Settings opens. See PanelWindowSizer
@MainActor private weak var panelWindow: NSWindow? = nil

private struct PanelWindowSizer: NSViewRepresentable {
    let height: CGFloat

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let height = height
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            panelWindow = window
            guard height > 0 else { return }
            let frame = window.frame
            let newHeight = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: frame.width, height: height)).height
            if abs(frame.height - newHeight) < 0.5 { return }
            window.setFrame(NSRect(x: frame.minX, y: frame.maxY - newHeight, width: frame.width, height: newHeight), display: true)
        }
    }
}

