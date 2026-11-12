import AppKit
import Common
import Foundation

@MainActor public func initAppBundle() {
    Task.startUnstructured {
        initTerminationHandler()
        unsafe _isCli = false
        initServerArgs()
        await waitForAccessibilityPermission_nonCancellable()
        // macOS waits about 6 seconds for an app that doesn't answer. At startup that's per call, and an app that's
        // stuck, or swapped out because memory is low, held everything up. Its windows are picked up on a later refresh
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 2)
        let startupStart = ContinuousClock.now
        if isDebug {
            await toggleReleaseServerIfDebug(isEnabled: false)
            interceptTermination(SIGINT)
            interceptTermination(SIGKILL)
        }

        syncFocusFollowsMouse(config)
        startUnixSocketServer()
        GlobalObserver.initObserver()
        BackdropPanels.shared.refresh()
        Workspace.garbageCollectUnusedWorkspaces() // init workspaces
        _ = Workspace.all.first?.focusWorkspace()
        await runHeavyCompleteRefreshSession(
            .startup,
            // It's important for the first initialization to be non cancellable
            // to make sure that isStartup propagates to all places
            assumeCancellable: false,
            layoutWorkspaces: false,
        )
        try await runLightSession(.startup, .forceRun) {
            restoreSavedLayout()
        }
        startupLog.notice("Started in \((ContinuousClock.now - startupStart).milliseconds, privacy: .public) ms")
    }
}

var isStartup: Bool { refreshSessionEvent?.isStartup == true }

struct ServerArgs: Sendable {
    var isReadOnly: Bool = false
}

private let serverHelp = """
    USAGE: \(CommandLine.arguments.first ?? "nanopress.app/Contents/MacOS/nanopress") [<options>]

    OPTIONS:
      -h, --help              Print help
      -v, --version           Print nanopress.app version
      --read-only             Disable window management
    """

nonisolated(unsafe) private var _serverArgs = ServerArgs()
var serverArgs: ServerArgs { unsafe _serverArgs }
private func initServerArgs() {
    let args = CommandLine.arguments.slice(1...) ?? []
    if args.contains(where: { $0 == "-h" || $0 == "--help" }) {
        exit(EXIT_CODE_ZERO, out: serverHelp)
    }
    var index = 0
    while index < args.count {
        let current = args[index]
        index += 1
        switch current {
            case "--version", "-v":
                exit(EXIT_CODE_ZERO, out: "\(aeroSpaceAppVersion) \(gitHash)")
            case "--read-only": // todo rename to '--disabled' and unite with disabled feature
                unsafe _serverArgs.isReadOnly = true
            case "-NSDocumentRevisionsDebugMode" where isDebug:
                // Skip Xcode CLI args.
                // Usually it's '-NSDocumentRevisionsDebugMode NO'/'-NSDocumentRevisionsDebugMode YES'
                while args.getOrNil(atIndex: index)?.starts(with: "-") == false { index += 1 }
            default:
                exit(EXIT_CODE_TWO, err: "Unrecognized flag \(args.first.orDie().singleQuoted)")
        }
    }
}
