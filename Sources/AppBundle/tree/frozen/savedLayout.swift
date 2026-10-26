import AppKit
import Common

/// The layout is saved to disk whenever it changes and restored on startup, so that restarting nanopress (e.g. after an
/// update) keeps every window where it was. Windows are matched by window id, which stays the same for as long as the
/// window's app keeps running. Windows of apps that were restarted in the meantime are placed as new windows.
///
/// Restoring goes through SimNode, the same way a drop does, so a saved tree that lost some of its windows is
/// normalized before it's applied.
///
/// Each display setup (the set of connected screens) keeps a layout of its own. Plugging a screen in or out brings
/// back the layout the new setup had last time, and windows whose screen went away move to the focused workspace
struct SavedLayout: Codable, Equatable {
    var workspaces: [SavedWorkspace]
    var monitors: [SavedMonitor]
}

struct SavedWorkspace: Codable, Equatable {
    var name: String
    var root: SavedNode
    var floatingWindowIds: [UInt32]
}

struct SavedMonitor: Codable, Equatable {
    var topLeftX: CGFloat
    var topLeftY: CGFloat
    var visibleWorkspace: String
}

indirect enum SavedNode: Codable, Equatable {
    case window(id: UInt32, weight: CGFloat)
    /// `orientation` is "h" or "v". `mostRecentChild` is the index of the window on top of a stack
    case container(orientation: String, layout: String, weight: CGFloat, mostRecentChild: Int?, children: [SavedNode])
}

@MainActor private var isSavedLayoutRestored = false
@MainActor private var lastPublishedLayout: SavedLayout? = nil
/// Keyed by displaySetup
@MainActor private var setupLayouts: [String: SavedLayout] = [:]
/// The setup the layout was last saved for. Nil until the saved layouts are restored
@MainActor private var currentSetup: String? = nil

@MainActor private var supportDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/\(aeroSpaceAppId)")
}
@MainActor private var setupLayoutsUrl: URL { supportDirectory.appending(path: "layouts.json") }
/// From before setups: one layout for whatever screens were connected
@MainActor private var legacyLayoutUrl: URL { supportDirectory.appending(path: "layout.json") }

/// Identifies the connected screens, e.g. "Built-in Retina Display 1512x982 + LG UltraFine 2560x1440"
@MainActor var displaySetup: String {
    monitorInfos.map { "\($0.name) \(Int($0.width))x\(Int($0.height))" }.sorted().joined(separator: " + ")
}

// MARK: Save

@MainActor
func saveLayoutIfChanged() {
    let layout = SavedLayout.current
    if layout != lastPublishedLayout {
        lastPublishedLayout = layout
        TrayMenuModel.shared.layoutRevision += 1
    }
    // Until adaptToDisplaySetup has run, the layout is the old setup's, half moved to the new screens
    guard isSavedLayoutRestored, !isUnitTest, let setup = currentSetup, setup == displaySetup else { return }
    // The lock screen makes all windows look closed. Don't overwrite a good layout with an empty one
    if layout.workspaces.allSatisfy({ $0.root.windowIds.isEmpty && $0.floatingWindowIds.isEmpty }) { return }
    if layout == setupLayouts[setup] { return }
    setupLayouts[setup] = layout
    do {
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(setupLayouts).write(to: setupLayoutsUrl, options: .atomic)
    } catch {
        print("Can't save the layout: \(error)")
    }
}

extension SavedLayout {
    @MainActor static var current: SavedLayout {
        SavedLayout(
            workspaces: Workspace.all.map(SavedWorkspace.init),
            monitors: monitorInfos.map {
                SavedMonitor(topLeftX: $0.rect.topLeftX, topLeftY: $0.rect.topLeftY, visibleWorkspace: $0.activeWorkspace.name)
            },
        )
    }
}

extension SavedWorkspace {
    @MainActor init(_ workspace: Workspace) {
        name = workspace.name
        root = SavedNode(workspace.rootTilingContainer, weight: 1)
        floatingWindowIds = workspace.floatingWindows.map(\.windowId)
    }
}

extension SavedNode {
    @MainActor init(_ node: TreeNode, weight: CGFloat) {
        switch node.tilingTreeNodeCasesOrDie() {
            case .window(let window):
                self = .window(id: window.windowId, weight: weight)
            case .tilingContainer(let container):
                let mostRecentChild = container.mostRecentChild.flatMap { mru in container.children.firstIndex { $0 === mru } }
                self = .container(
                    orientation: container.orientation == .h ? "h" : "v",
                    layout: container.layout.rawValue,
                    weight: weight,
                    mostRecentChild: mostRecentChild,
                    children: container.children.map { SavedNode($0, weight: $0.getWeight(container.orientation)) },
                )
        }
    }

    var windowIds: [UInt32] {
        switch self {
            case .window(let id, _): [id]
            case .container(_, _, _, _, let children): children.flatMap(\.windowIds)
        }
    }
}

// MARK: Restore

/// Called once on startup, after all windows are detected
@MainActor
func restoreSavedLayout() {
    defer { isSavedLayoutRestored = true }
    guard !isUnitTest else { return }
    let setup = displaySetup
    currentSetup = setup
    if let data = try? Data(contentsOf: setupLayoutsUrl), let layouts = try? JSONDecoder().decode([String: SavedLayout].self, from: data) {
        setupLayouts = layouts
    } else if let data = try? Data(contentsOf: legacyLayoutUrl), let layout = try? JSONDecoder().decode(SavedLayout.self, from: data) {
        setupLayouts = [setup: layout]
    }
    if let layout = setupLayouts[setup] { applySavedLayout(layout) }
}

/// Called on every refresh, after the workspaces are assigned to the screens. When the screens changed since the
/// layout was last saved, brings back the layout of the new setup, and moves windows whose screen went away to the
/// focused workspace, where they're stacked once it's full
@MainActor
func adaptToDisplaySetup() {
    guard isSavedLayoutRestored, !isUnitTest, let previous = currentSetup else { return }
    let setup = displaySetup
    if setup == previous { return }
    currentSetup = setup
    let wasVisible = setupLayouts[previous]?.monitors.map(\.visibleWorkspace) ?? []
    if let layout = setupLayouts[setup] { applySavedLayout(layout) }

    let visible = monitorInfos.map(\.activeWorkspace)
    let target = visible.contains(focus.workspace) ? focus.workspace : mainMonitorInfo.activeWorkspace
    for name in wasVisible where !visible.contains(where: { $0.name == name }) {
        let orphan = Workspace.get(byName: name)
        // Least recent first, so that the most recent window is placed last and ends up on top
        for window in windowsByRecency(orphan.rootTilingContainer).reversed() + orphan.floatingWindows {
            moveWindow(window, to: target)
        }
    }
}

@MainActor
func applySavedLayout(_ layout: SavedLayout) {
    // Minimized, hidden and native fullscreen windows stay where macOS put them
    var windows: [UInt32: Window] = [:]
    for workspace in Workspace.all {
        for window in workspace.rootTilingContainer.allLeafWindowsRecursive + workspace.floatingWindows {
            windows[window.windowId] = window
        }
    }
    let savedIds = layout.workspaces.flatMap { $0.root.windowIds + $0.floatingWindowIds }.toSet()

    for savedWorkspace in layout.workspaces {
        let workspace = Workspace.get(byName: savedWorkspace.name)
        let sim = SimNode(.workspace)
        guard let root = savedWorkspace.root.simNode(parent: sim, existing: windows) else { continue }
        // Windows that weren't open when the layout was saved stay in the workspace they were placed in
        for window in workspace.rootTilingContainer.allLeafWindowsRecursive where !savedIds.contains(window.windowId) {
            SimNode(.window(window.windowId)).bind(to: root, weight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        }
        // Apps the user wants floating since the layout was saved
        let nowFloating = root.allWindows.filter { NanopressSettings.shared.isFloatingApp(windows[$0.windowId.orDie()]?.app.rawAppBundleId) }
        for simWindow in nowFloating { simWindow.unbind() }
        sim.normalizeContainers()
        sim.materialize(into: workspace, windows: windows)
        for id in savedWorkspace.floatingWindowIds + nowFloating.compactMap(\.windowId) {
            _ = windows[id]?.bindAsFloatingWindow(to: workspace)
        }
    }
    for monitor in layout.monitors {
        let point = CGPoint(x: monitor.topLeftX, y: monitor.topLeftY)
        _ = monitorInfos.first { $0.rect.topLeftCorner == point }?.setActiveWorkspace(Workspace.get(byName: monitor.visibleWorkspace))
    }
}

extension SavedNode {
    /// Skips windows that no longer exist. Empty containers are removed later by normalizeContainers
    @MainActor
    fileprivate func simNode(parent: SimNode, existing windows: [UInt32: Window]) -> SimNode? {
        switch self {
            case .window(let id, let weight):
                guard windows[id] != nil else { return nil }
                let node = SimNode(.window(id))
                node.bind(to: parent, weight: weight, index: INDEX_BIND_LAST)
                return node
            case .container(let orientation, let layout, let weight, let mostRecentChild, let children):
                let node = SimNode(.container(orientation == "h" ? .h : .v, Layout(rawValue: layout) ?? .tiles))
                node.bind(to: parent, weight: weight, index: INDEX_BIND_LAST)
                let simChildren = children.map { $0.simNode(parent: node, existing: windows) }
                // Post-order, so that the parents' own choice wins over the propagation from their children
                if let mostRecentChild, let child = simChildren.getOrNil(atIndex: mostRecentChild) ?? nil {
                    child.markAsMostRecentChild()
                }
                return node
        }
    }
}
