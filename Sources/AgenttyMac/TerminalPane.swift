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
        // Looking at a session is not using it: the Mac app shows every
        // session, including ones a phone is typing in. The size comes here
        // when the user types, or asks for it in the banner.
        DispatchQueue.main.async {
            terminal.window?.makeFirstResponder(terminal)
        }
    }
}
