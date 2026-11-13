import AgentTermProtocol
import SwiftTerm
import XCTest

@testable import AgentTermHost

/// What a client is sent when it attaches: the session's screen written out
/// again. Each test feeds a session's output to the host's mirror, gives
/// what the mirror writes out to an empty emulator, as a client would, and
/// compares the two.
final class ScreenMirrorTests: XCTestCase {
    /// An emulator standing in for a client's.
    private final class Client: TerminalDelegate {
        private(set) var terminal: Terminal!
        /// What the emulator wanted sent to the program.
        var sent: [UInt8] = []

        init(size: TermSize, scrollback: Int = 1000) {
            terminal = Terminal(delegate: self, options: TerminalOptions(cols: size.cols, rows: size.rows, scrollback: scrollback))
        }

        func send(source: Terminal, data: ArraySlice<UInt8>) { sent.append(contentsOf: data) }
        func feed(_ data: Data) { terminal.feed(byteArray: [UInt8](data)) }
        func feed(_ text: String) { feed(Data(text.utf8)) }
    }

    private let size = TermSize(cols: 40, rows: 10)
    private let escape = "\u{1b}"

    /// A mirror and a session's own terminal, both fed the same output.
    private func session(_ output: [String], size: TermSize? = nil) -> (mirror: ScreenMirror, original: Client) {
        let size = size ?? self.size
        let mirror = ScreenMirror(size: size, scrollback: 1000)
        let original = Client(size: size)
        for piece in output {
            mirror.feed(Data(piece.utf8))
            original.feed(piece)
        }
        return (mirror, original)
    }

    private func attach(to mirror: ScreenMirror, size: TermSize? = nil) -> Client {
        let client = Client(size: size ?? self.size)
        client.feed(mirror.snapshot())
        return client
    }

    private struct Cell: Equatable {
        let text: String
        /// Nil for a cell with nothing in it, where only the background shows.
        let attribute: Attribute?
        let background: Attribute.Color
    }

    /// The rows of a buffer, with only what shows: a cell nothing was
    /// written to and a cell holding a space look the same.
    private func rows(of client: Client, buffer: Terminal.BufferKind = .active) -> [[Cell]] {
        client.terminal.contentSnapshot(region: .all, buffer: buffer).rows.map { row in
            var cells = row.cells.map { cell -> Cell in
                let blank = cell.isBlank || cell.text == " "
                return Cell(text: blank ? " " : cell.text, attribute: blank ? nil : cell.attribute, background: cell.attribute.bg)
            }
            while let last = cells.last, last.text == " ", last.background == .defaultColor { cells.removeLast() }
            return cells
        }
    }

    private func text(of client: Client, buffer: Terminal.BufferKind = .active) -> [String] {
        client.terminal.contentSnapshot(region: .all, buffer: buffer).rows.map(\.text)
    }

    private func cursor(of client: Client) -> [Int] {
        let content = client.terminal.contentSnapshot(region: .history(maximumScrollbackRows: 0))
        return [content.cursorRow - content.liveTopRow, content.cursorColumn]
    }

    private func assertSame(_ client: Client, _ original: Client, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(text(of: client), text(of: original), file: file, line: line)
        XCTAssertEqual(rows(of: client), rows(of: original), "the colors or styles differ", file: file, line: line)
        XCTAssertEqual(cursor(of: client), cursor(of: original), "the cursor is somewhere else", file: file, line: line)
        XCTAssertEqual(client.terminal.inputStateSnapshot(), original.terminal.inputStateSnapshot(), file: file, line: line)
    }

    func testAShellsLinesAndTheLinesAboveTheScreen() {
        var output: [String] = []
        for number in 1...60 {
            output.append("\(escape)[1;3\(number % 8)mline \(number)\(escape)[0m plain \(escape)[48;5;\(number)m  \(escape)[m\r\n")
        }
        output.append("$ typed so far")
        let (mirror, original) = session(output)
        let client = attach(to: mirror)
        assertSame(client, original)
        XCTAssertEqual(text(of: client).first, "line 1 plain   ")
        XCTAssertEqual(mirror.text.split(separator: "\n").last, "$ typed so far")

        // What the session writes next lands where it does in its own terminal.
        let next = " and more\r\n\(escape)[32mdone\(escape)[0m\r\n$ "
        original.feed(next)
        client.feed(next)
        assertSame(client, original)
    }

    /// HIST-6: a phone is sent the screen and only so many lines above it,
    /// told how many the host keeps, and asks for more as it scrolls up.
    func testOnlySoManyLinesAboveTheScreenAreWrittenOut() {
        let output = (1...300).map { "line \($0)\r\n" } + ["$ "]
        let (mirror, original) = session(output)
        XCTAssertEqual(mirror.linesAbove, 291, "300 lines and the prompt, ten rows on the screen")

        let client = Client(size: size)
        client.feed(mirror.snapshot(linesAbove: 50))
        let lines = text(of: client)
        XCTAssertEqual(lines.count, 50 + size.rows)
        XCTAssertEqual(lines.first, "line 242", "the fifty lines just above the screen")
        // The screen, the cursor and the modes are those of the session.
        XCTAssertEqual(Array(lines.suffix(size.rows)), Array(text(of: original).suffix(size.rows)))
        XCTAssertEqual(cursor(of: client), cursor(of: original))

        // More of them: the same lines, and those above them.
        let more = Client(size: size)
        more.feed(mirror.snapshot(linesAbove: 150))
        XCTAssertEqual(text(of: more).count, 150 + size.rows)
        XCTAssertEqual(Array(text(of: more).suffix(lines.count)), lines)
        // More than it keeps is all it keeps.
        let all = Client(size: size)
        all.feed(mirror.snapshot(linesAbove: 10_000))
        XCTAssertEqual(text(of: all), text(of: original))
    }

    func testAFullScreenProgramShowsWithoutDrawingAgain() {
        let (mirror, original) = session([
            "before the program\r\n$ agent\r\n",
            "\(escape)[?1049h\(escape)[?25l\(escape)[?1002h\(escape)[?1006h\(escape)[?2004h\(escape)[?1h\(escape)=",
            "\(escape)[2;3H\(escape)[7m title \(escape)[0m\(escape)[4;1H> ask anything",
            "\(escape)[10;1H\(escape)[2mstatus line\(escape)[0m\(escape)[4;16H",
        ])
        let client = attach(to: mirror)
        assertSame(client, original)
        XCTAssertTrue(client.terminal.isCurrentBufferAlternate)
        XCTAssertEqual(mirror.text.split(separator: "\n", omittingEmptySubsequences: false)[3], "> ask anything")
        let written = String(decoding: mirror.snapshot(), as: UTF8.self)
        XCTAssertTrue(written.contains("\(escape)[?1006h"), "how the mouse is reported was not carried over")
        XCTAssertTrue(written.contains("\(escape)[?25l"), "the cursor shows again")

        // The program ends: both are back at the shell's screen, as it was.
        let leaving = "\(escape)[?1006l\(escape)[?1002l\(escape)[?2004l\(escape)[?1l\(escape)>\(escape)[?25h\(escape)[?1049l$ "
        original.feed(leaving)
        client.feed(leaving)
        assertSame(client, original)
        XCTAssertFalse(client.terminal.isCurrentBufferAlternate)
        XCTAssertEqual(text(of: client).prefix(3), ["before the program", "$ agent", "$ "])
    }

    func testALineLongerThanTheScreenStaysOneLine() {
        let long = String(repeating: "abcdefghij", count: 10)
        let (mirror, original) = session(["first\r\n", long, "\r\nlast"])
        let client = attach(to: mirror)
        assertSame(client, original)
        let wrapped = client.terminal.contentSnapshot(region: .all).rows.map(\.isWrapped)
        XCTAssertEqual(wrapped, original.terminal.contentSnapshot(region: .all).rows.map(\.isWrapped))
        XCTAssertEqual(wrapped.filter { $0 }.count, 2, "a line of 100 characters on 40 columns continues twice")
    }

    func testWhatWasDrawnForAnotherWidthIsWrittenForThisOne() {
        let wide = TermSize(cols: 80, rows: 10)
        let (mirror, original) = session(["a line of seventy characters ".padding(toLength: 70, withPad: "x", startingAt: 0), "\r\nshort\r\n$ "], size: wide)
        // A phone takes over the session.
        mirror.resize(size)
        original.terminal.resize(cols: size.cols, rows: size.rows)
        let client = attach(to: mirror)
        XCTAssertEqual(text(of: client), text(of: original))
        XCTAssertEqual(cursor(of: client), cursor(of: original))
        XCTAssertEqual(text(of: client)[0].count, 40, "the long line was not folded to the new width")
    }

    func testOutputCutInTheMiddleOfASequenceGoesOnWhereItWas() {
        // Each of these ends in the middle of something: a color, a
        // character of three bytes, a title.
        let cuts: [(before: [UInt8], after: [UInt8])] = [
            (Array("abc\u{1b}[3".utf8), Array("1mred".utf8)),
            (Array("abc\u{1b}".utf8), Array("[31mred".utf8)),
            (Array("abc".utf8) + [0xE2, 0x82], [0xAC] + Array("!".utf8)),
            (Array("abc\u{1b}]2;a tit".utf8), Array("le\u{07}after".utf8)),
            (Array("abc\u{1b}]2;a title\u{1b}".utf8), Array("\\after".utf8)),
        ]
        for cut in cuts {
            let mirror = ScreenMirror(size: size, scrollback: 100)
            let original = Client(size: size)
            mirror.feed(Data(cut.before))
            original.feed(Data(cut.before))
            let client = attach(to: mirror)
            mirror.feed(Data(cut.after))
            original.feed(Data(cut.after))
            client.feed(Data(cut.after))
            assertSame(client, original)
            XCTAssertEqual(mirror.text.split(separator: "\n").first, Substring(text(of: original)[0]))
        }
    }

    func testTextGoesOnInTheColorsItWasBeingWrittenIn() {
        let (mirror, original) = session(["\(escape)[1m\(escape)[38;5;208mwarning: "])
        let client = attach(to: mirror)
        original.feed("the rest\(escape)[0m plain")
        client.feed("the rest\(escape)[0m plain")
        assertSame(client, original)
    }

    func testMarginsAndTheCursorInsideThem() {
        let (mirror, original) = session(["top\r\n\(escape)[3;8r\(escape)[5;4Hin the region"])
        let client = attach(to: mirror)
        assertSame(client, original)
        // Lines scroll inside the margins only, on both.
        let more = String(repeating: "\r\nscrolled", count: 8)
        original.feed(more)
        client.feed(more)
        assertSame(client, original)
    }

    func testNothingInItIsAQuestionToTheTerminal() {
        // The program asked where the cursor is and what terminal this is.
        let (mirror, _) = session(["hello\(escape)[6n\(escape)[c\(escape)[?1049h\(escape)[>c\(escape)]11;?\u{07}world"])
        let client = attach(to: mirror)
        XCTAssertEqual(client.sent, [], "a client would answer the program a second time")
        XCTAssertEqual(mirror.text.split(separator: "\n").first, "     world")
    }

    func testAnEmulatorUsedBeforeIsLeftAsTheSessionIs() {
        let (mirror, original) = session(["only this\r\n$ "])
        let client = Client(size: size)
        client.feed("something old\r\nand more\(escape)[?1049hfull screen\(escape)[2;5r")
        client.feed(mirror.snapshot())
        assertSame(client, original)
    }

    func testTheClientsOwnColorsAreLeftAlone() {
        let (mirror, _) = session(["\(escape)[31mred\(escape)[0m"])
        let written = String(decoding: mirror.snapshot(), as: UTF8.self)
        XCTAssertFalse(written.contains("\(escape)]"), "the snapshot sets colors or a title: \(written.debugDescription)")
    }

    /// SES-19.
    func testAStringCutShortByAnotherSequenceIsOver() {
        // A program killed in the middle of a title: the emulator takes the
        // escape that follows as the start of something new.
        let (mirror, original) = session(["abc\u{1b}]2;a tit", "\u{1b}[31mred\u{1b}[0m and more"])
        assertSame(attach(to: mirror), original)
        // And cut again right after the escape that ended it.
        let cut = ScreenMirror(size: size, scrollback: 100)
        let second = Client(size: size)
        for piece in ["abc\u{1b}]2;a tit\u{1b}"] {
            cut.feed(Data(piece.utf8))
            second.feed(piece)
        }
        let client = attach(to: cut)
        for target in [second, client] { target.feed("[31mred") }
        cut.feed(Data("[31mred".utf8))
        assertSame(client, second)
        assertSame(attach(to: cut), second)
    }

    /// SES-20.
    func testAnImageTooLongToKeepIsNotDrawnAsText() {
        // More than is kept of one sequence, with a client attaching in
        // the middle of it: it misses the image, and draws none of it.
        let mirror = ScreenMirror(size: size, scrollback: 100)
        mirror.feed(Data("before\r\n\u{1b}]1337;File=inline=1:".utf8))
        let piece = Data(repeating: UInt8(ascii: "A"), count: 300_000)
        for _ in 0..<5 { mirror.feed(piece) }
        let snapshot = mirror.snapshot()
        XCTAssertLessThan(snapshot.count, 10_000)
        let client = Client(size: size)
        client.feed(snapshot)
        for target in [client] { target.feed(piece) }
        mirror.feed(piece)
        client.feed("\u{07}after")
        mirror.feed(Data("\u{07}after".utf8))
        XCTAssertEqual(text(of: client).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }, ["before", "after"])
    }

    /// Two hundred colored lines of a session's output.
    private var manyLines: Data {
        var piece = ""
        for number in 1...200 { piece += "\(escape)[3\(number % 8)m\(number)\(escape)[0m " + String(repeating: "word ", count: 18) + "\r\n" }
        return Data(piece.utf8)
    }

    /// A mirror fed `pieces` times `manyLines`, and how long its screen
    /// takes to be written out: the shortest of three tries, since a
    /// machine that is busy for a moment makes one try longer, never shorter.
    private func writingTime(pieces: Int) -> (mirror: ScreenMirror, written: Data, seconds: TimeInterval) {
        let mirror = ScreenMirror(size: TermSize(cols: 120, rows: 40), scrollback: 10_000)
        let data = manyLines
        for _ in 0..<pieces { mirror.feed(data) }
        var shortest = TimeInterval.infinity
        var written = Data()
        for _ in 0..<3 {
            // Nothing new, but what was written out before is not kept.
            mirror.feed(Data())
            let started = Date()
            written = mirror.snapshot()
            shortest = min(shortest, Date().timeIntervalSince(started))
        }
        return (mirror, written, shortest)
    }

    /// SES-21. Each half compares the work with itself rather than with a
    /// number of seconds, which held on one machine and not on a slower
    /// one (issue #32).
    func testManyLinesAreWrittenOutQuickly() {
        let data = manyLines
        // Writing out takes as long again for as many lines again: a long
        // session costs in proportion, not more. 12,000 lines fed keep
        // 10,040 (the screen and the 10,000 above it); 13 pieces keep 2,640,
        // a quarter of that. In proportion, the long one takes about four
        // times as long; were each line to cost more the more there are,
        // fifteen times or more.
        let short = writingTime(pieces: 13)
        let (mirror, written, writing) = writingTime(pieces: 60)
        print("wrote 2,640 lines in \(short.seconds) s, 10,040 lines (\(written.count) bytes) in \(writing) s")
        XCTAssertLessThan(writing, short.seconds * 8, "writing out does not grow in proportion to the lines")
        // Several clients attach to a session that says nothing meanwhile,
        // the Mac app and a phone coming back for one: written out once.
        let again = Date()
        for _ in 0..<10 { XCTAssertEqual(mirror.snapshot(), written) }
        let rewriting = Date().timeIntervalSince(again)
        print("wrote it 10 more times in \(rewriting) s")
        XCTAssertLessThan(rewriting, max(writing, 0.05))
        // Not what was written before, once there is more.
        mirror.feed(Data("one more line\r\n".utf8))
        XCTAssertNotEqual(mirror.snapshot(), written)
        mirror.feed(data)
        let client = Client(size: TermSize(cols: 120, rows: 40), scrollback: 10_000)
        client.feed(mirror.snapshot())
        XCTAssertEqual(text(of: client).count, 10_040)
    }
}

final class OutputTrackerTests: XCTestCase {
    private func tracker(_ pieces: [String]) -> OutputTracker {
        var tracker = OutputTracker()
        for piece in pieces { tracker.consume(Data(piece.utf8)) }
        return tracker
    }

    func testNothingIsPendingBetweenSequences() {
        XCTAssertEqual(tracker(["plain \u{1b}[31mred\u{1b}[0m \u{1b}]0;title\u{07} é \u{1b}(B"]).pending, Data())
    }

    func testWhatHasBegunIsPendingFromItsStart() {
        XCTAssertEqual(tracker(["text\u{1b}[38;5"]).pending, Data("\u{1b}[38;5".utf8))
        XCTAssertEqual(tracker(["text\u{1b}"]).pending, Data("\u{1b}".utf8))
        // Over several pieces, with nothing else in them.
        XCTAssertEqual(tracker(["a\u{1b}]52;c;", "QUJD", "REVG"]).pending, Data("\u{1b}]52;c;QUJDREVG".utf8))
        // A sequence that another one cuts short.
        XCTAssertEqual(tracker(["\u{1b}[12\u{1b}[3"]).pending, Data("\u{1b}[3".utf8))
        // Ended in a later piece.
        XCTAssertEqual(tracker(["\u{1b}[3", "1mx"]).pending, Data())
        var cut = OutputTracker()
        cut.consume(Data([0x61, 0xF0, 0x9F]))
        XCTAssertEqual(cut.pending, Data([0xF0, 0x9F]))
        cut.consume(Data([0x98]))
        XCTAssertEqual(cut.pending, Data([0xF0, 0x9F, 0x98]))
        cut.consume(Data([0x80]))
        XCTAssertEqual(cut.pending, Data())
    }

    func testAStringEndsWhereAnotherSequenceBegins() {
        let cut = tracker(["\u{1b}]0;tit", "\u{1b}[31mred\u{1b}[?25l text"])
        XCTAssertEqual(cut.pending, Data())
        XCTAssertEqual(cut.pen, ["31"])
        XCTAssertEqual(cut.modes[25], false)
        // Binary output with the start of a string in it and no end.
        XCTAssertEqual(tracker(["\u{1b}Pjunk\u{1b}[1mbold"]).pen, ["1"])
        // Only the escape is pending while it may still be the string's end.
        XCTAssertEqual(tracker(["\u{1b}]0;title\u{1b}"]).pending, Data("\u{1b}".utf8))
    }

    func testAStringLongerThanIsKeptIsNotKeptInPart() {
        var long = OutputTracker()
        long.consume(Data("\u{1b}Pq".utf8))
        let piece = Data(repeating: UInt8(ascii: "?"), count: 300_000)
        for _ in 0..<5 { long.consume(piece) }
        // Not the middle of it: a few bytes that have a client's emulator
        // read the rest as a string too.
        XCTAssertLessThan(long.pending.count, 8)
        long.consume(Data("\u{1b}\\text".utf8))
        XCTAssertEqual(long.pending, Data())
    }

    func testModesAreRememberedAsLastSet() {
        let tracker = tracker(["\u{1b}[?1002;1006h\u{1b}[?25l", "\u{1b}[?1002l\u{1b}[?7l\u{1b}[4h"])
        XCTAssertEqual(tracker.modes, [1002: false, 1006: true, 25: false, 7: false])
    }

    func testThePenIsWhatWasSelectedSinceTheLastReset() {
        XCTAssertEqual(tracker(["\u{1b}[1m\u{1b}[31m\u{1b}[0m\u{1b}[4m\u{1b}[38;2;1;2;3m"]).pen, ["4", "38;2;1;2;3"])
        XCTAssertEqual(tracker(["\u{1b}[1m\u{1b}[0;32m"]).pen, ["0;32"])
        XCTAssertEqual(tracker(["\u{1b}[1m\u{1b}[m"]).pen, [])
        // Not a color: a key reporting setting that ends in the same letter.
        XCTAssertEqual(tracker(["\u{1b}[>4;2m"]).pen, [])
    }

    func testAResetForgetsAll() {
        let tracker = tracker(["\u{1b}[?1006h\u{1b}[1m\u{1b}[5 q", "\u{1b}c"])
        XCTAssertEqual(tracker.modes, [:])
        XCTAssertEqual(tracker.pen, [])
        XCTAssertNil(tracker.cursorStyle)
        XCTAssertEqual(self.tracker(["\u{1b}[5 q"]).cursorStyle, "5")
    }
}
