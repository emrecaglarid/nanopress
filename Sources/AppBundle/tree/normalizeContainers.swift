extension Workspace {
    @MainActor func normalizeContainers() {
        // A group is checked for a single child before its own empty groups are removed, so one pass can leave a group
        // with one child that only the next refresh flattens, and the layout moves a refresh later. Until nothing changes
        for _ in 0 ..< 8 {
            let count = rootTilingContainer.nodeCount
            rootTilingContainer.unbindEmptyAndAutoFlatten() // Beware! rootTilingContainer may change after this line of code
            if rootTilingContainer.nodeCount == count { break }
        }
        if config.enableNormalizationOppositeOrientationForNestedContainers {
            rootTilingContainer.normalizeOppositeOrientationForNestedContainers()
        }
    }
}

extension TreeNode {
    @MainActor fileprivate var nodeCount: Int { 1 + children.reduce(0) { $0 + $1.nodeCount } }
}

extension TilingContainer {
    @MainActor fileprivate func unbindEmptyAndAutoFlatten() {
        if let child = children.singleOrNil(), config.enableNormalizationFlattenContainers && (child is TilingContainer || !isRootContainer) {
            child.unbindFromParent()
            let mru = parent?.mostRecentChild
            let previousBinding = unbindFromParent()
            child.bind(to: previousBinding.parent, adaptiveWeight: previousBinding.adaptiveWeight, index: previousBinding.index)
            (child as? TilingContainer)?.unbindEmptyAndAutoFlatten()
            if mru != self {
                mru?.markAsMostRecentChild()
            } else {
                child.markAsMostRecentChild()
            }
        } else {
            for child in children {
                (child as? TilingContainer)?.unbindEmptyAndAutoFlatten()
            }
            if children.isEmpty && !isRootContainer {
                unbindFromParent()
            }
        }
    }
}
