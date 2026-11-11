import Foundation

/// What an iPhone needs to reach a host and pair with it. Encoded as an
/// `agentterm://pair` URL and shown as a QR code by the macOS app.
///
/// The code is not a credential to keep: it works once, for a few minutes,
/// and is traded for a token that belongs to the device.
public struct PairingInfo: Equatable, Sendable {
    /// Tailscale MagicDNS name or IP address of the Mac.
    public var host: String
    public var port: UInt16
    public var code: String
    /// Human readable name of the Mac.
    public var name: String

    public init(host: String, port: UInt16, code: String, name: String) {
        self.host = host
        self.port = port
        self.code = code
        self.name = name
    }

    public var url: URL {
        var c = URLComponents()
        c.scheme = AppChannel.current.linkScheme
        c.host = "pair"
        c.queryItems = [
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "name", value: name),
        ]
        return c.url!
    }

    public init?(url: URL) {
        // A link of either channel is understood: a development app can be
        // paired with a released Mac app and the other way round.
        guard let scheme = url.scheme, AppChannel.linkSchemes.contains(scheme), url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let host = value("host"), !host.isEmpty,
              let port = value("port").flatMap(UInt16.init),
              let code = value("code"), !code.isEmpty
        else { return nil }
        self.init(host: host, port: port, code: code, name: value("name") ?? host)
    }
}
