import AgenttyHost
import AgenttyProtocol
import Foundation

// agenttyd: the Agentty host daemon. It owns the terminal sessions so they
// keep running when the app window is closed.

setvbuf(stdout, nil, _IOLBF, 0)
signal(SIGPIPE, SIG_IGN)

var port = agenttyDefaultPort
var listenOnTailscale = true
var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.popFirst() {
    switch argument {
    case "--port":
        guard let value = arguments.popFirst().flatMap(UInt16.init) else {
            FileHandle.standardError.write(Data("agenttyd: --port needs a number\n".utf8))
            exit(2)
        }
        port = value
    case "--local-only":
        listenOnTailscale = false
    case "--help", "-h":
        print("""
        Usage: agenttyd [--port N] [--local-only]

          --port N       TCP port to listen on (default \(agenttyDefaultPort))
          --local-only   Listen on 127.0.0.1 only, not on the Tailscale address
        """)
        exit(0)
    default:
        FileHandle.standardError.write(Data("agenttyd: unknown option \(argument)\n".utf8))
        exit(2)
    }
}

let server: HostServer
do {
    let token = try HostEnvironment.loadOrCreateToken()
    server = HostServer(configuration: .init(port: port, token: token, listenOnTailscale: listenOnTailscale, foldersFile: HostEnvironment.foldersFile))
    let bound = try server.start()
    print("agenttyd listening on 127.0.0.1:\(bound)")
} catch {
    FileHandle.standardError.write(Data("agenttyd: \(error)\n".utf8))
    exit(1)
}

// Hang up every session on shutdown, like closing a terminal window does.
var signalSources: [DispatchSourceSignal] = []
for number in [SIGTERM, SIGINT] {
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler {
        server.stop()
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

dispatchMain()
