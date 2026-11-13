import ActivityKit
import Foundation

/// What the Live Activity shows of the agents on a Mac (#24): how many work,
/// which wait for an instruction, which are done. Only the sessions' names,
/// never what the agents said: it is on the lock screen.
struct AgentsActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var working: Int
        /// The names of the sessions that wait, with the first one's number.
        var waiting: [String]
        var firstWaiting: UInt32?
        var done: [String]
    }

    /// The Mac the agents run on.
    var mac: String
}

extension AgentsActivityAttributes.ContentState {
    /// "2 working · review waits".
    var summary: String {
        var parts: [String] = []
        if working > 0 { parts.append("\(working) working") }
        if let first = waiting.first { parts.append(waiting.count == 1 ? "\(first) waits" : "\(waiting.count) wait") }
        if !done.isEmpty { parts.append(done.count == 1 ? "\(done[0]) is done" : "\(done.count) done") }
        return parts.isEmpty ? "Nothing running" : parts.joined(separator: " · ")
    }
}
