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

    /// What it said or asks, without the choices: a notification's body,
    /// of which iOS shows a few lines only. The choices are its buttons
    /// (#55), which a long question does not push out of sight.
    public var words: String? {
        switch state {
        case .waitingForAnswer(let question): return question.text.isEmpty ? nil : question.text
        case .done, .waitingForPermission, .working: return detail
        }
    }

    /// A choice of a question, as a button where it is told.
    public struct Button: Equatable, Sendable, Identifiable {
        /// Names the choice by its place among the question's.
        public var id: String
        /// The choice, in the agent's words.
        public var title: String
    }

    /// As many buttons as a notification takes with a text reply beside
    /// them: iOS shows ten actions at most.
    public static let mostButtons = 9

    /// A question's choices, the first `mostButtons` of them. None for a
    /// permission, which is answered in the session.
    public var buttons: [Button] {
        guard case .waitingForAnswer(let question) = state else { return [] }
        return question.choices.prefix(Self.mostButtons).enumerated().map { Button(id: "choice-\($0.offset)", title: $0.element) }
    }

    /// The choice a button stands for, or nil when it is none of this
    /// notice's.
    public func choice(ofButton id: String) -> String? { buttons.first { $0.id == id }?.title }

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

/// When the iPhone shows the Live Activity of the agents on a Mac (#24),
/// and what ends it.
public enum LiveActivityRule {
    public enum Decision: Equatable, Sendable {
        /// Shown, or kept up to date.
        case show
        /// Ended at once: it could no longer be kept true, or no one wants it.
        case endNow
        /// Every agent is done: the last state may stay, since it stays true.
        case endShowingDone
    }

    /// All three have to hold: the phone is connected to the Mac, no one is
    /// at the Mac, and an agent works or waits.
    public static func decide(enabled: Bool, connected: Bool, macInUse: Bool, sessions: [SessionInfo]) -> Decision {
        guard enabled, connected, !macInUse else { return .endNow }
        if sessions.contains(where: { $0.state?.isWorking == true || $0.state?.isWaiting == true }) { return .show }
        return .endShowingDone
    }
}
