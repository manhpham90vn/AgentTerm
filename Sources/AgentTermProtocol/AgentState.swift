import Foundation

/// What the agent in a session is doing, as the agent says it itself
/// through its hooks (#3). The host works it out and tells every client in
/// `SessionInfo.state`. A session whose state is not known, a shell above
/// all, has none: nothing is shown rather than a guess.
public enum AgentState: Codable, Equatable, Hashable, Sendable {
    /// Thinking, running a tool, writing: since when.
    case working(since: Date)
    /// It asks whether it may do one thing: run a command, change a file.
    case waitingForPermission(AgentQuestion)
    /// It asked the user a question, or offers a choice that is not a
    /// permission.
    case waitingForAnswer(AgentQuestion)
    /// It finished its turn and waits for the next instruction, with the
    /// end of what it said when the agent tells it.
    case done(said: String?)

    /// In words, for VoiceOver and for a tooltip.
    public var name: String {
        switch self {
        case .working: return "working"
        case .waitingForPermission: return "waiting for permission"
        case .waitingForAnswer: return "waiting for an answer"
        case .done: return "done"
        }
    }

    /// It waits for the user: a permission or an answer.
    public var isWaiting: Bool {
        switch self {
        case .waitingForPermission, .waitingForAnswer: return true
        case .working, .done: return false
        }
    }

    public var isWorking: Bool { if case .working = self { return true } else { return false } }
}

/// What an agent asks, in its own words.
public struct AgentQuestion: Codable, Equatable, Hashable, Sendable {
    /// The question, or what it wants permission for.
    public var text: String
    /// The choices it offers, when the agent says which. Empty when it does
    /// not: then the session is opened to answer.
    public var choices: [String]

    public init(text: String, choices: [String] = []) {
        self.text = text
        self.choices = choices
    }
}
