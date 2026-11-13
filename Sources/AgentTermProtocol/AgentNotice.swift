import Foundation

/// An agent that finished its task or needs an instruction (#22): what the
/// apps tell the user of, once for each time it happens. Worked out by each
/// app from the states the host tells it (#3), so that the session on
/// screen, and a Mac that is in use, can be left out where it is shown.
public struct AgentNotice: Equatable, Sendable {
    public var session: SessionID
    /// The session's name in the lists.
    public var name: String
    /// The folder it runs in.
    public var folder: String
    /// What the agent asks, or that it is done: the state it is in. An
    /// answer names it, so that one that arrives after the agent moved on
    /// is not typed into whatever it asks next.
    public var state: AgentState

    public init(session: SessionID, name: String, folder: String, state: AgentState) {
        self.session = session
        self.name = name
        self.folder = folder
        self.state = state
    }

    /// Why it is told, in a few words: "is done", "needs permission".
    public var why: String {
        switch state {
        case .done: return "is done"
        case .waitingForPermission: return "needs permission"
        case .waitingForAnswer: return "asks a question"
        case .working: return "is working"
        }
    }

    /// What it said or asks, enough to decide without opening it.
    public var detail: String? {
        switch state {
        case .done(let said): return said.flatMap { $0.isEmpty ? nil : String($0.suffix(300)) }
        case .waitingForPermission(let question): return question.text.isEmpty ? nil : question.text
        case .waitingForAnswer(let question):
            return question.text + (question.choices.isEmpty ? "" : "\n" + question.choices.joined(separator: " · "))
        case .working: return nil
        }
    }

    /// Whether the user can answer it in a few words where it is told: a
    /// question, or a finished task's next instruction. A permission is
    /// answered in the session, whose choices the agents do not tell.
    public var takesAReply: Bool {
        switch state {
        case .done, .waitingForAnswer: return true
        case .waitingForPermission, .working: return false
        }
    }

    /// What to tell of: each session whose agent is done or waits, in a
    /// state it was not told in before (`told`, which the app keeps across
    /// connections and updates). An agent that becomes done or starts to
    /// wait is told once; one that asks again something else is told
    /// again; one that keeps waiting is not. On connecting, what waits or
    /// is done and was not told yet is told at once.
    public static func notices(in sessions: [SessionInfo], told: inout [SessionID: AgentState]) -> [AgentNotice] {
        var notices: [AgentNotice] = []
        for session in sessions {
            guard let state = session.state else {
                told[session.id] = nil
                continue
            }
            if case .working = state {
                // Working again: what it says next is new.
                told[session.id] = nil
                continue
            }
            guard told[session.id] != state else { continue }
            told[session.id] = state
            notices.append(AgentNotice(session: session.id, name: session.displayName, folder: session.cwd, state: state))
        }
        // Sessions that ended are forgotten.
        let running = Set(sessions.map(\.id))
        told = told.filter { running.contains($0.key) }
        return notices
    }
}
