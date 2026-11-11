@testable import AgenttyHost
import AgenttyProtocol
import XCTest

final class PTYProcessTests: XCTestCase {
    private let queue = DispatchQueue(label: "test.pty")

    /// Runs `/bin/sh -c script` in a PTY and collects output until it exits.
    private func run(
        _ script: String,
        size: TermSize = .default,
        during: ((PTYProcess, @escaping () -> String) -> Void)? = nil
    ) throws -> (output: String, status: Int32) {
        let exited = expectation(description: "exit")
        var output = Data()
        var status: Int32 = -1
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "en_US.UTF-8"
        let process = try PTYProcess(
            executable: "/bin/sh", arguments: ["sh", "-c", script],
            environment: environment, cwd: "/tmp", size: size, queue: queue
        )
        queue.sync {
            process.onOutput = { output.append($0) }
            process.onExit = { status = $0; exited.fulfill() }
        }
        during?(process) { self.queue.sync { String(decoding: output, as: UTF8.self) } }
        wait(for: [exited], timeout: 10)
        return (queue.sync { String(decoding: output, as: UTF8.self) }, status)
    }

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { usleep(20_000) }
    }

    func testOutputAndExitStatus() throws {
        let result = try run("echo hello-$((40+2)); exit 7")
        XCTAssertTrue(result.output.contains("hello-42"), result.output)
        XCTAssertEqual(result.status, 7)
    }

    func testChildHasAControllingTerminalOfTheRequestedSize() throws {
        let result = try run("tty; stty size < /dev/tty", size: TermSize(cols: 48, rows: 30))
        XCTAssertTrue(result.output.contains("/dev/ttys"), result.output)
        XCTAssertTrue(result.output.contains("30 48"), result.output)
        XCTAssertEqual(result.status, 0)
    }

    func testWorkingDirectory() throws {
        let result = try run("pwd -P")
        XCTAssertTrue(result.output.contains("/private/tmp"), result.output)
    }

    func testResizeSendsSIGWINCH() throws {
        let script = "trap 'stty size; exit 0' WINCH; echo ready; while :; do sleep 0.05; done"
        let result = try run(script) { process, output in
            self.waitUntil { output().contains("ready") }
            process.resize(TermSize(cols: 50, rows: 20))
            XCTAssertEqual(process.size, TermSize(cols: 50, rows: 20))
        }
        XCTAssertTrue(result.output.contains("20 50"), result.output)
    }

    func testControlCInterruptsTheForegroundProgram() throws {
        let result = try run("echo ready; sleep 30") { process, output in
            self.waitUntil { output().contains("ready") }
            process.write(Data([0x03]))
        }
        XCTAssertEqual(result.status, 128 + SIGINT)
    }

    func testVietnameseInputRoundTrips() throws {
        let text = "Tiếng Việt: ờ ữ ẩ đ ỵ"
        let result = try run("IFS= read -r line; printf 'got[%s]\\n' \"$line\"") { process, _ in
            process.write(Data((text + "\n").utf8))
        }
        XCTAssertTrue(result.output.contains("got[\(text)]"), result.output)
    }

    func testLargeInputIsNotTruncated() throws {
        let line = String(repeating: "x", count: 1000) + "\n"
        let result = try run("stty -echo; echo ready; wc -c") { process, output in
            self.waitUntil { output().contains("ready") }
            process.write(Data(String(repeating: line, count: 300).utf8))
            process.write(Data([0x04]))
        }
        XCTAssertTrue(result.output.contains("300300"), String(result.output.suffix(200)))
    }

    func testHangUpEndsTheProgram() throws {
        let result = try run("echo ready; sleep 30") { process, output in
            self.waitUntil { output().contains("ready") }
            process.hangUp()
        }
        XCTAssertEqual(result.status, 128 + SIGHUP)
    }

    func testMissingExecutableThrows() {
        XCTAssertThrowsError(try PTYProcess(
            executable: "/nonexistent/program", arguments: ["x"], environment: [:],
            cwd: "/tmp", size: .default, queue: queue
        ))
    }
}
