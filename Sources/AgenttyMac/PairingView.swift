import AgenttyHost
import AgenttyProtocol
import Combine
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Shows the QR code an iPhone scans to pair with this Mac, or, while
/// Tailscale is not ready on this Mac, what to do about that.
struct PairingView: View {
    let port: UInt16
    @Environment(\.dismiss) private var dismiss
    @State private var status: TailscaleStatus?
    @State private var info: PairingInfo?
    @State private var copied = false
    @State private var checking = false
    /// Re-checks while the sheet is open, so the code appears by itself once
    /// Tailscale is installed, signed in and connected.
    private let recheck = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 18) {
            Text("Pair an iPhone")
                .font(.system(size: 18, weight: .semibold))

            if let info, let image = Self.qrCode(for: info.url.absoluteString) {
                ready(info, image)
            } else if let status {
                setup(for: status)
            } else {
                ProgressView().controlSize(.small).frame(height: 248)
            }

            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(28)
        .frame(width: 400)
        .onAppear(perform: check)
        .onReceive(recheck) { _ in check() }
    }

    // MARK: Ready

    @ViewBuilder
    private func ready(_ info: PairingInfo, _ image: NSImage) -> some View {
        Image(nsImage: image)
            .interpolation(.none)
            .resizable()
            .frame(width: 220, height: 220)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white))

        VStack(alignment: .leading, spacing: 10) {
            Step(number: 1, text: "Install Tailscale on the iPhone and sign in to the same account as this Mac.")
            Step(number: 2, text: "Open Agentty on the iPhone and scan this code, or copy the link below and paste it there.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        Text("\(info.host):\(String(info.port))")
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)

        // The iPhone app can also take the link as text, for when scanning
        // is not possible.
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(info.url.absoluteString, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
        } label: {
            Label(copied ? "Copied" : "Copy Pairing Link", systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .help("Copy the link to paste into \"Enter a pairing link\" on the iPhone")

        Label("Anyone with this code or link can run commands on this Mac. Don't share it.", systemImage: "lock.fill")
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Not ready

    @ViewBuilder
    private func setup(for status: TailscaleStatus) -> some View {
        Image(systemName: status == .notInstalled ? "arrow.down.circle" : "network.slash")
            .font(.system(size: 34))
            .foregroundStyle(.secondary)
            .padding(.top, 4)

        Text(title(for: status))
            .font(.headline)
        Text("Agentty reaches this Mac from your iPhone over Tailscale, a private network between your own devices. The pairing code appears here once Tailscale is ready on this Mac.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(steps(for: status).enumerated()), id: \.offset) { index, text in
                Step(number: index + 1, text: text)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        HStack(spacing: 10) {
            if status == .notInstalled {
                Button("Get Tailscale") { NSWorkspace.shared.open(URL(string: "https://tailscale.com/download/mac")!) }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Open Tailscale") { openTailscale() }
                    .buttonStyle(.borderedProminent)
            }
            Button("Check Again") { check() }
            if checking { ProgressView().controlSize(.small) }
        }
    }

    private func title(for status: TailscaleStatus) -> String {
        switch status {
        case .notInstalled: return "Tailscale is not installed on this Mac"
        case .needsLogin: return "Sign in to Tailscale on this Mac"
        case .notConnected, .ready: return "Tailscale is not connected on this Mac"
        }
    }

    private func steps(for status: TailscaleStatus) -> [String] {
        let phone = "Install Tailscale on the iPhone too and sign in to the same account."
        switch status {
        case .notInstalled:
            return ["Install Tailscale on this Mac.", "Open it and sign in.", phone]
        case .needsLogin:
            return ["Open Tailscale on this Mac and sign in.", phone]
        case .notConnected, .ready:
            return ["Open Tailscale on this Mac and choose Connect.", phone]
        }
    }

    private func openTailscale() {
        let identifiers = ["io.tailscale.ipn.macos", "io.tailscale.ipn.macsys"]
        if let url = identifiers.lazy.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(URL(string: "https://tailscale.com/download/mac")!)
        }
    }

    // MARK: Checking

    private func check() {
        guard !checking else { return }
        checking = true
        let port = port
        DispatchQueue.global(qos: .userInitiated).async {
            let result = AppModel.pairingState(port: port)
            DispatchQueue.main.async {
                status = result.status
                if info != result.info { info = result.info }
                checking = false
            }
        }
    }

    static func qrCode(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        let representation = NSCIImageRep(ciImage: output)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}

private struct Step: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Theme.raised))
            Text(text)
                .font(.system(size: 12.5))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
