#if os(macOS)
import AgenttyProtocol
import Foundation

/// Works out which conversation each running agent session is having, so the
/// session can be named after what it is about.
///
/// Agents do not say which conversation a terminal belongs to. What is known
/// is the agent, the folder and when the session started, against each
/// conversation's agent, folder and start. That is enough unless two sessions
/// of one agent start in one folder within the same moment.
public enum SessionSummaries {
    public struct Running: Equatable, Sendable {
        public var id: SessionID
        public var agent: String
        public var cwd: String
        public var createdAt: Date
        /// Already known, for a resumed conversation or one matched earlier.
        public var conversationID: String?

        public init(id: SessionID, agent: String, cwd: String, createdAt: Date, conversationID: String? = nil) {
            self.id = id
            self.agent = agent
            self.cwd = cwd
            self.createdAt = createdAt
            self.conversationID = conversationID
        }
    }

    /// The agent a command line starts, if it is one Agentty knows.
    public static func agent(forCommand command: String?) -> String? {
        guard let first = command?.split(whereSeparator: \.isWhitespace).first else { return nil }
        let name = (String(first) as NSString).lastPathComponent
        return AgentDetector.known.contains { $0.id == name } ? name : nil
    }

    /// Pairs sessions with conversations. A conversation goes to one session only.
    public static func assign(_ sessions: [Running], conversations: [Conversation]) -> [SessionID: Conversation] {
        var result: [SessionID: Conversation] = [:]
        var taken: Set<String> = []

        // Conversations that are already known keep their session.
        for session in sessions {
            guard let known = session.conversationID,
                  let conversation = conversations.first(where: { $0.agent == session.agent && $0.sessionID == known })
            else { continue }
            result[session.id] = conversation
            taken.insert(conversation.id)
        }

        // Oldest session first: it takes the first conversation that began
        // after it started.
        let slack: TimeInterval = 5
        for session in sessions.sorted(by: { $0.createdAt < $1.createdAt }) where result[session.id] == nil {
            let folder = URL(fileURLWithPath: session.cwd).standardizedFileURL.path
            let candidates = conversations.filter {
                $0.agent == session.agent && !taken.contains($0.id)
                    && URL(fileURLWithPath: $0.cwd).standardizedFileURL.path == folder
            }
            let earliest = session.createdAt.addingTimeInterval(-slack)
            let began = candidates
                .filter { ($0.startedAt ?? .distantPast) >= earliest }
                .min { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
            // Where the agent does not record a start, fall back to the
            // conversation it touched most recently since the session began.
            let touched = candidates
                .filter { $0.startedAt == nil && $0.updatedAt >= earliest }
                .max { $0.updatedAt < $1.updatedAt }
            if let match = began ?? touched {
                result[session.id] = match
                taken.insert(match.id)
            }
        }
        return result
    }
}
#endif
