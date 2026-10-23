import Common
import Foundation

let configDotfileName = ".nanopress.toml"
func findCustomConfigUrl() -> ConfigFile {
    let xdgConfigHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(filePath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/")
    let candidates: [URL] = switch serverArgs.configLocation {
        case let configLocation?: [URL(filePath: configLocation)]
        case nil: configCandidates(xdgConfigHome, name: "nanopress")
    }
    var existingCandidates: [URL] = candidates.filter { (candidate: URL) in FileManager.default.fileExists(atPath: candidate.path) }
    if existingCandidates.isEmpty && serverArgs.configLocation == nil {
        // Fall back to an AeroSpace config, so that switching from AeroSpace keeps the config
        existingCandidates = configCandidates(xdgConfigHome, name: "aerospace")
            .filter { (candidate: URL) in FileManager.default.fileExists(atPath: candidate.path) }
    }
    let count = existingCandidates.count
    return switch count {
        case 0: .noCustomConfigExists
        case 1: .file(existingCandidates.first.orDie())
        default: .ambiguousConfigError(existingCandidates)
    }
}

private func configCandidates(_ xdgConfigHome: URL, name: String) -> [URL] {
    [
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".\(name).toml"),
        xdgConfigHome.appending(path: name).appending(path: "\(name).toml"),
    ]
}

enum ConfigFile {
    case file(URL), ambiguousConfigError(_ candidates: [URL]), noCustomConfigExists

    var urlOrNil: URL? {
        return switch self {
            case .file(let url): url
            case .ambiguousConfigError, .noCustomConfigExists: nil
        }
    }
}
