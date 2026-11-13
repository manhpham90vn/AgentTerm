#if os(macOS)
import AgentTermProtocol
import Darwin
import Foundation

/// What a running host leaves in its state folder, so that the host after
/// it can tell a death from a stop: a stop that was asked for removes it,
/// and a host that was killed or crashed cannot.
///
/// It is `host-<port>.json`, one per port, since a host is the host of a
/// port: the app and launchd both start the host of the same one. It names
/// the process and the sessions it holds; its modification time is when
/// the host was last known to be alive, since the host touches it every
/// few seconds.
public struct HostMarker: Codable, Equatable {
    public var pid: Int32
    public var startedAt: Date
    /// The sessions running in the host, as they are named in the lists.
    public var sessions: [EndedSession]

    public init(pid: Int32 = getpid(), startedAt: Date = Date(), sessions: [EndedSession] = []) {
        self.pid = pid
        self.startedAt = startedAt
        self.sessions = sessions
    }

    public static func file(in directory: URL, port: UInt16) -> URL {
        directory.appendingPathComponent("host-\(port).json")
    }

    /// Whether a host left a marker for this port: while it runs, or after
    /// it died. The app looks at it when its connection closes, to know
    /// whether its host died.
    public static func exists(in directory: URL, port: UInt16) -> Bool {
        FileManager.default.fileExists(atPath: file(in: directory, port: port).path)
    }

    /// The marker found there, with when its host was last known to be alive.
    public static func read(_ file: URL) -> (marker: HostMarker, aliveAt: Date)? {
        guard let data = try? Data(contentsOf: file), let marker = MessageCoding.decode(HostMarker.self, from: data) else { return nil }
        let touched = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date) ?? marker.startedAt
        return (marker, touched)
    }

    public func write(to file: URL) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? MessageCoding.encode(self).write(to: file, options: .atomic)
    }

    /// Says the host is still alive, without writing the marker again.
    public static func touch(_ file: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
    }

    /// Whether the process that left the marker still runs as a host: then
    /// it did not die, whatever else is wrong. A process number that was
    /// given to another program since does not count.
    public var isRunning: Bool {
        guard pid > 0, pid != getpid(), kill(pid, 0) == 0 || errno == EPERM else { return false }
        var name = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        guard proc_name(pid, &name, UInt32(name.count)) > 0 else { return false }
        return String(cString: name) == ProcessInfo.processInfo.processName
    }
}

/// The reports of parts that stopped and that nobody has seen yet. Kept in
/// the state folder (`failures.json`), so a host that is restarted, or that
/// dies itself, still has them to tell.
public enum FailureLog {
    /// So that a part that dies again and again does not grow it for ever.
    public static let limit = 20

    public static func file(in directory: URL) -> URL { directory.appendingPathComponent("failures.json") }

    public static func read(in directory: URL) -> [PartFailure] {
        guard let data = try? Data(contentsOf: file(in: directory)) else { return [] }
        return MessageCoding.decode([PartFailure].self, from: data) ?? []
    }

    public static func write(_ failures: [PartFailure], in directory: URL) {
        let url = file(in: directory)
        if failures.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? MessageCoding.encode(Array(failures.suffix(limit))).write(to: url, options: .atomic)
    }
}
#endif
