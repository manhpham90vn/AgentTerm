import Foundation

/// What an iPhone needs to reach and authenticate with a host. Encoded as an
/// `agentty://pair` URL and shown as a QR code by the macOS app.
public struct PairingInfo: Equatable, Sendable {
    /// Tailscale MagicDNS name or IP address of the Mac.
    public var host: String
    public var port: UInt16
    public var token: String
    /// Human readable name of the Mac.
    public var name: String

    public init(host: String, port: UInt16, token: String, name: String) {
        self.host = host
        self.port = port
        self.token = token
        self.name = name
    }

    public var url: URL {
        var c = URLComponents()
        c.scheme = "agentty"
        c.host = "pair"
        c.queryItems = [
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "name", value: name),
        ]
        return c.url!
    }

    public init?(url: URL) {
        guard url.scheme == "agentty", url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let host = value("host"), !host.isEmpty,
              let port = value("port").flatMap(UInt16.init),
              let token = value("token"), !token.isEmpty
        else { return nil }
        self.init(host: host, port: port, token: token, name: value("name") ?? host)
    }
}
