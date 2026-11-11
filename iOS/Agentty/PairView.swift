import SwiftUI
import VisionKit

/// First run: pair this iPhone with a Mac.
struct PairView: View {
    @EnvironmentObject private var model: PhoneModel
    @State private var scanning = false
    @State private var enteringLink = false
    @State private var link = ""

    private var canScan: Bool { DataScannerViewController.isSupported }

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: 440)
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Palette.canvas.ignoresSafeArea())
        .sheet(isPresented: $scanning) {
            ScannerSheet { url in
                scanning = false
                model.pair(with: url)
            }
        }
        .alert("Pairing Link", isPresented: $enteringLink) {
            TextField("agentty://pair?…", text: $link)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Pair") { model.pair(withText: link) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Paste the link from Agentty on your Mac.")
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            Image(systemName: "terminal")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(Palette.tint)
                .padding(.bottom, 22)
            Text("Pair with your Mac")
                .font(.system(size: 28, weight: .bold))
            Text("Run your coding agents on the Mac.\nSteer them from here.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 16) {
                Step(number: 1, text: "Connect this iPhone and your Mac to Tailscale.")
                Step(number: 2, text: "Open Agentty on the Mac and choose Pair iPhone.")
                Step(number: 3, text: "Scan the code it shows.")
            }
            .padding(.top, 34)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .leading)

            if let message = model.message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Palette.danger)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 12)
            }
            if model.isPairing {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Pairing with your Mac…").font(.subheadline)
                }
                .padding(.bottom, 14)
            }
            Button {
                scanning = true
            } label: {
                Label("Scan Code", systemImage: "qrcode.viewfinder")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canScan || model.isPairing)

            Button(canScan ? "Enter a pairing link instead" : "Enter a pairing link") {
                enteringLink = true
            }
            .font(.subheadline)
            .padding(.top, 14)
            if !canScan {
                Text("This device has no camera for scanning.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }
        }
    }
}

private struct Step: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text("\(number)")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Palette.raised))
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ScannerSheet: View {
    let onFound: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            QRScanner(onFound: onFound)
                .ignoresSafeArea()
                .navigationTitle("Scan the Code on Your Mac")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
    }
}

/// Live camera view that reports the first Agentty pairing code it sees.
private struct QRScanner: UIViewControllerRepresentable {
    let onFound: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFound: onFound) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onFound: (URL) -> Void
        private var done = false

        init(onFound: @escaping (URL) -> Void) {
            self.onFound = onFound
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for case .barcode(let code) in addedItems {
                guard let text = code.payloadStringValue, let url = URL(string: text), url.scheme == "agentty" else { continue }
                done = true
                onFound(url)
                return
            }
        }
    }
}
