import AVFoundation
import AppKit
import ApplicationServices
import SwiftUI

/// What macOS lets the programs in AgentTerm's sessions do.
///
/// macOS holds a terminal responsible for everything run inside it, so a
/// permission an agent needs is a permission of AgentTerm. Some of them macOS
/// asks about by itself the first time they are used. Others are never
/// asked: they have to be asked for here, or switched on in System Settings.
enum Permission: String, CaseIterable, Identifiable {
    case accessibility
    case screenRecording
    case automation
    case fullDiskAccess
    case microphone
    case camera

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .screenRecording: return "Screen & System Audio Recording"
        case .automation: return "Automation"
        case .fullDiskAccess: return "Full Disk Access"
        case .microphone: return "Microphone"
        case .camera: return "Camera"
        }
    }

    var symbol: String {
        switch self {
        case .accessibility: return "accessibility"
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .automation: return "gearshape.2"
        case .fullDiskAccess: return "internaldrive"
        case .microphone: return "mic"
        case .camera: return "camera"
        }
    }

    /// What an agent uses it for.
    var purpose: String {
        switch self {
        case .accessibility: return "Lets an agent click, type and read what is on screen in other apps: computer use in Claude Code and Codex, the browser agent in Antigravity."
        case .screenRecording: return "Lets an agent take screenshots, which is how it sees an app or a web page it is working on."
        case .automation: return "Lets an agent script another app, such as Chrome, Safari, Finder or Xcode. macOS asks once for each app the first time."
        case .fullDiskAccess: return "Lets agents read folders macOS protects, such as Mail, Messages and other apps' data. Most projects do not need it: Desktop, Documents and Downloads are asked about on their own."
        case .microphone: return "Voice dictation in Claude Code and Antigravity."
        case .camera: return "Only when a program in a session uses the camera."
        }
    }

    enum Status { case granted, notGranted, unknown }

    var status: Status {
        switch self {
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .notGranted
        case .screenRecording:
            return CGPreflightScreenCaptureAccess() ? .granted : .notGranted
        case .automation:
            // Given per app that is scripted; there is no single answer.
            return .unknown
        case .fullDiskAccess:
            // There is no API for this one. A file only it opens tells.
            let probe = NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"
            return FileManager.default.isReadableFile(atPath: probe) ? .granted : .notGranted
        case .microphone:
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? .granted : .notGranted
        case .camera:
            return AVCaptureDevice.authorizationStatus(for: .video) == .authorized ? .granted : .notGranted
        }
    }

    /// The pane of System Settings where it is switched on.
    private var settingsURL: URL? {
        let pane: String
        switch self {
        case .accessibility: pane = "Privacy_Accessibility"
        case .screenRecording: pane = "Privacy_ScreenCapture"
        case .automation: pane = "Privacy_Automation"
        case .fullDiskAccess: pane = "Privacy_AllFiles"
        case .microphone: pane = "Privacy_Microphone"
        case .camera: pane = "Privacy_Camera"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
    }

    func openSettings() {
        if let settingsURL { NSWorkspace.shared.open(settingsURL) }
    }

    /// Asks macOS for it where macOS has a question to ask, and opens the
    /// right pane of System Settings where it has not.
    func request(then done: @escaping () -> Void) {
        switch self {
        case .accessibility:
            // Shows the system's own prompt, which leads to the pane.
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            done()
        case .screenRecording:
            // Asks the first time; later it only answers, so the pane is opened too.
            if !CGRequestScreenCaptureAccess() { openSettings() }
            done()
        case .automation, .fullDiskAccess:
            openSettings()
            done()
        case .microphone, .camera:
            let media: AVMediaType = self == .microphone ? .audio : .video
            if AVCaptureDevice.authorizationStatus(for: media) == .notDetermined {
                AVCaptureDevice.requestAccess(for: media) { _ in DispatchQueue.main.async(execute: done) }
            } else {
                openSettings()
                done()
            }
        }
    }
}

struct PermissionsView: View {
    /// Bumped to read every status again.
    @State private var refresh = 0
    private let poll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("macOS treats what an agent does as done by AgentTerm, so these are AgentTerm's permissions. Turn on what your agents need. Changes to Accessibility and Screen Recording take effect for sessions started after AgentTerm is reopened.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Permission.allCases) { permission in
                PermissionRow(permission: permission, refresh: refresh) { refresh += 1 }
                if permission != Permission.allCases.last { Divider() }
            }
        }
        .padding(22)
        .frame(width: 560)
        // The answer changes in System Settings, outside this app.
        .onReceive(poll) { _ in refresh += 1 }
    }
}

private struct PermissionRow: View {
    let permission: Permission
    let refresh: Int
    let changed: () -> Void

    var body: some View {
        let status = permission.status
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: permission.symbol)
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(permission.title).font(.system(size: 13, weight: .medium))
                    switch status {
                    case .granted:
                        Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .notGranted:
                        Label("Not allowed", systemImage: "xmark.circle").foregroundStyle(.secondary)
                    case .unknown:
                        Label("Asked per app", systemImage: "questionmark.circle").foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 11.5))
                .labelStyle(.titleAndIcon)
                Text(permission.purpose)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if status == .granted {
                Button("Open Settings") { permission.openSettings() }.controlSize(.small)
            } else {
                Button(status == .unknown ? "Open Settings" : "Allow…") { permission.request(then: changed) }
                    .controlSize(.small)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
