import AgentTermProtocol
import XCTest

@testable import AgentTermTerminal

/// What the emulator answers to a replay must not reach the program.
@MainActor
final class ReplayTests: XCTestCase {
    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testAReplayThatTakesLongerThanTheTimeoutIsStillAReplay() {
        let controller = TerminalController(session: 1)
        var sent = Data()
        controller.onInput = { sent.append($0) }
        controller.replayQuiet = 1.5
        controller.beginReplay(size: TermSize(cols: 80, rows: 24))
        // The replay comes in pieces over a slow link: longer in all than
        // the timeout, but never quiet for that long.
        for piece in 0..<6 {
            controller.feed(Data("piece \(piece)\r\n".utf8))
            spin(0.4)
        }
        // A question the program asked long ago: where is the cursor.
        controller.feed(Data("\u{1b}[6n".utf8))
        spin(0.1)
        XCTAssertEqual(String(decoding: sent, as: UTF8.self), "", "an answer to the replay was sent on as input")

        controller.endReplay()
        spin(0.2)
        XCTAssertEqual(String(decoding: sent, as: UTF8.self), "", "the answer to the mark was sent on as input")
        // After the replay the program gets its answers again.
        controller.feed(Data("\u{1b}[6n".utf8))
        spin(0.1)
        XCTAssertTrue(String(decoding: sent, as: UTF8.self).hasSuffix("R"), "a live question got no answer")
    }

    func testAReplayThatStopsWithoutItsEndDoesNotSilenceTheTerminalForGood() {
        let controller = TerminalController(session: 1)
        var sent = Data()
        controller.onInput = { sent.append($0) }
        controller.replayQuiet = 0.2
        controller.beginReplay()
        controller.feed(Data("some output\r\n".utf8))
        spin(1)
        controller.feed(Data("\u{1b}[6n".utf8))
        spin(0.1)
        XCTAssertTrue(String(decoding: sent, as: UTF8.self).hasSuffix("R"))
    }
}
