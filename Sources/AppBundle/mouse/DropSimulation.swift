import AppKit
import Common

/// A detached copy of a workspace tiling tree. Drops are applied to the copy first: the overlay draws the layout the copy
/// produces, and on mouse up the real tree is rebuilt from the copy. That's why the preview always matches the result.
///
/// Keep in sync with: TreeNode.bind (weights and MRU), normalizeContainers, layoutTiles and layoutAccordion
@MainActor
final class SimNode {
    enum Kind: Equatable {
        case workspace
        case container(Orientation, Layout)
        case window(UInt32)
    }

    var kind: Kind
    var weight: CGFloat
    private(set) var children: [SimNode] = []
    private(set) weak var parent: SimNode? = nil
    /// Most recent first. Like the real tree, every bind marks the node as the most recent child
    private(set) var mru: [SimNode] = []
    /// Filled by layout()
    private(set) var rect: Rect? = nil

    init(_ kind: Kind, weight: CGFloat = 1) {
        self.kind = kind
        self.weight = weight
    }

    var windowId: UInt32? { if case .window(let id) = kind { id } else { nil } }
    var orientation: Orientation? { if case .container(let orientation, _) = kind { orientation } else { nil } }
    var layout: Layout? { if case .container(_, let layout) = kind { layout } else { nil } }
    var isContainer: Bool { orientation != nil }
    var isRootContainer: Bool { parent?.kind == .workspace }
    var mostRecentChild: SimNode? { mru.first ?? children.last }
    var ownIndex: Int? { parent?.children.firstIndex { $0 === self } }
    var root: SimNode { parent?.root ?? self }

    var allWindows: [SimNode] { windowId != nil ? [self] : children.flatMap(\.allWindows) }
    var allNodes: [SimNode] { [self] + children.flatMap(\.allNodes) }

    func window(_ id: UInt32) -> SimNode? { allNodes.first { $0.windowId == id } }

    /// Same as Window.stackOrSelf
    var stackOrSelf: SimNode {
        if let parent, parent.layout == .accordion, !parent.isRootContainer { parent } else { self }
    }

    // MARK: Tree operations, mirroring TreeNode

    func bind(to newParent: SimNode, weight: CGFloat, index: Int) {
        if parent != nil { unbind() }
        if weight == WEIGHT_AUTO {
            self.weight = newParent.isContainer && !newParent.children.isEmpty
                ? newParent.children.map(\.weight).reduce(0, +) / CGFloat(newParent.children.count)
                : 1
        } else {
            self.weight = weight
        }
        newParent.children.insert(self, at: index != INDEX_BIND_LAST ? index : newParent.children.count)
        parent = newParent
        markAsMostRecentChild()
    }

    @discardableResult
    func unbind() -> (parent: SimNode, weight: CGFloat, index: Int) {
        guard let parent, let index = ownIndex else { die("SimNode is already unbound") }
        parent.children.remove(at: index)
        parent.mru.removeAll { $0 === self }
        self.parent = nil
        return (parent, weight, index)
    }

    func markAsMostRecentChild() {
        guard let parent else { return }
        parent.mru.removeAll { $0 === self }
        parent.mru.insert(self, at: 0)
        parent.markAsMostRecentChild()
    }

    fileprivate func setOrientation(_ orientation: Orientation) {
        if case .container(_, let layout) = kind { kind = .container(orientation, layout) }
    }
}

// MARK: Snapshot

extension SimNode {
    /// Copies the tiling tree of `workspace`. Window nodes keep window ids, so the result can be applied back with `materialize`
    @MainActor
    static func snapshot(_ workspace: Workspace) -> SimNode {
        let simWorkspace = SimNode(.workspace)
        let root = workspace.rootTilingContainer
        let simRoot = copy(root, weight: 1)
        simRoot.bindForSnapshot(to: simWorkspace)
        return simWorkspace
    }

    @MainActor
    private static func copy(_ node: TreeNode, weight: CGFloat) -> SimNode {
        switch node.tilingTreeNodeCasesOrDie() {
            case .window(let window):
                return SimNode(.window(window.windowId), weight: weight)
            case .tilingContainer(let container):
                let simContainer = SimNode(.container(container.orientation, container.layout), weight: weight)
                var copies: [ObjectIdentifier: SimNode] = [:]
                for child in container.children {
                    let simChild = copy(child, weight: child.getWeight(container.orientation))
                    copies[ObjectIdentifier(child)] = simChild
                    simChild.bindForSnapshot(to: simContainer)
                }
                simContainer.mru = container.mruChildren.compactMap { copies[ObjectIdentifier($0)] }
                return simContainer
        }
    }

    /// Doesn't touch weights and MRU, they are copied as is
    private func bindForSnapshot(to newParent: SimNode) {
        newParent.children.append(self)
        parent = newParent
        if newParent.kind == .workspace { newParent.mru = [self] }
    }

    var rootContainer: SimNode { children.first.orDie() }
}

// MARK: Normalization, mirroring normalizeContainers.swift and TilingContainer.normalizeOppositeOrientationForNestedContainers

extension SimNode {
    /// `self` must be the workspace node
    func normalizeContainers() {
        rootContainer.unbindEmptyAndAutoFlatten() // Beware! rootContainer may change after this line of code
        if config.enableNormalizationOppositeOrientationForNestedContainers {
            rootContainer.normalizeOppositeOrientationForNestedContainers()
        }
    }

    private func unbindEmptyAndAutoFlatten() {
        if children.count == 1, let child = children.first, config.enableNormalizationFlattenContainers && (child.isContainer || !isRootContainer) {
            child.unbind()
            let mruOfParent = parent?.mostRecentChild
            let previousBinding = unbind()
            child.bind(to: previousBinding.parent, weight: previousBinding.weight, index: previousBinding.index)
            if child.isContainer { child.unbindEmptyAndAutoFlatten() }
            if mruOfParent !== self {
                mruOfParent?.markAsMostRecentChild()
            } else {
                child.markAsMostRecentChild()
            }
        } else {
            for child in children where child.isContainer {
                child.unbindEmptyAndAutoFlatten()
            }
            if children.isEmpty && !isRootContainer {
                unbind()
            }
        }
    }

    private func normalizeOppositeOrientationForNestedContainers() {
        if let orientation, orientation == parent?.orientation {
            setOrientation(orientation.opposite)
        }
        for child in children where child.isContainer {
            child.normalizeOppositeOrientationForNestedContainers()
        }
    }
}

// MARK: Layout, mirroring layoutRecursive.swift

extension SimNode {
    /// `self` must be the workspace node. Fills `rect` of every node
    func layout(_ rect: Rect, innerGaps: ResolvedGaps.Inner) {
        // See Workspace.layoutWorkspace for "height - 1"
        rootContainer.layoutRecursive(rect.topLeftCorner, width: rect.width, height: rect.height - 1, innerGaps)
    }

    private func layoutRecursive(_ point: CGPoint, width: CGFloat, height: CGFloat, _ gaps: ResolvedGaps.Inner) {
        rect = Rect(topLeftX: point.x, topLeftY: point.y, width: width, height: height)
        guard let orientation, let layout else { return }
        switch layout {
            case .tiles:
                var point = point
                guard let delta = ((orientation == .h ? width : height) - children.map(\.weight).reduce(0, +)).div(children.count) else { return }
                let lastIndex = children.indices.last
                for (i, child) in children.enumerated() {
                    child.weight += delta
                    let rawGap = gaps.get(orientation).toDouble()
                    let gap = rawGap - (i == 0 ? rawGap / 2 : 0) - (i == lastIndex ? rawGap / 2 : 0)
                    child.layoutRecursive(
                        i == 0 ? point : point.addingOffset(orientation, rawGap / 2),
                        width: orientation == .h ? child.weight - gap : width,
                        height: orientation == .v ? child.weight - gap : height,
                        gaps,
                    )
                    point = point.addingOffset(orientation, child.weight)
                }
            case .accordion:
                guard let mruIndex = mostRecentChild?.ownIndex else { return }
                if children.count > 1 && !isUnitTest {
                    for child in children {
                        child.layoutRecursive(point.addingYOffset(stackWindowsOffset()), width: width, height: height - stackTabsHeight, gaps)
                    }
                    return
                }
                let padding = CGFloat(config.accordionPadding)
                for (index, child) in children.enumerated() {
                    let (lPadding, rPadding): (CGFloat, CGFloat) = switch index {
                        case 0 where children.count == 1: (0, 0)
                        case 0:                           (0, padding)
                        case children.indices.last:       (padding, 0)
                        case mruIndex - 1:                (0, 2 * padding)
                        case mruIndex + 1:                (2 * padding, 0)
                        default:                          (padding, padding)
                    }
                    switch orientation {
                        case .h: child.layoutRecursive(point + CGPoint(x: lPadding, y: 0), width: width - rPadding - lPadding, height: height, gaps)
                        case .v: child.layoutRecursive(point + CGPoint(x: 0, y: lPadding), width: width, height: height - lPadding - rPadding, gaps)
                    }
                }
        }
    }
}

// MARK: Materialize

extension SimNode {
    /// Rebuilds the tiling tree of `workspace` so that it matches `self` (the workspace node)
    @MainActor
    func materialize(into workspace: Workspace, windows: [UInt32: Window]) {
        let root = workspace.rootTilingContainer
        for window in root.allLeafWindowsRecursive { window.unbindFromParent() }
        for child in root.children { child.unbindFromParent() }
        for simWindow in allWindows {
            if let window = windows[simWindow.windowId.orDie()], window.parent != nil { window.unbindFromParent() }
        }
        let simRoot = rootContainer
        root.layout = simRoot.layout.orDie()
        root.changeOrientation(simRoot.orientation.orDie())
        var realNodes: [ObjectIdentifier: TreeNode] = [ObjectIdentifier(simRoot): root]
        simRoot.build(into: root, windows, &realNodes)
        simRoot.restoreMru(realNodes)
    }

    @MainActor
    private func build(into container: TilingContainer, _ windows: [UInt32: Window], _ realNodes: inout [ObjectIdentifier: TreeNode]) {
        for child in children {
            let realChild: TreeNode
            switch child.kind {
                case .window(let id):
                    let window = windows[id].orDie("Window \(id) is missing")
                    window.bind(to: container, adaptiveWeight: child.weight, index: INDEX_BIND_LAST)
                    realChild = window
                case .container(let orientation, let layout):
                    let realContainer = TilingContainer(parent: container, adaptiveWeight: child.weight, orientation, layout, index: INDEX_BIND_LAST)
                    child.build(into: realContainer, windows, &realNodes)
                    realChild = realContainer
                case .workspace:
                    die("Workspace can't be nested")
            }
            realNodes[ObjectIdentifier(child)] = realChild
        }
    }

    /// Post-order, so that every container ends up with the MRU order of its sim counterpart
    @MainActor
    private func restoreMru(_ realNodes: [ObjectIdentifier: TreeNode]) {
        for child in children { child.restoreMru(realNodes) }
        for child in mru.reversed() { realNodes[ObjectIdentifier(child)]?.markAsMostRecentChild() }
    }
}
