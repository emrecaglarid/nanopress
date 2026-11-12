import Common
import OrderedCollections

/// The tiling settings that aren't in NanopressSettings. Fixed in code: nanopress has no config file. Tests change
/// some of them
@MainActor var config: Config = Config()

struct Config: ConvenienceMutable {
    var enableNormalizationFlattenContainers: Bool = true
    var enableNormalizationOppositeOrientationForNestedContainers: Bool = true
    var defaultRootContainerLayout: Layout = .tiles
    var defaultRootContainerOrientation: DefaultContainerOrientation = .auto
    var automaticallyUnhideMacosHiddenApps: Bool = false
    var accordionPadding: Int = 30
    var persistentWorkspaces: OrderedSet<String> = ["1", "2", "3"]
    var focusFollowsMouse: FocusFollowsMouse = FocusFollowsMouse()
    /// Only tests read it. The app takes its gaps from the spacing in NanopressSettings, see effectiveGaps
    var gaps: Gaps = .zero
}

struct FocusFollowsMouse: ConvenienceMutable {
    var enabled: Bool = false
}

enum DefaultContainerOrientation: String {
    case horizontal, vertical, auto
}

struct Gaps: ConvenienceMutable, Equatable, Sendable {
    var inner: Inner
    var outer: Outer

    static let zero = Gaps(inner: .init(vertical: 0, horizontal: 0), outer: .init(left: 0, bottom: 0, top: 0, right: 0))

    struct Inner: ConvenienceMutable, Equatable, Sendable {
        var vertical: Int
        var horizontal: Int

        func get(_ orientation: Orientation) -> Int {
            orientation == .h ? horizontal : vertical
        }
    }

    struct Outer: ConvenienceMutable, Equatable, Sendable {
        var left: Int
        var bottom: Int
        var top: Int
        var right: Int
    }
}

/// The gaps on one monitor. Gaps are the same on every monitor now, without a config to set them per monitor
struct ResolvedGaps {
    typealias Inner = Gaps.Inner
    typealias Outer = Gaps.Outer

    let inner: Inner
    let outer: Outer

    init(gaps: Gaps, monitor _: any MonitorInfo) {
        inner = gaps.inner
        outer = gaps.outer
    }
}
