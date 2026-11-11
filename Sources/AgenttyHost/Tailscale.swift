#if os(macOS)
import Darwin
import Foundation

/// Reads this Mac's Tailscale identity without depending on Tailscale itself.
public enum Tailscale {
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
        let candidates = [
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
            "/opt/homebrew/bin/tailscale",
            "/usr/local/bin/tailscale",
        ]
        guard let cli = candidates.first(where: FileManager.default.isExecutableFile(atPath:)),
              let result = Subprocess.run(cli, ["status", "--json"], timeout: 4), result.status == 0,
              let json = try? JSONSerialization.jsonObject(with: result.output) as? [String: Any],
              let me = json["Self"] as? [String: Any],
              let name = me["DNSName"] as? String
        else { return nil }
        let trimmed = name.hasSuffix(".") ? String(name.dropLast()) : name
        return trimmed.isEmpty ? nil : trimmed
    }
}
#endif
