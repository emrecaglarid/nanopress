import AppKit
import Common
import Network

func startUnixSocketServer() {
    try? FileManager.default.removeItem(atPath: socketPath)
    let params = NWParameters.tcp
    params.requiredLocalEndpoint = .unix(path: socketPath)
    let listener = Result { try NWListener(using: params) }.getOrDie()
    listener.newConnectionHandler = { connection in
        Task.startUnstructured {
            defer { connection.cancel() }
            connection.start(queue: .global())
            await newConnection(connection)
        }
    }
    listener.start(queue: .global())
}

/// A debug build turns tiling off in the release app while it runs, so that the two don't both move windows
func toggleReleaseServerIfDebug(isEnabled: Bool) async {
    if serverArgs.isReadOnly { return }
    if !isDebug { return }
    let socketFile = "/tmp/\(stableAeroSpaceAppId)-\(unixUserName).sock"
    let connection = NWConnection(to: NWEndpoint.unix(path: socketFile), using: .tcp)
    defer { connection.cancel() }
    if await connection.initConnection().error != nil { // Can't connect, nanopress.app is not running
        return
    }

    let req = ClientRequest(args: ["enable", isEnabled ? "on" : "off"], stdin: "", windowId: nil, workspace: nil)
    _ = await connection.writeAtomic(req)
    _ = await connection.readNonAtomic()
}

private let serverVersionAndHash = "\(aeroSpaceAppVersion) \(gitHash)"

private func newConnection(_ connection: NWConnection) async { // todo add exit codes
    func answerToClient(exitCode: Int32, stdout: String = "", stderr: String = "") async {
        let ans = ServerAnswer(exitCode: exitCode, stdout: stdout, stderr: stderr, serverVersionAndHash: serverVersionAndHash)
        await answerToClient(ans)
    }
    func answerToClient(_ ans: ServerAnswer) async {
        _ = await connection.writeAtomic(ans)
    }

    guard let clientVersion = await connection.readUInt32().getIgnoringErrorsOrNil() else { return }
    // The server unconditionally answers with the only version it supports
    if await connection.writeUInt32(SOCKET_PROTOCOL_VERSION).error != nil { return }
    if clientVersion != SOCKET_PROTOCOL_VERSION { return }

    while true {
        guard let rawRequest = await connection.readNonAtomic().getOrNil(onFailure: { err in
            await answerToClient(exitCode: EXIT_CODE_TWO, stderr: "Error: \(err)")
        }) else { return }
        guard let request = await ClientRequest.decodeJson(rawRequest).getOrNil(onFailure: { err in
            let msg = """
                Can't parse request \(String(describing: String(data: rawRequest, encoding: .utf8)).singleQuoted).
                Error: \(err)
                """
            return await answerToClient(exitCode: EXIT_CODE_TWO, stderr: msg)
        }) else { continue }
        // Requests are tool calls from `nanopress mcp`, the version check of `nanopress --version`, and a debug build
        // turning tiling on and off (see toggleReleaseServerIfDebug)
        switch request.args {
            case [agentRequestArg]:
                let (exitCode, stdout, stderr) = await handleAgentRequest(request.stdin)
                await answerToClient(exitCode: exitCode, stdout: stdout, stderr: stderr)
            case ["enable", "on"], ["enable", "off"]:
                await setTilingEnabled(request.args[1] == "on")
                await answerToClient(exitCode: EXIT_CODE_ZERO)
            case []:
                await answerToClient(exitCode: EXIT_CODE_ZERO)
            default:
                await answerToClient(exitCode: EXIT_CODE_TWO, stderr: "nanopress doesn't take commands. 'nanopress mcp' connects an AI agent")
        }
    }
}
