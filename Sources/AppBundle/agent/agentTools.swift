import AppKit
import Common

/// The tools `nanopress mcp` offers an AI agent (see Sources/Cli/mcp.swift). The CLI forwards each call here as JSON,
/// with `agentRequestArg` as the only argument. Answers are JSON text for the agent to read
@MainActor
func handleAgentRequest(_ json: String) async -> (exitCode: Int32, stdout: String, stderr: String) {
    guard NanopressSettings.shared.allowsAgents else {
        return fail("AI agents are turned off. Ask the user to turn them on in nanopress Settings, under Agents.")
    }
    guard let call = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
          let name = call["name"] as? String else { return fail("Couldn't read the tool call") }
    let arguments = call["arguments"] as? [String: Any] ?? [:]
    guard let token: RunSessionGuard = .isServerEnabled else {
        return fail("Tiling is turned off in nanopress, so windows can't be arranged. Ask the user to turn it on.")
    }
    do {
        let result = try await runLightSession(.agent(name), token) {
            try await runAgentTool(name, arguments)
        }
        return (0, result, "")
    } catch let error as AgentError {
        return fail(error.message)
    } catch {
        return fail("Something went wrong: \(error.localizedDescription)")
    }
}

private func fail(_ message: String) -> (exitCode: Int32, stdout: String, stderr: String) {
    (1, "", message)
}

struct AgentError: Error {
    let message: String
}

@MainActor
private func runAgentTool(_ name: String, _ arguments: [String: Any]) async throws -> String {
    switch name {
        case "list_windows":
            return try json(await listWindows())
        case "get_layout":
            let workspace = try workspace(arguments["workspace"])
            return try json(["workspace": workspace.name, "layout": layoutJson(workspace.rootTilingContainer, parent: nil) as Any])
        case "arrange":
            let workspace = try workspace(arguments["workspace"])
            try arrange(workspace, arguments["layout"])
            return try json(["workspace": workspace.name, "layout": layoutJson(workspace.rootTilingContainer, parent: nil) as Any])
        case "focus_window":
            let window = try window(arguments["window"])
            _ = window.focusWindow()
            return "Focused \(window.app.name ?? "the window")"
        case "move_to_workspace":
            let window = try window(arguments["window"])
            let target = try workspace(arguments["workspace"])
            guard let from = window.nodeWorkspace else { throw AgentError(message: "That window isn't on a workspace") }
            let before = SimNode.snapshot(from)
            moveWindow(window, to: target)
            offerUndo("Your agent moved \(windowNames([window.windowId])) to workspace \(target.name)", workspace: from, before: before, near: nil)
            return "Moved \(window.app.name ?? "the window") to workspace \(target.name)"
        case "show_workspace":
            let workspace = try workspace(arguments["workspace"])
            _ = workspace.focusWorkspace()
            return "Showing workspace \(workspace.name)"
        case "save_layout":
            guard let name = (arguments["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
                throw AgentError(message: "Give the layout a name")
            }
            NanopressSettings.shared.saveNamedLayout(SavedLayout.current, as: name)
            return "Saved the layout of every workspace as \"\(name)\""
        case "restore_layout":
            guard let name = arguments["name"] as? String, let layout = NanopressSettings.shared.namedLayout(name) else {
                throw AgentError(message: "There's no saved layout by that name. Saved: \(NanopressSettings.shared.namedLayoutNames.joined(separator: ", "))")
            }
            applySavedLayout(layout)
            return "Restored \"\(name)\""
        case "list_layouts":
            return try json(["layouts": NanopressSettings.shared.namedLayoutNames])
        default:
            throw AgentError(message: "There's no tool called \(name)")
    }
}

// MARK: Reading

@MainActor
private func listWindows() async -> [String: Any] {
    let sharesTitles = NanopressSettings.shared.sharesTitlesWithAgents
    var windows: [[String: Any]] = []
    for window in MacWindow.allWindows.sorted(by: { $0.windowId < $1.windowId }) {
        var entry: [String: Any] = [
            "id": window.windowId,
            "app": window.app.name ?? "",
            "state": state(of: window),
            "focused": window == focus.windowOrNil,
        ]
        if let workspace = window.nodeWorkspace { entry["workspace"] = workspace.name }
        if sharesTitles, let title = try? await window.getTitle(.cancellable) { entry["title"] = title }
        windows.append(entry)
    }
    let workspaces = Workspace.all.map { workspace in
        ["name": workspace.name, "onScreen": workspace.isVisible, "focused": workspace == focus.workspace] as [String: Any]
    }
    return ["windows": windows, "workspaces": workspaces, "titlesShared": sharesTitles]
}

@MainActor
private func state(of window: Window) -> String {
    switch window.parent {
        case is TilingContainer: "tiled"
        case is FloatingWindowsContainer: "floating"
        case is MacosMinimizedWindowsContainer: "minimized"
        case is MacosHiddenAppsWindowsContainer: "hidden"
        case is MacosFullscreenWindowsContainer: "fullscreen"
        default: "other"
    }
}

/// The shape arrange takes. Sizes are shares of the parent group, rounded
@MainActor
private func layoutJson(_ node: TreeNode, parent: TilingContainer?) -> [String: Any]? {
    var result: [String: Any]
    switch node {
        case let window as Window:
            result = ["window": window.windowId]
        case let container as TilingContainer where container.layout == .accordion:
            // On top first
            result = ["stack": windowsByRecency(container).map(\.windowId)]
        case let container as TilingContainer:
            let children = container.children.compactMap { layoutJson($0, parent: container) }
            if children.isEmpty { return nil }
            result = [container.orientation == .h ? "columns" : "rows": children]
        default:
            return nil
    }
    if let parent, parent.layout == .tiles, parent.children.count > 1 {
        let total = parent.children.map { $0.getWeight(parent.orientation) }.reduce(0, +)
        // A decimal, so that 0.43 doesn't come out as 0.42999999999999999
        if total > 0 { result["size"] = NSDecimalNumber(string: String(format: "%.2f", node.getWeight(parent.orientation) / total)) }
    }
    return result
}

private func json(_ value: Any) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

// MARK: Arguments

@MainActor
private func workspace(_ value: Any?) throws -> Workspace {
    guard let value else { return focus.workspace }
    guard let name = value as? String ?? (value as? Int).map(String.init), !name.isEmpty else {
        throw AgentError(message: "A workspace is given by its name, like \"1\"")
    }
    return Workspace.get(byName: name)
}

@MainActor
private func window(_ value: Any?) throws -> Window {
    guard let id = (value as? Int).map(UInt32.init) ?? (value as? String).flatMap(UInt32.init), let window = Window.get(byId: id) else {
        throw AgentError(message: "There's no window with that id. Call list_windows for the current ones")
    }
    return window
}

// MARK: Arranging

/// Builds the layout off to the side, then applies it in one step, like a drop
@MainActor
private func arrange(_ workspace: Workspace, _ layout: Any?) throws {
    guard let layout = layout as? [String: Any] else { throw AgentError(message: "Give the layout as an object, like {\"columns\": [...]}") }
    let sim = SimNode(.workspace)
    var used: Set<UInt32> = []
    let built = try simNode(layout, parentOrientation: nil, used: &used)
    // The root is always a group
    let root: SimNode
    if built.isContainer && built.layout == .tiles {
        root = built
    } else {
        root = SimNode(.container(.h, .tiles))
        built.bind(to: root, weight: 1, index: INDEX_BIND_LAST)
    }
    root.bind(to: sim, weight: 1, index: 0)

    // Windows of this workspace that the layout leaves out go behind the first tile, rather than disappearing
    let leftOut = workspace.rootTilingContainer.allLeafWindowsRecursive.filter { !used.contains($0.windowId) }
    if !leftOut.isEmpty, let first = sim.allWindows.first {
        for window in leftOut {
            stackWindow(SimNode(.window(window.windowId)), onto: first.stackOrSelf)
        }
        first.markAsMostRecentChild()
    }
    sim.normalizeContainers()

    var windows: [UInt32: Window] = [:]
    for window in workspace.rootTilingContainer.allLeafWindowsRecursive { windows[window.windowId] = window }
    for id in used { windows[id] = Window.get(byId: id) }
    let before = SimNode.snapshot(workspace)
    sim.materialize(into: workspace, windows: windows)
    offerUndo("Your agent arranged workspace \(workspace.name)", workspace: workspace, before: before, near: nil)
}

@MainActor
private func simNode(_ value: Any, parentOrientation: Orientation?, used: inout Set<UInt32>) throws -> SimNode {
    guard let object = value as? [String: Any] else { throw AgentError(message: "Every node of the layout is an object") }
    func windowId(_ value: Any?) throws -> UInt32 {
        guard let id = (value as? Int).map(UInt32.init), let window = Window.get(byId: id) else {
            throw AgentError(message: "There's no window with id \(value.map { "\($0)" } ?? "nil"). Call list_windows for the current ones")
        }
        guard !used.contains(id) else { throw AgentError(message: "Window \(id) is in the layout twice") }
        guard window.parent is TilingContainer || window.parent is FloatingWindowsContainer else {
            throw AgentError(message: "Window \(id) is minimized, hidden or in full screen, so it can't take a tile")
        }
        used.insert(id)
        return id
    }
    if let id = object["window"] {
        return SimNode(.window(try windowId(id)))
    }
    if let ids = object["stack"] as? [Any] {
        guard !ids.isEmpty else { throw AgentError(message: "A stack needs at least one window") }
        let stack = SimNode(.container((parentOrientation ?? .h).opposite, .accordion))
        let nodes = try ids.map { SimNode(.window(try windowId($0))) }
        for node in nodes { node.bind(to: stack, weight: 1, index: INDEX_BIND_LAST) }
        nodes.first?.markAsMostRecentChild()
        return stack
    }
    let orientation: Orientation
    let children: [Any]
    if let columns = object["columns"] as? [Any] {
        (orientation, children) = (.h, columns)
    } else if let rows = object["rows"] as? [Any] {
        (orientation, children) = (.v, rows)
    } else {
        throw AgentError(message: "Every node is {\"window\": id}, {\"stack\": [ids]}, {\"columns\": [nodes]} or {\"rows\": [nodes]}")
    }
    guard !children.isEmpty else { throw AgentError(message: "Columns and rows need at least one node") }
    let group = SimNode(.container(orientation, .tiles))
    // Sizes are shares of the group. Nodes without one share what's left
    let sizes = children.map { (($0 as? [String: Any])?["size"] as? Double).map { CGFloat($0) } }
    let given = sizes.compactMap(\.self).reduce(0, +)
    let missing = sizes.filter { $0 == nil }.count
    let rest = missing > 0 ? max(1 - given, 0.1 * CGFloat(missing)) / CGFloat(missing) : 0
    for (child, size) in zip(children, sizes) {
        let node = try simNode(child, parentOrientation: orientation, used: &used)
        node.bind(to: group, weight: max(size ?? rest, 0.05) * 1000, index: INDEX_BIND_LAST)
    }
    return group
}
