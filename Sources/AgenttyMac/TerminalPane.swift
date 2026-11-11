import AgenttyProtocol
import AgenttyTerminal
import AppKit
import SwiftUI

/// Hosts the terminal view of whichever session is selected.
struct TerminalPane: NSViewRepresentable {
    let controller: TerminalController
    /// The grid another device imposed, while it drives the session.
    let foreignSize: TermSize?

    func makeNSView(context: Context) -> TerminalContainerView {
        TerminalContainerView()
    }

    func updateNSView(_ container: TerminalContainerView, context: Context) {
        container.show(controller, foreignSize: foreignSize)
    }
}

/// Lays the terminal out in its pane.
///
/// Normally the terminal fills the pane. While another device drives the
/// session the emulator draws that device's grid, which is usually much
/// smaller than a Mac window. Left alone it would sit in the top-left corner
/// with the rest of the pane blank, which looks broken. Instead the grid is
/// centered and framed like a preview of the other device's screen.
final class TerminalContainerView: NSView {
    private var controller: TerminalController?
    private var foreignSize: TermSize?
    private let dim = CAShapeLayer()
    private let frameLine = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = TerminalStyle.background.cgColor
        layer?.masksToBounds = true

        dim.fillRule = .evenOdd
        dim.fillColor = NSColor.black.withAlphaComponent(0.42).cgColor
        frameLine.fillColor = nil
        frameLine.strokeColor = NSColor.white.withAlphaComponent(0.22).cgColor
        frameLine.lineWidth = 1
        for overlay in [dim, frameLine] {
            // Above the terminal view's own layer.
            overlay.zPosition = 10
            overlay.isHidden = true
            layer?.addSublayer(overlay)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    func show(_ controller: TerminalController, foreignSize: TermSize?) {
        let terminal = controller.view
        if terminal.superview !== self {
            subviews.forEach { $0.removeFromSuperview() }
            // Positioned in `layout`, not by autoresizing: its origin moves
            // while another device's grid is shown.
            terminal.autoresizingMask = []
            addSubview(terminal)
            self.controller = controller
            // Looking at a session is not using it: the Mac app shows every
            // session, including ones a phone is typing in. The size comes
            // here when the user types, or asks for it in the banner.
            DispatchQueue.main.async {
                terminal.window?.makeFirstResponder(terminal)
            }
        }
        self.foreignSize = foreignSize
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let controller else { return }
        let terminal = controller.view

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard foreignSize != nil else {
            terminal.frame = bounds
            dim.isHidden = true
            frameLine.isHidden = true
            return
        }

        // The view keeps the pane's size, so the size that fits this window
        // is still known when control comes back. Only its origin moves, to
        // bring the grid it draws in its top-left corner to the middle.
        let grid = controller.gridPixelSize
        let dx = max(0, ((bounds.width - grid.width) / 2).rounded(.down))
        let dy = max(0, ((bounds.height - grid.height) / 2).rounded(.down))
        terminal.frame = NSRect(x: dx, y: -dy, width: bounds.width, height: bounds.height)

        let card = NSRect(x: dx, y: bounds.height - dy - grid.height, width: grid.width, height: grid.height)
            .insetBy(dx: -10, dy: -10)
            .intersection(bounds.insetBy(dx: 1, dy: 1))
        let outline = CGPath(roundedRect: card, cornerWidth: 10, cornerHeight: 10, transform: nil)
        let surround = CGMutablePath()
        surround.addRect(bounds)
        surround.addPath(outline)
        dim.frame = bounds
        dim.path = surround
        dim.isHidden = false
        frameLine.frame = bounds
        frameLine.path = outline
        frameLine.isHidden = false
    }
}
