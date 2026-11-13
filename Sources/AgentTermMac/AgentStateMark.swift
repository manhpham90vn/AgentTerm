import AgentTermProtocol
import SwiftUI

/// What the agent in a session is doing, as a mark next to its name (#3):
/// working, waiting for permission or for an answer, done. Nothing when it
/// is not known. When something keeps it from being known, a mark that says
/// why when the pointer rests on it.
struct AgentStateMark: View {
    let session: SessionInfo

    var body: some View {
        if let state = session.state {
            Image(systemName: Self.symbol(for: state))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Self.color(for: state))
                .help(Self.help(for: state))
                .accessibilityLabel(state.name)
                .accessibilityIdentifier("state-\(session.id)")
        } else if let note = session.stateNote {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .help(note)
                .accessibilityLabel(note)
                .accessibilityIdentifier("state-note-\(session.id)")
        }
    }

    static func symbol(for state: AgentState) -> String {
        switch state {
        case .working: return "circle.dotted"
        case .waitingForPermission: return "hand.raised.fill"
        case .waitingForAnswer: return "questionmark.bubble.fill"
        case .done: return "checkmark.circle.fill"
        }
    }

    static func color(for state: AgentState) -> Color {
        switch state {
        case .working: return .blue
        case .waitingForPermission, .waitingForAnswer: return .orange
        case .done: return .green
        }
    }

    /// What the agent asks, or said last, under its state's name.
    static func help(for state: AgentState) -> String {
        switch state {
        case .working(let since): return "Working since \(since.formatted(date: .omitted, time: .shortened))"
        case .waitingForPermission(let question): return "Waiting for permission: \(question.text)"
        case .waitingForAnswer(let question):
            return "Waiting for an answer: \(question.text)" + (question.choices.isEmpty ? "" : "\n" + question.choices.joined(separator: " · "))
        case .done(let said): return "Done" + (said.map { ": \($0)" } ?? "")
        }
    }

    /// The label a session is read with, its state after its name.
    static func label(_ name: String, _ session: SessionInfo) -> String {
        session.state.map { "\(name), \($0.name)" } ?? name
    }
}
