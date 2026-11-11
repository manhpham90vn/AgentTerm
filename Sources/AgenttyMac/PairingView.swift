import AgenttyProtocol
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Shows the QR code an iPhone scans to pair with this Mac.
struct PairingView: View {
    let port: UInt16
    @Environment(\.dismiss) private var dismiss
    @State private var info: PairingInfo?
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 18) {
            Text("Pair an iPhone")
                .font(.system(size: 18, weight: .semibold))

            if let info, let image = Self.qrCode(for: info.url.absoluteString) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 220, height: 220)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white))
                VStack(spacing: 4) {
                    Text("Scan this code with Agentty on your iPhone.")
                    Text("\(info.host):\(String(info.port))")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Label("Anyone with this code can run commands on this Mac. Don't share it.", systemImage: "lock.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            } else if loaded {
                Image(systemName: "network.slash")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                Text("Tailscale isn't connected on this Mac")
                    .font(.headline)
                Text("Agentty reaches your Mac over Tailscale. Install it on this Mac and on your iPhone, sign in to the same account on both, then try again.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { load() }
            } else {
                ProgressView().controlSize(.small).frame(height: 248)
            }

            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(28)
        .frame(width: 380)
        .onAppear(perform: load)
    }

    private func load() {
        loaded = false
        let port = port
        DispatchQueue.global(qos: .userInitiated).async {
            let result = AppModel.pairingInfo(port: port)
            DispatchQueue.main.async {
                info = result
                loaded = true
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
