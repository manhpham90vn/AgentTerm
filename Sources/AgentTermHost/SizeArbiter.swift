import AgentTermProtocol

public typealias ClientID = UInt64

/// Decides the size of a PTY that several clients look at.
///
/// A PTY has exactly one size, but a Mac window and an iPhone screen rarely
/// agree. The rule is "the client being used wins": whichever client last
/// took control or typed is the driver and the PTY takes its size. When the
/// driver leaves, the most recently active remaining client takes over.
///
/// Merely watching a session, or having one's window resized, never takes
/// the size away from the client that is using it. Otherwise an app that is
/// only open in the background would keep resizing what a phone is typing in.
public struct SizeArbiter: Sendable {
    /// Clients ordered from least to most recently active.
    private var order: [ClientID] = []
    private var sizes: [ClientID: TermSize] = [:]
    private let fallback: TermSize

    public init(fallback: TermSize = .default) {
        self.fallback = fallback
    }

    public var driver: ClientID? { order.last }
    public var clients: [ClientID] { order }
    public var isEmpty: Bool { order.isEmpty }

    /// Size the PTY should have right now. With no client attached the last
    /// known size is kept so a detached program is not disturbed.
    public private(set) var effectiveSize: TermSize?

    public var currentSize: TermSize { effectiveSize ?? fallback }

    /// The client is using the session: records its size and makes it the
    /// driver. Returns true when the effective size changed.
    @discardableResult
    public mutating func takeControl(_ client: ClientID, size: TermSize) -> Bool {
        sizes[client] = size.clamped
        return promote(client)
    }

    /// The client started watching, or its own grid changed. Its size is
    /// remembered for when it types, but it only becomes the driver when
    /// nobody else is there. Returns true when the effective size changed.
    @discardableResult
    public mutating func update(_ client: ClientID, size: TermSize) -> Bool {
        let isNew = sizes[client] == nil
        sizes[client] = size.clamped
        if isNew {
            // Behind everyone already there: the last to be handed control.
            order.insert(client, at: 0)
        }
        return recompute()
    }

    /// Marks a known client as active (it typed something).
    /// Returns true when the effective size changed.
    @discardableResult
    public mutating func activity(_ client: ClientID) -> Bool {
        guard sizes[client] != nil, driver != client else { return false }
        return promote(client)
    }

    /// Returns true when the effective size changed.
    @discardableResult
    public mutating func remove(_ client: ClientID) -> Bool {
        order.removeAll { $0 == client }
        sizes[client] = nil
        return recompute()
    }

    private mutating func promote(_ client: ClientID) -> Bool {
        order.removeAll { $0 == client }
        order.append(client)
        return recompute()
    }

    private mutating func recompute() -> Bool {
        guard let driver, let size = sizes[driver] else { return false }
        guard size != effectiveSize else { return false }
        effectiveSize = size
        return true
    }
}
