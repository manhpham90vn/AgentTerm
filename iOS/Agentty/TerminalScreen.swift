import AgenttyProtocol
import AgenttyTerminal
import SwiftUI

/// A session's terminal, sized to this screen, with a key bar and a compose field.
struct TerminalScreen: View {
    @EnvironmentObject private var model: PhoneModel
    let session: SessionID
    @State private var confirmingEnd = false

    private var controller: TerminalController? {
        model.controller?.session == session ? model.controller : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if let size = model.foreignSize {
                ForeignSizeBanner(size: size)
            }
            if let controller {
                TerminalPane(controller: controller, foreignSize: model.foreignSize)
                    .id(ObjectIdentifier(controller))
                    .padding(.leading, model.foreignSize == nil ? 6 : 0)
                    .padding(.top, model.foreignSize == nil ? 4 : 0)
                KeyBar(controller: controller)
                ComposeBar(controller: controller)
            } else {
                Spacer()
                ProgressView()
                Spacer()
            }
        }
        .background(Palette.canvas.ignoresSafeArea())
        .navigationTitle(model.session(session)?.title ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { model.changeFontSize(by: 1) } label: { Label("Larger Text", systemImage: "textformat.size.larger") }
                    Button { model.changeFontSize(by: -1) } label: { Label("Smaller Text", systemImage: "textformat.size.smaller") }
                    if let info = model.session(session), model.canHandOff(info) {
                        Divider()
                        Button { model.requestHandoff(session: info) } label: { Label("Hand Off…", systemImage: "arrowshape.turn.up.right") }
                    }
                    Divider()
                    Button(role: .destructive) { confirmingEnd = true } label: { Label("End Session", systemImage: "xmark.circle") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityIdentifier("session-menu")
            }
        }
        .confirmationDialog("End this session?", isPresented: $confirmingEnd, titleVisibility: .visible) {
            Button("End Session", role: .destructive) { model.end(session) }
        } message: {
            Text("The program running in it is stopped.")
        }
        .onAppear { model.open(session) }
        .onDisappear { model.leave(session) }
    }
}

/// Hosts the SwiftTerm view.
private struct TerminalPane: UIViewRepresentable {
    let controller: TerminalController
    /// The grid another device imposed, while it drives the session.
    let foreignSize: TermSize?

    func makeUIView(context: Context) -> TerminalContainerView {
        TerminalContainerView()
    }

    func updateUIView(_ container: TerminalContainerView, context: Context) {
        container.show(controller, foreignSize: foreignSize)
    }
}

/// Lays the terminal out in the room above the key bar.
///
/// Normally the terminal fills it, and its size decides the grid. While
/// the Mac drives the session the grid is the Mac's, far larger than a phone
/// screen. Showing it at full size would leave only its top-left corner on
/// screen. Instead the whole grid is scaled down to fit, like a picture of
/// the Mac's terminal, until the user takes the session back.
final class TerminalContainerView: UIView {
    private var controller: TerminalController?
    private var foreignSize: TermSize?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = TerminalStyle.background
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    func show(_ controller: TerminalController, foreignSize: TermSize?) {
        let terminal = controller.view
        if terminal.superview !== self {
            subviews.forEach { $0.removeFromSuperview() }
            terminal.autoresizingMask = []
            addSubview(terminal)
            self.controller = controller
            // Opening a session here means using it here, so take over its size.
            DispatchQueue.main.async { controller.claimSize() }
        }
        self.foreignSize = foreignSize
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let controller else { return }
        let terminal = controller.view
        // Geometry is set through bounds and center, which stay meaningful
        // under a transform. `frame` does not.
        terminal.transform = .identity

        guard foreignSize != nil else {
            terminal.bounds = CGRect(origin: terminal.bounds.origin, size: bounds.size)
            terminal.center = CGPoint(x: bounds.midX, y: bounds.midY)
            return
        }

        controller.containerResized(to: bounds.size)
        let grid = controller.gridPixelSize
        guard grid.width > 0, grid.height > 0 else { return }
        let scale = min(1, bounds.width / grid.width, bounds.height / grid.height)
        // A little slack so rounding never costs the last column or row.
        terminal.bounds = CGRect(origin: terminal.bounds.origin, size: CGSize(width: grid.width + 0.5, height: grid.height + 0.5))
        // Centered across, against the top: a terminal reads from the top.
        terminal.center = CGPoint(x: bounds.midX, y: grid.height * scale / 2)
        terminal.transform = CGAffineTransform(scaleX: scale, y: scale)
    }
}

private struct ForeignSizeBanner: View {
    @EnvironmentObject private var model: PhoneModel
    let size: TermSize

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "macbook").foregroundStyle(.secondary)
            Text("In use on the Mac · \(size.cols)×\(size.rows) · scaled to fit")
                .font(.footnote)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer()
            Button("Fit This Screen") { model.takeControl() }
                .font(.footnote.weight(.semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Palette.panel)
    }
}

/// Keys a phone keyboard does not have.
private struct KeyBar: View {
    let controller: TerminalController

    private struct Key: Identifiable {
        let label: String
        let name: String
        let action: (TerminalController) -> Void
        var id: String { name }
    }

    private static let keys: [Key] = [
        Key(label: "esc", name: "Escape") { $0.type([0x1b]) },
        Key(label: "tab", name: "Tab") { $0.type([0x09]) },
        Key(label: "⇧tab", name: "Shift Tab") { $0.type([0x1b, 0x5b, 0x5a]) },
        Key(label: "^C", name: "Control C") { $0.type([0x03]) },
        Key(label: "↑", name: "Up") { $0.view.sendKeyUp() },
        Key(label: "↓", name: "Down") { $0.view.sendKeyDown() },
        Key(label: "←", name: "Left") { $0.view.sendKeyLeft() },
        Key(label: "→", name: "Right") { $0.view.sendKeyRight() },
        Key(label: "⏎", name: "Return") { $0.type([0x0d]) },
        Key(label: "^D", name: "Control D") { $0.type([0x04]) },
        Key(label: "^L", name: "Control L") { $0.type([0x0c]) },
        Key(label: "^R", name: "Control R") { $0.type([0x12]) },
        Key(label: "^Z", name: "Control Z") { $0.type([0x1a]) },
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Self.keys) { key in
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        key.action(controller)
                    } label: {
                        Text(key.label)
                            .font(.system(size: 15, weight: .medium, design: .monospaced))
                            .frame(minWidth: 40, minHeight: 36)
                            .padding(.horizontal, 4)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.raised))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(key.name)
                    .accessibilityIdentifier("key-\(key.name)")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .background(Palette.panel)
        .overlay(alignment: .top) { Palette.hairline.frame(height: 1) }
    }
}

/// Text is written here with the normal iOS keyboard and input methods, then
/// sent to the terminal as finished text. Composition (Vietnamese Telex, for
/// one) never happens inside the terminal emulator this way.
private struct ComposeBar: View {
    let controller: TerminalController
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $text, axis: .vertical)
                .lineLimit(1...5)
                .focused($focused)
                .accessibilityIdentifier("compose")
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 19, style: .continuous).fill(Palette.raised))
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 34))
                    .symbolRenderingMode(.hierarchical)
            }
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .background(Palette.panel)
    }

    private func send() {
        let message = text
        text = ""
        guard !message.isEmpty else {
            controller.type([0x0d])
            return
        }
        var bytes = Array(message.replacingOccurrences(of: "\n", with: "\r").utf8)
        if message.contains("\n") {
            // Bracketed paste keeps a multi-line message in one piece.
            bytes = [0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e] + bytes + [0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e]
        }
        controller.type(bytes)
        // Sent separately: agents treat a burst that ends in Return as a
        // paste and would not submit it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            controller.type([0x0d])
        }
    }
}
