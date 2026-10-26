import AppKit
import Common

/// Some apps won't make a window smaller than a minimum size. Given a smaller tile, the window sticks out of it, past
/// its neighbours or off the screen. nanopress widens the tile to fit, taking the room from its neighbours, or lets the
/// window float when they can't spare enough
@MainActor private var pendingChecks: Set<UInt32> = []

/// Neighbours don't get narrower than this to make room
private let neighbourMinimum: CGFloat = 200

/// Called when a window resized without the mouse. The check waits a moment, because a frame nanopress just set may not
/// have reached the app yet
@MainActor
func checkForMinimumSize(_ window: Window) {
    let id = window.windowId
    guard window.parent is TilingContainer, !pendingChecks.contains(id) else { return }
    pendingChecks.insert(id)
    Task.startUnstructured { @MainActor in
        defer { pendingChecks.remove(id) }
        try await Task.sleep(for: .milliseconds(400))
        guard window.parent is TilingContainer, currentlyManipulatedWithMouseWindowId == nil, !isLeftMouseButtonDown,
              let workspace = window.nodeWorkspace, workspace.isVisible,
              let applied = window.lastAppliedLayoutPhysicalRect,
              let rect = try await window.getAxRect(.cancellable) else { return }
        let extra = CGSize(width: rect.width - applied.width, height: rect.height - applied.height)
        guard extra.width > 4 || extra.height > 4, let token: RunSessionGuard = .isServerEnabled else { return }
        try await runLightSession(.ax("minimumSize"), token) {
            if !makeRoom(for: window, extra: extra) {
                let before = SimNode.snapshot(workspace)
                window.bindAsFloatingWindow(to: workspace)
                offerUndo("\(windowNames([window.windowId])) needs more room than a tile here, so it floats", workspace: workspace, before: before, near: nil)
            }
        }
    }
}

/// Grows the tile of `window` by `extra` where its neighbours can spare it. False if they can't
@MainActor
func makeRoom(for window: Window, extra: CGSize) -> Bool {
    for (orientation, needed) in [(Orientation.h, extra.width), (.v, extra.height)] where needed > 4 {
        var node: TreeNode = window.stackOrSelf
        var fitted = false
        while let parent = node.parent as? TilingContainer {
            if parent.layout == .tiles && parent.orientation == orientation && parent.children.count > 1 {
                let siblings = parent.children.filter { $0 !== node }
                let spare = siblings.map { max($0.getWeight(orientation) - neighbourMinimum, 0) }
                let total = spare.reduce(0, +)
                guard total >= needed else { return false }
                for (sibling, spare) in zip(siblings, spare) {
                    sibling.setWeight(orientation, sibling.getWeight(orientation) - needed * spare / total)
                }
                node.setWeight(orientation, node.getWeight(orientation) + needed)
                fitted = true
                break
            }
            node = parent
        }
        // Alone along this side: there's nothing to take room from
        if !fitted { return false }
    }
    return true
}
