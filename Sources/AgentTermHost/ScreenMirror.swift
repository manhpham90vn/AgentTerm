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
    func snapshot() -> Data {
        if let written { return written }
        let escape = "\u{1b}["
        // An emulator that was used before starts empty too.
        var out = "\(escape)?1049l\(escape)r\(escape)H\(escape)2J\(escape)3J"

        let normal = terminal.contentSnapshot(region: .all, buffer: .normal)
        let state = normal.inputState
        out += written(normal)
        out += cursorPosition(in: normal)
        if state.isAlternateBuffer {
            // Entering the other screen saves the cursor just placed, as the
            // program's own entering did, for when it leaves.
            let alternate = terminal.contentSnapshot(region: .history(maximumScrollbackRows: 0), buffer: .alt)
            out += "\(escape)?1049h\(escape)H"
            out += written(alternate)
            let margins = scrollRegion()
            out += margins
            out += cursorPosition(in: alternate)
        } else {
            // Setting the margins moves the cursor, so they go first.
            let margins = scrollRegion()
            if !margins.isEmpty { out += margins + cursorPosition(in: normal) }
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
        for mode in [1005, 1006, 1015, 1016] where tracker.modes[mode] == true {
            out += "\(escape)?\(mode)h"
        }
        if state.keyboardEnhancementFlags.rawValue != 0 {
            // Pushed, as the program did: it pops them when it ends.
            out += "\(escape)>\(state.keyboardEnhancementFlags.rawValue)u"
        }
        if tracker.modes[7] == false { out += "\(escape)?7l" }
        if tracker.modes[25] == false { out += "\(escape)?25l" }
        if let style = tracker.cursorStyle { out += "\(escape)\(style) q" }
        for parameters in tracker.pen { out += "\(escape)\(parameters)m" }

        var data = Data(out.utf8)
        // The beginning of what the live output is in the middle of.
        data.append(tracker.pending)
        written = data
        return data
    }

    /// The rows of a buffer as terminal output. Without the colors of this
    /// emulator: a client has its own, and these are nobody's choice.
    private func written(_ content: TerminalContentSnapshot) -> String {
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

    private func cursorPosition(in content: TerminalContentSnapshot) -> String {
        let row = min(max(content.cursorRow - content.liveTopRow, 0), max(content.dimensions.rows - 1, 0))
        let column = min(max(content.cursorColumn, 0), max(content.dimensions.cols - 1, 0))
        return "\u{1b}[\(row + 1);\(column + 1)H"
    }

    /// The margins of the screen in front, when the program set any.
    private func scrollRegion() -> String {
        let buffer = terminal.buffer
        guard buffer.scrollTop != 0 || buffer.scrollBottom != terminal.rows - 1 else { return "" }
        return "\u{1b}[\(buffer.scrollTop + 1);\(buffer.scrollBottom + 1)r"
    }
}
#endif
