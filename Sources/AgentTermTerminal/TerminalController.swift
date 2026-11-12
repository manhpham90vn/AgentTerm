import AgentTermProtocol
import SwiftTerm
import SwiftUI

/// One terminal emulator view bound to one host session.
@MainActor
public final class TerminalController: NSObject, TerminalViewDelegate {
    public let session: SessionID
    public let view: TerminalView

    /// Called with bytes the user typed.
    public var onInput: ((Data) -> Void)?
    /// Called when the grid that fits this view changes. The host follows
    /// only if this client is the one driving the session.
    public var onResize: ((TermSize) -> Void)?
    /// Called when the user is using the session here, to become its driver.
    public var onClaim: ((TermSize) -> Void)?

    /// The grid that fits this view, regardless of who drives the PTY.
    public private(set) var naturalSize: TermSize = .default
    /// Set while another device's size is in effect.
    public private(set) var foreignSize: TermSize?

    /// How far back a terminal scrolls, in lines.
    public static let scrollbackLines = 20_000

    private var applyingRemoteSize = false
    private var hasLaidOut = false
    /// The emulator's current grid. SwiftTerm does not expose it.
    private var grid: TermSize?
    private var pendingReport: DispatchWorkItem?
    private var claimWhenLaidOut = false

    public init(session: SessionID, fontSize: CGFloat = 13) {
        self.session = session
        view = TerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
        super.init()
        view.font = TerminalStyle.font(size: fontSize)
        view.nativeBackgroundColor = TerminalStyle.background
        view.nativeForegroundColor = TerminalStyle.foreground
        view.terminalDelegate = self
        // Lines kept to scroll back through. The host replays megabytes of
        // a session's earlier output; without room for them here most of
        // that would be thrown away as it arrives.
        view.changeScrollback(Self.scrollbackLines)
        // Full-width characters at the size of their two cells: see `WideGlyphs`.
        view.glyphFallbackProvider = WideGlyphs.shared
        #if os(iOS)
        // The emulator brings a key bar of its own above the keyboard, which
        // appears when the terminal is tapped. The app has its own key bar
        // under the terminal, so that one would be a second, different row
        // of keys that comes and goes.
        view.inputAccessoryView = nil
        #endif
    }

    /// The exact size in points of the grid the emulator currently draws,
    /// which is smaller than the view while another device's size is shown.
    public var gridPixelSize: CGSize {
        view.getOptimalFrameSize().size
    }

    /// Called by the container with the room it has. While another device
    /// drives, the terminal view is sized to that device's grid, so the grid
    /// that would fit here has to be worked out from the cell size instead.
    /// It is what this client asks for when the user comes back to it.
    public func containerResized(to size: CGSize) {
        guard foreignSize != nil, let grid, grid.cols > 0, grid.rows > 0 else { return }
        let pixels = gridPixelSize
        let cell = CGSize(width: pixels.width / CGFloat(grid.cols), height: pixels.height / CGFloat(grid.rows))
        guard cell.width > 0, cell.height > 0 else { return }
        let fitted = TermSize(cols: max(2, Int(size.width / cell.width)), rows: max(2, Int(size.height / cell.height)))
        guard fitted != naturalSize else { return }
        naturalSize = fitted
        hasLaidOut = true
        reportNaturalSizeSoon()
    }

    public func feed(_ data: Data) {
        // A replay is megabytes in many pieces and may take a while over a
        // slow link. It is over when it says so, or when nothing more of it
        // comes: not some seconds after it began.
        if isReplaying, !replayIsFed { armReplayTimeout(seconds: replayQuiet) }
        view.feed(byteArray: ArraySlice([UInt8](data)))
    }

    /// True while the emulator may still be answering what the host
    /// replayed: the session's output from before this client attached.
    private var isReplaying = false
    /// True once all of the replay was fed and the emulator was asked to
    /// mark its end. What is fed after that is the session's live output.
    private var replayIsFed = false
    private var replayTimeout: DispatchWorkItem?
    /// How long a replay may say nothing before it is taken to be over.
    var replayQuiet: TimeInterval = 5

    /// A mode nothing uses. The emulator is asked about it after a replay,
    /// and its answer marks the end of the answers that belong to the replay.
    private static let replayMarkMode = 27717

    /// The session's earlier output is about to arrive. It holds the
    /// questions the program once asked its terminal (which terminal are
    /// you, where is the cursor), and the emulator answers them again. Sent
    /// on, those answers would land in the program's input as stray text.
    ///
    /// `size` is the session's grid. The emulator takes it before the first
    /// byte: what is replayed was drawn for that grid, and fed to an
    /// emulator of another width its lines wrap in the wrong places. A
    /// program that redraws in place, an agent for one, then shows a broken
    /// screen, and nothing makes it draw again while its size stays as it is.
    public func beginReplay(size: TermSize? = nil) {
        if let size { setGrid(size) }
        isReplaying = true
        replayIsFed = false
        armReplayTimeout(seconds: replayQuiet)
    }

    /// The replay has been fed. The emulator works through what it is fed
    /// in order and answers later, on its own time, so "the replay is over"
    /// cannot be read off the clock. Instead it is asked one more question;
    /// every answer that comes before the answer to that one is the replay's.
    public func endReplay() {
        guard isReplaying else { return }
        replayIsFed = true
        view.feed(text: "\u{1b}[?\(Self.replayMarkMode)$p")
        armReplayTimeout(seconds: 3)
    }

    /// An emulator that never answers the mark must not leave the program
    /// without answers for good.
    private func armReplayTimeout(seconds: TimeInterval) {
        replayTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in self?.isReplaying = false }
        replayTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: timeout)
    }

    /// Whether bytes the emulator wants sent belong to a replay. The answer
    /// to the mark ends the replay and is itself not sent.
    private func isReplayAnswer(_ bytes: Data) -> Bool {
        guard isReplaying else { return false }
        if String(decoding: bytes, as: UTF8.self).contains("?\(Self.replayMarkMode);") {
            replayTimeout?.cancel()
            replayTimeout = nil
            isReplaying = false
        }
        return true
    }

    /// Sends bytes as if they were typed in the terminal.
    public func type(_ bytes: [UInt8]) {
        onInput?(Data(bytes))
    }

    public func setFontSize(_ size: CGFloat) {
        view.font = TerminalStyle.font(size: size)
        // The grid's size in points changed with the cells, so a container
        // that sizes the view to another device's grid has to place it again.
        #if os(macOS)
        view.superview?.needsLayout = true
        #else
        view.superview?.setNeedsLayout()
        #endif
    }

    /// The user is using the session here: asks to drive it at the grid
    /// that fits this view.
    public func claimSize() {
        guard hasLaidOut else {
            // Not laid out yet, so the size is not known. Claim once it is.
            claimWhenLaidOut = true
            return
        }
        pendingReport?.cancel()
        onClaim?(naturalSize)
    }

    /// The host changed the PTY size. When another device drives, show its
    /// grid as is rather than our own, so the content lines up.
    public func hostResized(to size: TermSize, driver: Bool) {
        foreignSize = driver ? nil : (size == naturalSize ? nil : size)
        // Until this view has been laid out, the grid that fits it is not
        // known: the session keeps its own rather than a made-up one. Once
        // the view is on screen it reports what fits and the session follows.
        setGrid(driver && hasLaidOut ? naturalSize : size)
    }

    private func setGrid(_ size: TermSize) {
        guard grid != size else { return }
        grid = size
        applyingRemoteSize = true
        view.resize(cols: size.cols, rows: size.rows)
        applyingRemoteSize = false
        // A session that changes hands is drawn again for its new size.
        // Whoever was reading further up is brought back to the screen as
        // it is now, rather than left at a place in the old output that no
        // longer lines up, with the prompt out of sight.
        view.scroll(toPosition: 1)
        #if os(macOS)
        view.needsDisplay = true
        #else
        view.setNeedsDisplay()
        #endif
    }

    /// Layout can change several times in a row (a window being dragged, the
    /// iOS keyboard sliding in). Only the size it settles on is reported.
    private func reportNaturalSizeSoon() {
        pendingReport?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Reported even while another device drives: the host does not
            // act on it then, but uses it when the user types here again.
            if self.claimWhenLaidOut {
                self.claimWhenLaidOut = false
                self.onClaim?(self.naturalSize)
            } else {
                self.onResize?(self.naturalSize)
            }
        }
        pendingReport = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    // MARK: TerminalViewDelegate

    public nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        MainActor.assumeIsolated {
            guard !applyingRemoteSize else { return }
            let reported = TermSize(cols: newCols, rows: newRows)
            if let foreignSize {
                // While another device drives, the view is sized to that
                // device's grid, so what it reports is that grid or a layout
                // pass on the way to it. It is never the size that fits here;
                // that comes from `containerResized`.
                grid = reported
                if reported != foreignSize {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.foreignSize == foreignSize else { return }
                        self.setGrid(foreignSize)
                    }
                }
                return
            }
            // The view fills its container and picked the grid that fits it.
            naturalSize = reported
            grid = reported
            hasLaidOut = true
            reportNaturalSizeSoon()
        }
    }

    public nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Data(data)
        MainActor.assumeIsolated {
            guard !isReplayAnswer(bytes) else { return }
            onInput?(bytes)
        }
    }

    public nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
    public nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    public nonisolated func scrolled(source: TerminalView, position: Double) {}
    public nonisolated func bell(source: TerminalView) {}
    public nonisolated func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    public nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    public nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased()) else { return }
        DispatchQueue.main.async {
            #if os(macOS)
            NSWorkspace.shared.open(url)
            #else
            UIApplication.shared.open(url)
            #endif
        }
    }

    public nonisolated func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        DispatchQueue.main.async {
            #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            #else
            UIPasteboard.general.string = text
            #endif
        }
    }
}
