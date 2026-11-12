import AgentTermHost
import AgentTermProtocol
import Combine
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Pairs an iPhone with this Mac and lists the devices already paired.
///
/// The code on show works once and for a few minutes. It stops working when
/// this sheet closes. While Tailscale is not ready on this Mac, the sheet
/// shows what to do about that instead of a code.
struct PairingView: View {
    @EnvironmentObject private var model: AppModel
    let port: UInt16
    @Environment(\.dismiss) private var dismiss
    @State private var status: TailscaleStatus?
    @State private var copied = false
    @State private var checking = false
    @State private var now = Date()
    /// Re-checks while the sheet is open, so the code appears by itself once
    /// Tailscale is installed, signed in and connected.
    private let recheck = Timer.publish(every: 3, on: .main, in: .common).autoconnect()
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var host: String? {
        if case .ready(let host) = status { return host }
        return nil
    }

    var body: some View {
        VStack(spacing: 18) {
            Text("Pair a Device")
                .font(.system(size: 18, weight: .semibold))

            if let device = model.justPaired {
                paired(device)
            } else if let host {
                if let code = model.pairingCode, code.expiresAt > now,
                    let image = Self.qrCode(for: link(host: host, code: code))
                {
                    ready(host: host, code: code, image: image)
                } else {
                    ProgressView().controlSize(.small).frame(height: 248)
                }
            } else if let status {
                setup(for: status)
            } else {
                ProgressView().controlSize(.small).frame(height: 248)
            }

            if !model.devices.isEmpty {
                devices
            }

            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(28)
        .frame(width: 400)
        .onAppear(perform: check)
        .onDisappear { model.cancelPairingCode() }
        .onReceive(recheck) { _ in check() }
        .onReceive(clock) { now = $0 }
        .onChange(of: host) { _, _ in renewCodeIfNeeded() }
        .onChange(of: now) { _, _ in renewCodeIfNeeded() }
    }

    private func link(host: String, code: PairingCode) -> String {
        PairingInfo(host: host, port: port, code: code.code, name: Host.current().localizedName ?? "Mac").url.absoluteString
    }

    /// Keeps a working code on show: asks for one when Tailscale becomes
    /// ready, and for a new one when the old one runs out.
    private func renewCodeIfNeeded() {
        guard host != nil, model.justPaired == nil else { return }
        if let code = model.pairingCode, code.expiresAt > now { return }
        guard !requesting else { return }
        requesting = true
        model.requestPairingCode()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { requesting = false }
    }

    @State private var requesting = false

    // MARK: Ready

    @ViewBuilder
    private func ready(host: String, code: PairingCode, image: NSImage) -> some View {
        Image(nsImage: image)
            .interpolation(.none)
            .resizable()
            .frame(width: 220, height: 220)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white))

        Text("This code works once and expires in \(remaining(until: code.expiresAt)).")
            .font(.system(size: 12, weight: .medium))
            .monospacedDigit()

        VStack(alignment: .leading, spacing: 10) {
            Step(number: 1, text: "Install Tailscale on the iPhone or the other Mac and sign in to the same account as this Mac.")
            Step(number: 2, text: "On an iPhone, open AgentTerm and scan this code. On another Mac, copy the link below and paste it under Pair with Another Mac.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        Text("\(host):\(String(port))")
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)

        HStack(spacing: 10) {
            // The iPhone app can also take the link as text, for when
            // scanning is not possible.
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link(host: host, code: code), forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
            } label: {
                Label(copied ? "Copied" : "Copy Pairing Link", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .help("Copy the link to paste into \"Enter a pairing link\" on the iPhone, or \"Pair with Another Mac\" on a Mac")
            Button("New Code") { model.requestPairingCode() }
                .help("Replace this code. The old one stops working at once.")
        }

        Label("The code stops working when this window closes. Until then, whoever has it can pair a device with this Mac.", systemImage: "lock.fill")
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func remaining(until date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now).rounded(.up)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: Paired

    @ViewBuilder
    private func paired(_ device: DeviceInfo) -> some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 44))
            .foregroundStyle(Theme.added)
            .padding(.top, 8)
        Text("\(device.name) is paired")
            .font(.headline)
        Text("It can now open this Mac's sessions. The code it used no longer works.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        Button("Pair Another Device") { model.requestPairingCode() }
    }

    // MARK: Devices

    private var devices: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PAIRED DEVICES (\(model.devices.count))")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
            // A long list scrolls in place, so the sheet never grows past the
            // screen and hides what is under it.
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.devices) { device in
                        HStack(spacing: 9) {
                            Image(systemName: "iphone")
                                .foregroundStyle(device.isConnected ? Theme.added : .secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(device.name).font(.system(size: 12.5))
                                Text(subtitle(for: device))
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 6)
                            Button("Remove", role: .destructive) { model.revoke(device) }
                                .controlSize(.small)
                                .help("Take this device's access away. It has to be paired again to come back.")
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        if device.id != model.devices.last?.id {
                            Theme.hairline.frame(height: 1).padding(.leading, 34)
                        }
                    }
                }
            }
            .defaultScrollAnchor(.top)
            .frame(height: min(CGFloat(model.devices.count) * Self.deviceRowHeight, Self.deviceRowHeight * 3.4))
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.black.opacity(0.22)))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Height of one device in the list, its separator included.
    private static let deviceRowHeight: CGFloat = 43

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    private func subtitle(for device: DeviceInfo) -> String {
        if device.isConnected { return "Connected now" }
        guard let seen = device.lastSeenAt else { return "Has not connected since it was paired" }
        return seen.timeIntervalSince(now) > -60 ? "Last connected just now" : "Last connected \(Self.relative.localizedString(for: seen, relativeTo: now))"
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
        Text(
            "AgentTerm reaches this Mac from your iPhone or another Mac over Tailscale, a private network between your own devices. "
                + "The pairing code appears here once Tailscale is ready on this Mac."
        )
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
        let phone = "Install Tailscale on the iPhone or the other Mac too and sign in to the same account."
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
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Tailscale.status()
            DispatchQueue.main.async {
                if status != result { status = result }
                checking = false
                renewCodeIfNeeded()
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
