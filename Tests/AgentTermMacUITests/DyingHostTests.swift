import AgentTermProtocol
import XCTest

/// The host is killed under the app, as a crash or macOS would do it.
final class DyingHostTests: MacUITestCase {
    /// How many reports of a host that died are on screen.
    private var banners: Int { app.all(.containing("host stopped unexpectedly")).count }

    /// HOST-5: the app starts its host again and says what ended with it.
    func testAHostThatWasKilledIsStartedAgainAndTheBannerSaysWhatEnded() throws {
        let phone = try device()
        phone.send(.create(CreateRequest(command: "sleep 600", cwd: project.path, title: "build")))
        app.wait(for: .containing("build"), timeout: 15)

        killHost(on: port)
        // Started again by the app, which says so, with what ended.
        app.wait(for: .containing("The AgentTerm host stopped unexpectedly"), timeout: 20)
        app.wait(for: .containing("and was started again"))
        app.wait(for: .containing("Its session ended: build"))
        wait("a host on the port again") { !self.listeners(on: self.port).isEmpty }
        // The app works on the new host.
        app.wait(for: .text("project, folder"), timeout: 15)

        shot("banner")
        // Seen here, it is seen everywhere.
        app.press(.button("Dismiss"))
        app.waitGone(.containing("host stopped unexpectedly"))
        let later = try device("later")
        wait("the report to be gone from the host") { later.failures == [] }
    }

    /// HOST-6: three deaths in sixty seconds, and the app stops starting it.
    func testAHostThatKeepsDyingIsReportedBrokenWithAWayToTryAgain() throws {
        app.wait(for: .text("project, folder"), timeout: 15)
        killHost(on: port)
        wait("the first report", timeout: 20) { self.banners == 1 }
        killHost(on: port)
        // The report of the first is not seen yet, so there are two.
        wait("the second report", timeout: 20) { self.banners == 2 }
        killHost(on: port)

        app.wait(for: .containing("The AgentTerm host keeps stopping"), timeout: 20)
        app.wait(for: .containing("3 times within a minute"))
        // Why the last one stopped: the app started it, and saw it killed.
        app.wait(for: .containing("killed"))
        shot("broken")
        // Not started again by itself.
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        XCTAssertEqual(listeners(on: port), [], "a host that keeps dying is not started again by itself")

        app.press(.button("Try Again"))
        wait("a host on the port again", timeout: 20) { !self.listeners(on: self.port).isEmpty }
        app.wait(for: .text("project, folder"), timeout: 15)
        // The new host tells of the three that died.
        wait("the three reports", timeout: 20) { self.banners == 3 }
    }
}

/// The app's port held by something that is not a host.
final class HostThatCannotStartTests: MacUITestCase {
    private var blocker: PortBlocker?
    override var appPort: UInt16 { blocker?.port ?? port }

    override func beforeTheAppStarts() throws {
        // The host the app starts cannot listen there, and nothing there
        // answers the app.
        blocker = try PortBlocker()
    }

    override func tearDown() {
        super.tearDown()
        blocker?.stop()
    }

    /// HOST-7: a host that cannot start says why, with a way to try again.
    func testAHostThatCannotStartSaysWhy() throws {
        app.wait(for: .containing("could not be started"), timeout: 30)
        app.wait(for: .containing("could not listen"))
        XCTAssertTrue(app.exists(.button("Try Again")))
    }
}

/// Holds a local port and closes every connection to it at once.
final class PortBlocker {
    private let socket: Int32
    let port: UInt16
    private var running = true

    init() throws {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        self.socket = socket
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socket, $0, length) == 0 && getsockname(socket, $0, &length) == 0 }
        }
        guard bound, listen(socket, 16) == 0 else { throw XCTSkip("no port to block") }
        port = UInt16(bigEndian: address.sin_port)
        Thread.detachNewThread { [weak self] in
            while self?.running ?? false {
                let connection = accept(socket, nil, nil)
                if connection < 0 { return }
                close(connection)
            }
        }
    }

    func stop() {
        running = false
        shutdown(socket, SHUT_RDWR)
        close(socket)
    }
}
