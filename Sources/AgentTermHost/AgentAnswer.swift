#if os(macOS)
import AgentTermProtocol
import Foundation

/// How an answer given away from the session, in a notification's reply or
/// with one of its buttons (#22, #55), is typed into the agent's terminal.
///
/// An agent that asks a question with choices shows a list, with the first
/// choice marked, and takes Return as choosing the one that is marked. So
/// text and Return, which is right for a prompt, answers such a question
/// with its first choice whatever the text says. What each agent's list
/// takes was tried with the real agents (Claude Code 2.1, Copilot CLI,
/// Antigravity CLI 1.5): Down moves the mark and Return chooses; the row
/// after the last choice ("Type something.", "Other", "Write-in...") takes
/// an answer of the user's own, typed there and sent with Return, after a
/// Return of its own in Antigravity.
public enum AgentAnswer {
    static let down = "\u{1b}[B"

    /// What to type, in steps a moment apart, as a person types it: an
    /// agent takes text that arrives with its Return as pasted.
    ///
    /// - Parameters:
    ///   - agent: The agent's id, nil for another program.
    ///   - state: What the agent asks, which the answer is to.
    ///   - text: The answer: one of the question's choices, or the user's
    ///     own words.
    public static func steps(agent: String?, state: AgentState, text: String) -> [String] {
        guard case .waitingForAnswer(let question) = state, !question.choices.isEmpty, let agent, ["claude", "copilot", "agy"].contains(agent) else {
            return [text, "\r"]
        }
        let wanted = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let index =
            question.choices.firstIndex(of: wanted)
            ?? question.choices.firstIndex { $0.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(wanted) == .orderedSame }
        if let index {
            // The first choice is marked already.
            return (index == 0 ? [] : [String(repeating: down, count: index)]) + ["\r"]
        }
        // None of the choices: the row after them takes the user's own.
        let toOwn = String(repeating: down, count: question.choices.count)
        return [toOwn] + (agent == "agy" ? ["\r"] : []) + [text, "\r"]
    }
}
#endif
