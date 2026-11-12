import Common
import Darwin
import Foundation
import Network

let usage =
    """
    USAGE: \(CommandLine.arguments.first ?? "nanopress") [-h|--help] [-v|--version] mcp

    SUBCOMMANDS:
      mcp   Connect an AI agent to nanopress, as an MCP server over stdio
    """

@main
struct Main {
    static func main() async {
        let args = CommandLine.arguments.slice(1...) ?? []

        switch args.first {
            case nil:
                exit(EXIT_CODE_TWO, err: usage)
            case "--help", "-h":
                exit(EXIT_CODE_ZERO, out: usage)
            case "--version", "-v":
                await printVersion()
            case "mcp":
                await runMcpServer()
            case let subcommand?:
                exit(EXIT_CODE_TWO, err: "Unknown subcommand \(subcommand.singleQuoted)\n\n\(usage)")
        }
    }
}

private func printVersion() async -> Never {
    let connection = NWConnection(to: NWEndpoint.unix(path: socketPath), using: .tcp)
    let serverVersionAndHash: String?
    switch await connection.initConnection().error {
        case nil:
            serverVersionAndHash = await askServerVersion(connection)
        case .nwError(let e):
            eprint(e.localizedDescription)
            serverVersionAndHash = nil
        case .customError(let msg):
            exit(EXIT_CODE_TWO, err: msg)
    }
    print(
        """
        nanopress CLI client version: \(cliClientVersionAndHash)
        nanopress.app server version: \(serverVersionAndHash ?? "Unknown. The server is not responding")
        """,
    )
    if serverVersionAndHash != nil && cliClientVersionAndHash != serverVersionAndHash {
        eprint(
            """
            Warning: nanopress client/server versions don't match. Possible fixes:
              - Restart nanopress.app (server restart is required after each update)
              - Reinstall and restart nanopress (corrupted installation)
            """,
        )
    }
    exit(EXIT_CODE_ZERO)
}

/// A request without arguments, which the server answers with just its version
private func askServerVersion(_ connection: NWConnection) async -> String? {
    if await connection.writeAtomic(ClientRequest(args: [], stdin: "", windowId: nil, workspace: nil)).error != nil { return nil }
    guard let answer = await connection.readNonAtomic().getIgnoringErrorsOrNil() else { return nil }
    return (try? JSONDecoder().decode(ServerAnswer.self, from: answer))?.serverVersionAndHash
}
