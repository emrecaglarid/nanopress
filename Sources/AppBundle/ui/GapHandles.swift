import AppKit
import Common

/// The gaps between tiled windows work like the gaps on the menu map: drag one to resize the windows on both sides,
/// double-click it to even out the group. Each gap gets a panel of its own that stays out of sight until hovered
@MainActor
final class GapHandles {
    static let shared = GapHandles()

    private var handles: [String: GapHandle] = [:]
    /// The resize being dragged, laid out
    private var resized: SimNode? = nil
    private var snapped: CGFloat? = nil

    private init() {}

    /// Called after every layout
    func update() {
        var alive: Set<String> = []
        if TrayMenuModel.shared.isEnabled && !isUnitTest {
            for monitor in monitorInfos {
                let workspace = monitor.activeWorkspace
                let sim = SimNode.snapshot(workspace)
                _ = arrangedTiles(sim, on: workspace) // Lays it out
                let gaps = ResolvedGaps(gaps: effectiveGaps(on: monitor), monitor: monitor)
                for divider in mapDividers(sim.rootContainer) {
                    let thickness = CGFloat(gaps.inner.get(divider.orientation))
                    // Without a gap there's nothing to grab that isn't a window
                    guard thickness >= 4 else { continue }
                    let key = "\(workspace.name)/\(divider.id)"
                    alive.insert(key)
                    let handle = handles[key] ?? GapHandle()
                    handles[key] = handle
                    handle.update(divider, workspace: workspace, frame: frame(of: divider, thickness: thickness))
                }
            }
        }
        for (key, handle) in handles where !alive.contains(key) {
            handle.close()
            handles[key] = nil
        }
    }

    /// In AppKit coordinates
    private func frame(of divider: MapDivider, thickness: CGFloat) -> NSRect {
        let rect = divider.orientation == .h
            ? CGRect(x: divider.position - thickness / 2, y: divider.crossStart, width: thickness, height: divider.crossEnd - divider.crossStart)
            : CGRect(x: divider.crossStart, y: divider.position - thickness / 2, width: divider.crossEnd - divider.crossStart, height: thickness)
        return NSRect(x: rect.minX, y: mainMonitorInfo.height - rect.maxY, width: rect.width, height: rect.height)
    }

    // MARK: Resizing

    /// `delta` is in points along the divider's orientation. The screen previews the sizes until the mouse is released
    fileprivate func resize(_ divider: MapDivider, by delta: CGFloat, in workspace: Workspace) {
        let sim = SimNode.snapshot(workspace)
        _ = arrangedTiles(sim, on: workspace) // Lays it out, so that weights are sizes in points
        let snap = resizeDivider(divider, by: delta, in: sim)
        if snap != snapped, snap != nil {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        snapped = snap
        resized = sim
        DropZoneOverlay.shared.showArrangement(arrangedTiles(sim, on: workspace), monitorRect: workspace.workspaceMonitor.rect.cgRect)
    }

    fileprivate func endResize(_ divider: MapDivider, in workspace: Workspace) {
        DropZoneOverlay.shared.hide()
        if let resized { applyDividerResize([divider], from: resized, in: workspace) }
        resized = nil
        snapped = nil
    }
}

@MainActor
private final class GapHandle {
    private let panel: NSPanel
    private let view = GapHandleView()

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .normal
        panel.collectionBehavior = [.ignoresCycle, .fullScreenNone]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Clicks on the see-through panel land on it instead of going through
        panel.ignoresMouseEvents = false
        panel.contentView = view
    }

    func update(_ divider: MapDivider, workspace: Workspace, frame: NSRect) {
        view.divider = divider
        view.workspace = workspace
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func close() {
        panel.orderOut(nil)
    }
}

/// Shows an accent line while hovered or dragged, nothing otherwise
private final class GapHandleView: NSView {
    var divider: MapDivider? = nil
    weak var workspace: Workspace? = nil
    private var isHovered = false { didSet { needsDisplay = true } }
    private var dragStart: CGPoint? = nil { didSet { needsDisplay = true } }
    private var trackingArea: NSTrackingArea? = nil

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // Almost clear rather than clear, so that the window server doesn't let clicks through
        NSColor.black.withAlphaComponent(0.01).setFill()
        bounds.fill()
        guard isHovered || dragStart != nil, let divider else { return }
        let line = divider.orientation == .h
            ? NSRect(x: bounds.midX - 1.5, y: bounds.minY + 4, width: 3, height: bounds.height - 8)
            : NSRect(x: bounds.minX + 4, y: bounds.midY - 1.5, width: bounds.width - 8, height: 3)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: line, xRadius: 1.5, yRadius: 1.5).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        cursor.push()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        NSCursor.pop()
    }

    private var cursor: NSCursor { divider?.orientation == .v ? .resizeUpDown : .resizeLeftRight }

    override func mouseDown(with event: NSEvent) {
        guard let divider, let workspace else { return }
        if event.clickCount == 2 {
            evenOutDivider(divider, in: workspace)
            return
        }
        dragStart = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart, let divider, let workspace else { return }
        let location = NSEvent.mouseLocation
        // AppKit's y axis points up, the layout's down
        let delta = divider.orientation == .h ? location.x - dragStart.x : dragStart.y - location.y
        MainActor.assumeIsolated { GapHandles.shared.resize(divider, by: delta, in: workspace) }
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil, let divider, let workspace else { return }
        dragStart = nil
        MainActor.assumeIsolated { GapHandles.shared.endResize(divider, in: workspace) }
    }
}
