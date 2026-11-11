import AgenttyProtocol
import AppKit
import SwiftTerm
import SwiftUI

/// One terminal emulator view bound to one host session.
@MainActor
final class TerminalController: NSObject, TerminalViewDelegate {
    let session: SessionID
    let view: TerminalView

    /// Called with bytes the user typed.
    var onInput: ((Data) -> Void)?
    /// Called when this window's own grid size changes and should drive the PTY.
    var onResize: ((TermSize) -> Void)?

    /// The grid that fits this window, regardless of who drives the PTY.
    private(set) var naturalSize: TermSize = .default
    /// Set while another device's size is in effect.
    private(set) var foreignSize: TermSize?
    private var applyingRemoteSize = false
    private var hasLaidOut = false
    /// The emulator's current grid. SwiftTerm does not expose it.
    private var grid: TermSize?

    init(session: SessionID) {
        self.session = session
        view = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        super.init()
        view.font = Theme.terminalFont
        view.nativeBackgroundColor = Theme.terminalBackground
        view.nativeForegroundColor = Theme.terminalForeground
        view.terminalDelegate = self
    }

    func feed(_ data: Data) {
        view.feed(byteArray: ArraySlice([UInt8](data)))
    }

    /// Reports the grid that fits the window, making this client the driver.
    func claimSize() {
        guard hasLaidOut else { return }
        onResize?(naturalSize)
    }

    /// The host changed the PTY size. When another device drives, show its
    /// grid as is rather than our own, so the content lines up.
    func hostResized(to size: TermSize, driver: Bool) {
        foreignSize = driver ? nil : (size == naturalSize ? nil : size)
        setGrid(driver ? naturalSize : size)
    }

    private func setGrid(_ size: TermSize) {
        guard grid != size else { return }
        grid = size
        applyingRemoteSize = true
        view.resize(cols: size.cols, rows: size.rows)
        applyingRemoteSize = false
        view.needsDisplay = true
    }

    // MARK: TerminalViewDelegate

    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        MainActor.assumeIsolated {
            guard !applyingRemoteSize else { return }
            // The view was laid out and picked the grid that fits it.
            naturalSize = TermSize(cols: newCols, rows: newRows)
            grid = naturalSize
            hasLaidOut = true
            if let foreignSize {
                // Another device is driving. Resizing our window must not
                // steal control, so put its grid back once layout is done.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.foreignSize == foreignSize else { return }
                    self.setGrid(foreignSize)
                }
            } else {
                onResize?(naturalSize)
            }
        }
    }

    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Data(data)
        MainActor.assumeIsolated { onInput?(bytes) }
    }

    nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func scrolled(source: TerminalView, position: Double) {}
    nonisolated func bell(source: TerminalView) {}
    nonisolated func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased()) else { return }
        DispatchQueue.main.async { NSWorkspace.shared.open(url) }
    }

    nonisolated func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        DispatchQueue.main.async {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
}

/// Hosts the terminal view of whichever session is selected.
struct TerminalPane: NSViewRepresentable {
    let controller: TerminalController

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = Theme.terminalBackground.cgColor
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        let terminal = controller.view
        guard terminal.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        terminal.frame = container.bounds
        terminal.autoresizingMask = [.width, .height]
        container.addSubview(terminal)
        DispatchQueue.main.async {
            terminal.window?.makeFirstResponder(terminal)
            // Showing a session means using it here, so take over its size.
            controller.claimSize()
        }
    }
}
