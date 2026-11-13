import AgentTermClient
import AgentTermHost
import AgentTermProtocol
import Foundation

// agenttermd: the AgentTerm host daemon. It owns the terminal sessions so they
// keep running when the app window is closed.

setvbuf(stdout, nil, _IOLBF, 0)
signal(SIGPIPE, SIG_IGN)

var port = agenttermDefaultPort
var listenOnTailscale = true
var askServices = true
var protocolVersion = agenttermProtocolVersion
var home = NSHomeDirectory()
var agentsDirectory: String?
var arguments = CommandLine.arguments.dropFirst()

// `agenttermd statusline <file>` is what Claude Code sessions started by
// AgentTerm run as their status line. See StatusLineRelay.
if arguments.first == "statusline" {
    arguments.removeFirst()
    guard let file = arguments.popFirst() else { fail("statusline needs a file", status: 2) }
    let output = StatusLineRelay.run(input: FileHandle.standardInput.readDataToEndOfFile(), file: file)
    FileHandle.standardOutput.write(output)
    exit(0)
}

// `agenttermd hook <agent> <event>` is what the hooks of an agent started by
// AgentTerm run: it saves what the agent tells it for the host, in the file
// AGENTTERM_EVENTS names. It never fails the agent's hook. See AgentHooks.
if arguments.first == "hook" {
    arguments.removeFirst()
    let agent = arguments.popFirst() ?? ""
    let event = arguments.popFirst() ?? ""
    let input = FileHandle.standardInput.readDataToEndOfFile()
    if let file = ProcessInfo.processInfo.environment[AgentHooks.eventsVariable], !file.isEmpty {
        AgentHooks.save(input, agent: agent, event: event, to: file)
    }
    if let reply = AgentHooks.reply(agent: agent, event: event) { print(reply) }
    exit(0)
}

// `agenttermd mcp` is the MCP server agents are given (#10). Inside a session
// of an agent AgentTerm started, it asks the host on this Mac, as that
// session, for what the agent's tools do; elsewhere it offers no tools.
if arguments.first == "mcp" {
    var ask: AgentShellsMCP.Ask?
    let named = ProcessInfo.processInfo.environment[HostServer.agentShellsVariable]?.split(separator: " ").map(String.init) ?? []
    if named.count == 2, let port = UInt16(named[0]), let token = try? HostEnvironment.loadOrCreateToken() {
        let key = named[1]
        let connection = AgentTermConnection(host: "127.0.0.1", port: port, credential: .token(token), clientName: "MCP")
        let lock = NSLock()
        var answers: [Int: AgentShellResult] = [:]
        var waiting: [Int: DispatchSemaphore] = [:]
        var next = 0
        connection.onMessage = { message in
            guard case .agentShellResult(let id, let result) = message else { return }
            lock.lock()
            answers[id] = result
            let semaphore = waiting.removeValue(forKey: id)
            lock.unlock()
            semaphore?.signal()
        }
        DispatchQueue.main.async { connection.connect() }
        ask = { request in
            lock.lock()
            next += 1
            let id = next
            let semaphore = DispatchSemaphore(value: 0)
            waiting[id] = semaphore
            lock.unlock()
            DispatchQueue.main.async { connection.send(.agentShell(id: id, key: key, request: request)) }
            guard semaphore.wait(timeout: .now() + 15) == .success else { return .refused("AgentTerm's host did not answer.") }
            lock.lock()
            defer { lock.unlock() }
            return answers.removeValue(forKey: id) ?? .refused("AgentTerm's host did not answer.")
        }
    }
    let server = AgentShellsMCP(ask: ask, version: AppChannel.current.appName)
    // Lines are read and answered in turn, off the main queue, where the
    // connection's answers arrive.
    Thread.detachNewThread {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty, let reply = server.handle(line) else { continue }
            print(reply)
        }
        exit(0)
    }
    dispatchMain()
}

// `agenttermd pairing-link` asks the running daemon for a pairing code and
// prints the link an iPhone can pair with. Meant for the iOS Simulator, which
// has no camera, and for tests.
if arguments.first == "pairing-link" {
    arguments.removeFirst()
    var host: String?
    var name: String?
    while let argument = arguments.popFirst() {
        switch argument {
        case "--name":
            guard let value = arguments.popFirst() else { fail("--name needs a name", status: 2) }
            name = value
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
    printPairingLink(port: port, host: host, name: name)
}

// `agenttermd take-control` plays a Mac that starts using a session: it
// waits for the daemon's first session, types a command in it at a size of
// its own, and stays attached for a while. For testing what a phone shows
// while the Mac has a session. Not in the help.
if arguments.first == "take-control" {
    arguments.removeFirst()
    var size = TermSize(cols: 150, rows: 45)
    var hold: TimeInterval = 30
    var wait: TimeInterval = 0
    var typed = ""
    while let argument = arguments.popFirst() {
        switch argument {
        case "--port":
            guard let value = arguments.popFirst().flatMap(UInt16.init) else { fail("--port needs a number", status: 2) }
            port = value
        case "--cols":
            guard let value = arguments.popFirst().flatMap(Int.init) else { fail("--cols needs a number", status: 2) }
            size.cols = value
        case "--rows":
            guard let value = arguments.popFirst().flatMap(Int.init) else { fail("--rows needs a number", status: 2) }
            size.rows = value
        case "--hold":
            guard let value = arguments.popFirst().flatMap(TimeInterval.init) else { fail("--hold needs seconds", status: 2) }
            hold = value
        case "--after":
            guard let value = arguments.popFirst().flatMap(TimeInterval.init) else { fail("--after needs seconds", status: 2) }
            wait = value
        case "--type":
            guard let value = arguments.popFirst() else { fail("--type needs text", status: 2) }
            typed = value
        default:
            fail("unknown option \(argument)", status: 2)
        }
    }
    takeControl(port: port, size: size, after: wait, typing: typed, hold: hold)
}

while let argument = arguments.popFirst() {
    switch argument {
    case "--port":
        guard let value = arguments.popFirst().flatMap(UInt16.init) else {
            FileHandle.standardError.write(Data("agenttermd: --port needs a number\n".utf8))
            exit(2)
        }
        port = value
    case "--local-only":
        listenOnTailscale = false
    case "--no-account-usage":
        askServices = false
    case "--protocol-version":
        // For testing the apps against a host of another release. Not in the help.
        guard let value = arguments.popFirst().flatMap(Int.init) else { fail("--protocol-version needs a number", status: 2) }
        protocolVersion = value
    case "--home":
        guard let value = arguments.popFirst() else { fail("--home needs a folder", status: 2) }
        home = value
    case "--agents":
        guard let value = arguments.popFirst() else { fail("--agents needs a folder", status: 2) }
        agentsDirectory = value
    case "--help", "-h":
        print(
            """
            Usage: agenttermd [--port N] [--local-only]
                   agenttermd pairing-link [--port N] [--host NAME] [--name LABEL]

              --port N       TCP port to listen on, or of the daemon to ask (default \(agenttermDefaultPort))
              --local-only   Listen on 127.0.0.1 only, not on the Tailscale address
              --no-account-usage
                             Do not ask the agents' services what their accounts
                             have left. Their sign-ins are then never read.
              --home DIR     Read agent history from DIR instead of the home folder,
                             and start the folder picker there (for tests)
              --agents DIR   Take the agents' programs from DIR only, instead of
                             looking for the installed ones (for tests)

            pairing-link prints a link that pairs one device with the running
            daemon. It works once and for five minutes. --host sets the name the
            device should connect to (default: this Mac's Tailscale name, or
            127.0.0.1 when Tailscale is not connected). --name sets what the device
            calls this Mac (default: the Mac's name).
            """)
        exit(0)
    default:
        FileHandle.standardError.write(Data("agenttermd: unknown option \(argument)\n".utf8))
        exit(2)
    }
}

let server: HostServer
do {
    let token = try HostEnvironment.loadOrCreateToken()
    var configuration = HostServer.Configuration(
        port: port, token: token, listenOnTailscale: listenOnTailscale, foldersFile: HostEnvironment.foldersFile, devicesFile: HostEnvironment.devicesFile, home: home,
        statusLineTool: Bundle.main.executablePath, usageDirectory: HostEnvironment.usageDirectory, fetchAccountUsage: askServices ? { AccountUsageFetcher.fetch(agent: $0) } : nil)
    configuration.protocolVersion = protocolVersion
    configuration.hooksDirectory = HostEnvironment.supportDirectory.appendingPathComponent("hooks", isDirectory: true)
    // Installs the MCP server in the agents' own configuration, for this
    // Mac's host only: not for one with a state folder of its own (a test,
    // a trial run), which must leave the user's agents alone.
    if (ProcessInfo.processInfo.environment["AGENTTERM_STATE_DIR"] ?? "").isEmpty, agentsDirectory == nil, let tool = Bundle.main.executablePath {
        configuration.agentShells = AgentShellsInstall(directory: HostEnvironment.supportDirectory, tool: tool)
    }
    // Notes that it runs, so the next host knows whether this one died.
    configuration.stateDirectory = HostEnvironment.supportDirectory
    if let agentsDirectory {
        configuration.detectAgents = { AgentDetector.detect(in: agentsDirectory) }
        configuration.agentsDirectory = agentsDirectory
    }
    // Started at login, when the user asked for that. The app may have been
    // moved since: launchd has to start the host of the app that is here now.
    configuration.loginItem = LoginItem.forThisHost()
    configuration.loginItem?.refresh()
    server = HostServer(configuration: configuration)
    let bound = try server.start()
    print("agenttermd listening on 127.0.0.1:\(bound)")
} catch HostServer.StartError.keepsDying(let count) {
    // With status 0, so that launchd does not start it again: it is broken
    // until the user asks for it. The next host reports it.
    FileHandle.standardError.write(Data("agenttermd: \(HostServer.StartError.keepsDying(count))\n".utf8))
    exit(0)
} catch {
    FileHandle.standardError.write(Data("agenttermd: \(error)\n".utf8))
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
    FileHandle.standardError.write(Data("agenttermd: \(message)\n".utf8))
    exit(status)
}

func takeControl(port: UInt16, size: TermSize, after wait: TimeInterval, typing typed: String, hold: TimeInterval) -> Never {
    guard let token = try? HostEnvironment.loadOrCreateToken() else { fail("could not read this Mac's token") }
    let connection = AgentTermConnection(host: "127.0.0.1", port: port, token: token, clientName: "Mac (test)")
    var taken = false
    connection.onMessage = { message in
        switch message {
        case .sessions(let list):
            // The first session, once, some time after it appeared: a
            // phone that opens it takes its size first.
            guard !taken, let session = list.first else { return }
            taken = true
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                connection.send(.attach(session: session.id, size: size))
                connection.send(.takeControl(session: session.id, size: size))
                if !typed.isEmpty { connection.sendInput(Data((typed + "\r").utf8), to: session.id) }
                print("took session \(session.id) at \(size.cols)x\(size.rows)")
                DispatchQueue.main.asyncAfter(deadline: .now() + hold) { exit(0) }
            }
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
    dispatchMain()
}

func printPairingLink(port: UInt16, host: String?, name: String?) -> Never {
    guard let token = try? HostEnvironment.loadOrCreateToken() else { fail("could not read this Mac's token") }
    var target = host
    if target == nil, case .ready(let name) = Tailscale.status() { target = name }
    let connection = AgentTermConnection(host: "127.0.0.1", port: port, token: token, clientName: "agenttermd")
    connection.onMessage = { message in
        switch message {
        case .welcome:
            connection.send(.createPairingCode)
        case .pairingCode(let code, _):
            let info = PairingInfo(host: target ?? "127.0.0.1", port: port, code: code, name: name ?? Host.current().localizedName ?? "Mac")
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
