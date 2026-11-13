#if os(macOS)
import AgentTermProtocol
import Foundation
import SwiftTerm

/// A session's screen, kept on the host by a terminal emulator nobody looks
/// at. Everything the session writes is fed to it, so at any moment it holds
/// what a terminal that had been there from the start would show.
///
/// A client that attaches is sent that, written out again as terminal output
/// (`snapshot()`), rather than the session's raw output of before. The raw
/// output only shows a full screen program right once the program draws
/// again, and what was drawn for another width reads badly further up. The
/// screen written out again is right for the size the session has now.
final class ScreenMirror: TerminalDelegate {
    private var terminal: Terminal!
    private var tracker = OutputTracker()
    /// The screen as last written out, until the session writes more or is
    /// resized. Writing out a long session takes a good part of a second,
    /// on the queue all the host's work goes through, and clients come in
    /// numbers: the Mac app and the phones, each after every reconnect.
    private var written: Data?

    /// - Parameter scrollback: How many lines above the screen are kept.
    init(size: TermSize, scrollback: Int) {
        let options = TerminalOptions(cols: size.cols, rows: size.rows, scrollback: scrollback)
        terminal = Terminal(delegate: self, options: options)
    }

    func feed(_ data: Data) {
        written = nil
        tracker.consume(data)
        terminal.feed(byteArray: [UInt8](data))
    }

    /// The screen as text, with up to `linesAbove` of the lines above it,
    /// without the blank lines at its end: what an agent reads (#10).
    func text(linesAbove: Int) -> String {
        var lines = terminal.contentSnapshot(region: .history(maximumScrollbackRows: max(0, linesAbove))).rows.map {
            $0.text.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    func resize(_ size: TermSize) {
        guard size.cols != terminal.cols || size.rows != terminal.rows else { return }
        written = nil
        terminal.resize(cols: size.cols, rows: size.rows)
    }

    /// The emulator answers what programs ask a terminal. Those answers are
    /// the clients' to give, not this one's.
    func send(source: Terminal, data: ArraySlice<UInt8>) {}

    /// The screen as plain text, one line per row, without what is above it.
    var text: String {
        terminal.contentSnapshot(region: .history(maximumScrollbackRows: 0)).rows.map(\.text).joined(separator: "\n")
    }

    /// Terminal output that, fed to an empty emulator of the session's size,
    /// leaves it as this one is: the lines above the screen, the screen,
    /// where the cursor is and the modes the program set. The session's live
    /// output can follow it directly.
    ///
    /// It holds no question to the terminal, so nothing in it is answered.
    ///
    /// Not carried over: images, links, tab stops, character sets and origin
    /// mode. A cursor that waits past the last column to wrap is put on the
    /// last column.
    ///
    /// - Parameter linesAbove: At most this many of the lines above the
    ///   screen, the nearest ones; nil for all of them. A phone opens a long
    ///   session with a few hundred, and asks for more as it scrolls up.
    func snapshot(linesAbove: Int? = nil) -> Data {
        if linesAbove == nil, let written { return written }
        let data = capture(linesAbove: linesAbove).written()
        if linesAbove == nil { written = data }
        return data
    }

    /// What `snapshot` writes out, taken as it is now: the rows and the
    /// state. Taking it is quick and has to be done where the output is
    /// fed; writing it out is most of the work and can be done anywhere.
    func capture(linesAbove: Int? = nil) -> Capture {
        let region: TerminalContentRegion = linesAbove.map { .history(maximumScrollbackRows: max(0, $0)) } ?? .all
        let normal = terminal.contentSnapshot(region: region, buffer: .normal)
        let alternate =
            normal.inputState.isAlternateBuffer ? terminal.contentSnapshot(region: .history(maximumScrollbackRows: 0), buffer: .alt) : nil
        return Capture(
            normal: normal, alternate: alternate, margins: scrollRegion(), modes: tracker.modes, cursorStyle: tracker.cursorStyle, pen: tracker.pen,
            pending: tracker.pending, cached: linesAbove == nil ? written : nil)
    }

    /// A session's screen and state as they were, to be written out.
    struct Capture: Sendable {
        let normal: TerminalContentSnapshot
        let alternate: TerminalContentSnapshot?
        let margins: String
        let modes: [Int: Bool]
        let cursorStyle: String?
        let pen: [String]
        let pending: Data
        /// What was written out of the same, nothing having changed since.
        let cached: Data?

        func written() -> Data {
            if let cached { return cached }
            let escape = "\u{1b}["
            // An emulator that was used before starts empty too.
            var out = "\(escape)?1049l\(escape)r\(escape)H\(escape)2J\(escape)3J"
            let state = normal.inputState
            out += Self.written(normal)
            out += Self.cursorPosition(in: normal)
            if let alternate {
                // Entering the other screen saves the cursor just placed, as the
                // program's own entering did, for when it leaves.
                out += "\(escape)?1049h\(escape)H"
                out += Self.written(alternate)
                out += margins
                out += Self.cursorPosition(in: alternate)
            } else if !margins.isEmpty {
                // Setting the margins moves the cursor, so they go first.
                out += margins + Self.cursorPosition(in: normal)
            }

            if state.applicationCursor { out += "\(escape)?1h" }
            if state.applicationKeypad { out += "\u{1b}=" }
            if state.bracketedPasteMode { out += "\(escape)?2004h" }
            if state.focusReportingEnabled { out += "\(escape)?1004h" }
            switch state.mouseMode {
            case .off: break
            case .x10: out += "\(escape)?9h"
            case .vt200: out += "\(escape)?1000h"
            case .buttonEventTracking: out += "\(escape)?1002h"
            case .anyEvent: out += "\(escape)?1003h"
            }
            // How the mouse is reported, which the emulator does not say.
            for mode in [1005, 1006, 1015, 1016] where modes[mode] == true {
                out += "\(escape)?\(mode)h"
            }
            if state.keyboardEnhancementFlags.rawValue != 0 {
                // Pushed, as the program did: it pops them when it ends.
                out += "\(escape)>\(state.keyboardEnhancementFlags.rawValue)u"
            }
            if modes[7] == false { out += "\(escape)?7l" }
            if modes[25] == false { out += "\(escape)?25l" }
            if let cursorStyle { out += "\(escape)\(cursorStyle) q" }
            for parameters in pen { out += "\(escape)\(parameters)m" }

            var data = Data(out.utf8)
            // The beginning of what the live output is in the middle of.
            data.append(pending)
            return data
        }

        /// The rows of a buffer as terminal output. Without the colors of this
        /// emulator: a client has its own, and these are nobody's choice.
        private static func written(_ content: TerminalContentSnapshot) -> String {
            TerminalContentSnapshot(
                inputState: content.inputState,
                bufferKind: content.bufferKind,
                dimensions: content.dimensions,
                capturedRange: content.capturedRange,
                liveTopRow: content.liveTopRow,
                rows: content.rows,
                cursorRow: content.cursorRow,
                cursorColumn: content.cursorColumn
            ).ansiRepresentation()
        }

        private static func cursorPosition(in content: TerminalContentSnapshot) -> String {
            let row = min(max(content.cursorRow - content.liveTopRow, 0), max(content.dimensions.rows - 1, 0))
            let column = min(max(content.cursorColumn, 0), max(content.dimensions.cols - 1, 0))
            return "\u{1b}[\(row + 1);\(column + 1)H"
        }
    }

    /// How many lines are kept above the screen of the session's own
    /// buffer, the one a person scrolls back through.
    var linesAbove: Int {
        if terminal.isCurrentBufferAlternate {
            return max(0, terminal.contentSnapshot(region: .all, buffer: .normal).rows.count - terminal.rows)
        }
        return terminal.getTopVisibleRow()
    }

    /// The margins of the screen in front, when the program set any.
    private func scrollRegion() -> String {
        let buffer = terminal.buffer
        guard buffer.scrollTop != 0 || buffer.scrollBottom != terminal.rows - 1 else { return "" }
        return "\u{1b}[\(buffer.scrollTop + 1);\(buffer.scrollBottom + 1)r"
    }
}
#endif
