@testable import AppBundle
import Common
import Foundation
import XCTest

let projectRoot: URL = {
    var url = URL(filePath: #filePath).absoluteURL
    check(FileManager.default.fileExists(atPath: url.path))
    while !FileManager.default.fileExists(atPath: url.appending(component: ".git").path) {
        url.deleteLastPathComponent()
    }
    return url
}()

@MainActor
func setUpWorkspacesForTests() {
    config = Config()
    config.enableNormalizationFlattenContainers = false // Make layout tests more predictable
    config.enableNormalizationOppositeOrientationForNestedContainers = false // Make layout tests more predictable
    config.defaultRootContainerOrientation = .horizontal // Make default layout predictable

    // Don't create any workspaces for tests
    config.persistentWorkspaces = []

    for workspace in Workspace.all {
        for child in workspace.children {
            child.unbindFromParent()
        }
    }
    check(Workspace.get(byName: "setUpWorkspacesForTests").focusWorkspace())
    Workspace.garbageCollectUnusedWorkspaces()
    check(focus.workspace.isEffectivelyEmpty)
    check(focus.workspace === Workspace.all.singleOrNil(), Workspace.all.map(\.description).joined(separator: ", "))
    check(mainMonitorInfo.setActiveWorkspace(focus.workspace))

    TestApp.shared.focusedWindow = nil
    TestApp.shared.windows = []
}

extension TreeNode {
    var layoutDescription: LayoutDescription {
        return switch nodeCases {
            case .window(let window): .window(window.windowId)
            case .workspace(let workspace): .workspace(workspace.children.map(\.layoutDescription))
            case .floatingWindowsContainer(let container): .floatingWindowsContainer(container.children.map(\.layoutDescription))
            case .macosMinimizedWindowsContainer: .macosMinimized
            case .macosFullscreenWindowsContainer: .macosFullscreen
            case .macosHiddenAppsWindowsContainer: .macosHiddeAppWindow
            case .macosPopupWindowsContainer: .macosPopupWindowsContainer
            case .tilingContainer(let container):
                switch container.layout {
                    case .tiles:
                        container.orientation == .h
                            ? .h_tiles(container.children.map(\.layoutDescription))
                            : .v_tiles(container.children.map(\.layoutDescription))
                    case .accordion:
                        container.orientation == .h
                            ? .h_accordion(container.children.map(\.layoutDescription))
                            : .v_accordion(container.children.map(\.layoutDescription))
                }
        }
    }
}

enum LayoutDescription: Equatable {
    case workspace([LayoutDescription])
    case h_tiles([LayoutDescription])
    case v_tiles([LayoutDescription])
    case h_accordion([LayoutDescription])
    case v_accordion([LayoutDescription])
    case floatingWindowsContainer([LayoutDescription])
    case window(UInt32)
    case macosPopupWindowsContainer
    case macosMinimized
    case macosHiddeAppWindow
    case macosFullscreen
}
