#if os(macOS)
import CoreServices
import Darwin
import Foundation

/// Whether a phone could reach this Mac over Tailscale right now.
public enum TailscaleStatus: Equatable, Sendable {
    /// Tailscale is not on this Mac.
    case notInstalled
    /// Installed, but nobody is signed in.
    case needsLogin
    /// Installed and signed in, but switched off or still starting.
    case notConnected
    /// Connected. `host` is the name or address a phone should use.
    case ready(host: String)
}

/// Reads this Mac's Tailscale identity without depending on Tailscale itself.
public enum Tailscale {
    private static let cliCandidates = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
    ]

    private static var cli: String? {
        cliCandidates.first(where: FileManager.default.isExecutableFile(atPath:))
    }

    /// True when the Tailscale app or command line tool is on this Mac.
    public static var isInstalled: Bool {
        if cli != nil { return true }
        // The app can live outside /Applications; ask the system by identifier
        // (App Store build, then the standalone build).
        return ["io.tailscale.ipn.macos", "io.tailscale.ipn.macsys"].contains { identifier in
            LSCopyApplicationURLsForBundleIdentifier(identifier as CFString, nil) != nil
        }
    }

    /// Checks installation and connection. Runs the Tailscale CLI when there
    /// is one, so call it off the main thread.
    public static func status() -> TailscaleStatus {
        var backendState: String?
        var dnsName: String?
        if let cli, let result = Subprocess.run(cli, ["status", "--json"], timeout: 4),
           let json = try? JSONSerialization.jsonObject(with: result.output) as? [String: Any] {
            backendState = json["BackendState"] as? String
            dnsName = (json["Self"] as? [String: Any])?["DNSName"] as? String
        }
        return status(installed: isInstalled, backendState: backendState, address: ipv4Address(), dnsName: dnsName)
    }

    /// The decision behind `status()`, separated from the system calls.
    static func status(installed: Bool, backendState: String?, address: String?, dnsName: String?) -> TailscaleStatus {
        // An address in Tailscale's range is proof enough of a working
        // connection, even where the CLI cannot be found or asked.
        if let address, backendState == nil || backendState == "Running" {
            let name = dnsName.map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
            return .ready(host: name?.isEmpty == false ? name! : address)
        }
        guard installed else { return .notInstalled }
        return backendState == "NeedsLogin" ? .needsLogin : .notConnected
    }

    /// The Mac's address in the Tailscale range 100.64.0.0/10, if it is connected.
    public static func ipv4Address() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        var cursor = list
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                  entry.pointee.ifa_flags & UInt32(IFF_UP) != 0
            else { continue }
            let raw = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            if raw & 0xFFC0_0000 == 0x6440_0000 {
                return "\(raw >> 24).\((raw >> 16) & 0xff).\((raw >> 8) & 0xff).\(raw & 0xff)"
            }
        }
        return nil
    }

    /// The Mac's MagicDNS name, e.g. "macbook.tail1234.ts.net". Needs the
    /// Tailscale CLI, which ships inside the app.
    public static func dnsName() -> String? {
        guard let cli, let result = Subprocess.run(cli, ["status", "--json"], timeout: 4), result.status == 0,
              let json = try? JSONSerialization.jsonObject(with: result.output) as? [String: Any],
              let me = json["Self"] as? [String: Any],
              let name = me["DNSName"] as? String
        else { return nil }
        let trimmed = name.hasSuffix(".") ? String(name.dropLast()) : name
        return trimmed.isEmpty ? nil : trimmed
    }
}
#endif
