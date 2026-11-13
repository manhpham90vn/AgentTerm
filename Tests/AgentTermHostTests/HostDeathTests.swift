import AgentTermClient
import AgentTermHost
import AgentTermProtocol
import Darwin
import XCTest

/// A host that dies, and the host started after it. These run the real
/// `agenttermd`, since what is tested is what one process leaves for the
/// next: each host has a state folder, a home and a port of the test's own.
final class HostDeathTests: XCTestCase {
    private final class Client {
        let connection: AgentTermConnection
        var messages: [ServerMessage] = []

        init(port: UInt16, token: String, name: String) {
            connection = AgentTermConnection(host: "127.0.0.1", port: port, token: token, clientName: name)
            connection.onMessage = { [weak self] in self?.messages.append($0) }
            connection.connect()
        }

        var welcomed: Bool { messages.contains { if case .welcome = $0 { return true } else { return false } } }
        var sessions: [SessionInfo] { messages.compactMap { if case .sessions(let list) = $0 { return list } else { return nil } }.last ?? [] }
        /// The last list of failures the host sent, nil when it sent none.
        var failures: [PartFailure]? { messages.compactMap { if case .failures(let list) = $0 { return list } else { return nil } }.last }
        /// Whether the host has sent all it sends on connecting.
        var settled: Bool { messages.contains { if case .displaySettings = $0 { return true } else { return false } } }
    }

    private var root: URL!
    private var state: URL!
    private var home: URL!
    private var port: UInt16 = 0
    private var hosts: [Process] = []
    private var clients: [Client] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-death-\(UUID().uuidString.prefix(8))")
        state = root.appendingPathComponent("state")
        home = root.appendingPathComponent("home")
        for folder in [state!, home!] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        port = try Self.freePort()
    }

    override func tearDown() {
        clients.forEach { $0.connection.close() }
        clients = []
        // Only the hosts this test started.
        for host in hosts where host.isRunning {
            host.terminate()
            host.waitUntilExit()
        }
        hosts = []
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    /// A port nothing listens on now.
    private static func freePort() throws -> UInt16 {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socket, $0, length) == 0 && getsockname(socket, $0, &length) == 0 }
        }
        guard bound else { throw XCTSkip("no free port") }
        return UInt16(bigEndian: address.sin_port)
    }

    private var executable: URL { Bundle(for: HostDeathTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("agenttermd") }

    /// Starts a host on the test's port and state folder, and waits until it answers.
    @discardableResult
    private func startHost() throws -> Process {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: executable.path), "agenttermd is not built next to the tests")
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--port", String(port), "--local-only", "--no-account-usage", "--home", home.path, "--agents", root.appendingPathComponent("agents").path]
        var environment = ProcessInfo.processInfo.environment
        environment["AGENTTERM_STATE_DIR"] = state.path
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        hosts.append(process)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if (try? token()) != nil, Self.answers(port: port) { return process }
            usleep(100_000)
        }
        XCTFail("the host did not start")
        return process
    }

    private func token() throws -> String {
        try String(contentsOf: state.appendingPathComponent("token"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether something accepts a connection on the port.
    private static func answers(port: UInt16) -> Bool {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = port.bigEndian
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }

    private func connect(_ name: String) throws -> Client {
        let client = Client(port: port, token: try token(), name: name)
        clients.append(client)
        waitUntil("\(name) to be welcomed") { client.welcomed && client.settled }
        return client
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertTrue(condition(), "timed out waiting for: \(what)")
    }

    /// Two sessions that run until they are ended.
    private func startTwoSessions() throws {
        let mac = try connect("mac before")
        mac.connection.send(.create(CreateRequest(command: "sleep 600", cwd: root.path, title: "build")))
        mac.connection.send(.create(CreateRequest(command: "sleep 600", cwd: root.path, title: "tests")))
        waitUntil("two sessions") { mac.sessions.count == 2 }
        // What the host notes about its sessions is written as they change.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        mac.connection.close()
    }

    /// HOST-3: the host is killed. The next one tells every client that it
    /// died, when, which sessions ended with it, and that it was started
    /// again; a client that connects later too, until one has seen it.
    func testAHostThatDiedIsReportedToEveryClientUntilSeen() throws {
        let first = try startHost()
        try startTwoSessions()
        let killedAt = Date()
        kill(first.processIdentifier, SIGKILL)
        first.waitUntilExit()

        try startHost()
        let mac = try connect("mac")
        waitUntil("the report of the host that died") { mac.failures?.isEmpty == false }
        let report = try XCTUnwrap(mac.failures?.first)
        XCTAssertEqual(mac.failures?.count, 1)
        XCTAssertEqual(report.part, .host)
        XCTAssertNil(report.name)
        XCTAssertEqual(report.ended.map(\.name), ["build", "tests"])
        XCTAssertEqual(report.ended.map(\.cwd), [root.path, root.path])
        XCTAssertTrue(report.restarted)
        XCTAssertFalse(report.broken)
        // Within the few seconds the host looks in on itself.
        XCTAssertLessThan(abs(report.at.timeIntervalSince(killedAt)), 15)
        XCTAssertEqual(mac.sessions, [], "the sessions ended with it")

        // A client that connects later is told the same.
        let phone = try connect("phone")
        XCTAssertEqual(phone.failures, [report])

        // Also after the host is restarted on purpose, while nobody has seen it.
        hosts.last?.terminate()
        hosts.last?.waitUntilExit()
        try startHost()
        let again = try connect("mac again")
        XCTAssertEqual(again.failures, [report], "a restart that was asked for is not a death, and keeps what was not seen")

        // Seen on one device, it is gone from all, and not sent again.
        let other = try connect("phone again")
        other.connection.send(.dismissFailure(id: report.id))
        waitUntil("the report to be gone") { again.failures == [] && other.failures == [] }
        let later = try connect("later")
        XCTAssertEqual(later.failures ?? [], [])
    }

    /// HOST-4: a host stopped as asked for (SIGTERM: Restart Host, replacing
    /// another copy's host, logging out) is not reported.
    func testAHostThatWasStoppedIsNotReported() throws {
        let first = try startHost()
        try startTwoSessions()
        first.terminate()
        first.waitUntilExit()

        try startHost()
        let mac = try connect("mac")
        XCTAssertEqual(mac.failures ?? [], [])
        XCTAssertEqual(mac.sessions, [])
    }
}
