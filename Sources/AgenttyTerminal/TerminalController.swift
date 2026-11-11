import AgenttyProtocol
import SwiftTerm
import SwiftUI

/// One terminal emulator view bound to one host session.
@MainActor
public final class TerminalController: NSObject, TerminalViewDelegate {
    public let session: SessionID
    public let view: TerminalView

    /// Called with bytes the user typed.
    public var onInput: ((Data) -> Void)?
    /// Called when this view's own grid size changes and should drive the PTY.
    public var onResize: ((TermSize) -> Void)?

    /// The grid that fits this view, regardless of who drives the PTY.
    public private(set) var naturalSize: TermSize = .default
    /// Set while another device's size is in effect.
    public private(set) var foreignSize: TermSize?

    private var applyingRemoteSize = false
    private var hasLaidOut = false
    /// The emulator's current grid. SwiftTerm does not expose it.
    private var grid: TermSize?
    private var pendingReport: DispatchWorkItem?

    public init(session: SessionID, fontSize: CGFloat = 13) {
        self.session = session
        view = TerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
        super.init()
        view.font = TerminalStyle.font(size: fontSize)
        view.nativeBackgroundColor = TerminalStyle.background
        view.nativeForegroundColor = TerminalStyle.foreground
        view.terminalDelegate = self
    }

    public func feed(_ data: Data) {
        view.feed(byteArray: ArraySlice([UInt8](data)))
    }

    /// Sends bytes as if they were typed in the terminal.
    public func type(_ bytes: [UInt8]) {
        onInput?(Data(bytes))
    }

    public func setFontSize(_ size: CGFloat) {
        view.font = TerminalStyle.font(size: size)
    }

    /// Reports the grid that fits the view, making this client the driver.
    public func claimSize() {
        guard hasLaidOut else { return }
        pendingReport?.cancel()
        onResize?(naturalSize)
    }

    /// The host changed the PTY size. When another device drives, show its
    /// grid as is rather than our own, so the content lines up.
    public func hostResized(to size: TermSize, driver: Bool) {
        foreignSize = driver ? nil : (size == naturalSize ? nil : size)
        setGrid(driver ? naturalSize : size)
    }

    private func setGrid(_ size: TermSize) {
        guard grid != size else { return }
        grid = size
        applyingRemoteSize = true
        view.resize(cols: size.cols, rows: size.rows)
        applyingRemoteSize = false
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
            guard let self, self.foreignSize == nil else { return }
            self.onResize?(self.naturalSize)
        }
        pendingReport = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    // MARK: TerminalViewDelegate

    public nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        MainActor.assumeIsolated {
            guard !applyingRemoteSize else { return }
            // The view was laid out and picked the grid that fits it.
            naturalSize = TermSize(cols: newCols, rows: newRows)
            grid = naturalSize
            hasLaidOut = true
            if let foreignSize {
                // Another device is driving. A layout change here must not
                // steal control, so put its grid back once layout is done.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.foreignSize == foreignSize else { return }
                    self.setGrid(foreignSize)
                }
            } else {
                reportNaturalSizeSoon()
            }
        }
    }

    public nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Data(data)
        MainActor.assumeIsolated { onInput?(bytes) }
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
