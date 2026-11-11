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
        view.feed(byteArray: ArraySlice([UInt8](data)))
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
