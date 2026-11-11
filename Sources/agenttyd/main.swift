import AgenttyClient
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

// `agenttyd pairing-link` asks the running daemon for a pairing code and
// prints the link an iPhone can pair with. Meant for the iOS Simulator, which
// has no camera, and for tests.
if arguments.first == "pairing-link" {
    arguments.removeFirst()
    var host: String?
    while let argument = arguments.popFirst() {
        switch argument {
        case "--port":
            guard let value = arguments.popFirst().flatMap(UInt16.init) else { fail("--port needs a number", status: 2) }
            port = value
        case "--host":
            guard let value = arguments.popFirst() else { fail("--host needs a name or address", status: 2) }
            host = value
        default:
            fail("unknown option \(argument)", status: 2)
        }
    }
    printPairingLink(port: port, host: host)
}

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
               agenttyd pairing-link [--port N] [--host NAME]

          --port N       TCP port to listen on, or of the daemon to ask (default \(agenttyDefaultPort))
          --local-only   Listen on 127.0.0.1 only, not on the Tailscale address

        pairing-link prints a link that pairs one device with the running
        daemon. It works once and for five minutes. --host sets the name the
        device should connect to (default: this Mac's Tailscale name, or
        127.0.0.1 when Tailscale is not connected).
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
    server = HostServer(configuration: .init(port: port, token: token, listenOnTailscale: listenOnTailscale, foldersFile: HostEnvironment.foldersFile, devicesFile: HostEnvironment.devicesFile))
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

func fail(_ message: String, status: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("agenttyd: \(message)\n".utf8))
    exit(status)
}

func printPairingLink(port: UInt16, host: String?) -> Never {
    guard let token = try? HostEnvironment.loadOrCreateToken() else { fail("could not read this Mac's token") }
    var target = host
    if target == nil, case .ready(let name) = Tailscale.status() { target = name }
    let connection = AgenttyConnection(host: "127.0.0.1", port: port, token: token, clientName: "agenttyd")
    connection.onMessage = { message in
        switch message {
        case .welcome:
            connection.send(.createPairingCode)
        case .pairingCode(let code, _):
            let info = PairingInfo(host: target ?? "127.0.0.1", port: port, code: code, name: Host.current().localizedName ?? "Mac")
            print(info.url.absoluteString)
            exit(0)
        case .error(let text):
            fail(text)
        default:
            break
        }
    }
    connection.onState = { state in
        if case .closed(let reason) = state { fail("no daemon answered on port \(port)" + (reason.map { ": \($0)" } ?? "")) }
    }
    connection.connect()
    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { fail("timed out waiting for the daemon on port \(port)") }
    dispatchMain()
}
