import AgenttyTerminal
import AppKit
import SwiftUI

/// Hosts the terminal view of whichever session is selected.
struct TerminalPane: NSViewRepresentable {
    let controller: TerminalController

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = TerminalStyle.background.cgColor
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
