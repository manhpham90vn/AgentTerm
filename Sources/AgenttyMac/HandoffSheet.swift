import AgenttyHost
import AgenttyProtocol
import SwiftUI

/// Asks who should take over a conversation and what they should know.
struct HandoffSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let conversation: Conversation

    /// The agent picked last time is offered first.
    @AppStorage("handoffTarget") private var rememberedTarget = ""
    @State private var targetID = ""
    @State private var note = ""
    /// Made once when the sheet opens, so the file named in the prompt is
    /// the file that gets written.
    @State private var plan: Handoff.Plan?
    @State private var prompt = ""
    @FocusState private var noteFocused: Bool

    private var promptIsEdited: Bool { plan.map { prompt != $0.prompt } ?? false }

    private var targets: [AgentInfo] { model.handoffTargets(from: conversation.agent) }
    private var target: AgentInfo? { targets.first { $0.id == targetID } ?? targets.first }
    private var sourceName: String { model.agents.first { $0.id == conversation.agent }?.name ?? conversation.agent }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Hand Off")
                    .font(.system(size: 17, weight: .semibold))
                HStack(spacing: 6) {
                    Circle().fill(Theme.accent(for: conversation.agent)).frame(width: 7, height: 7)
                    Text("\(sourceName) · \(conversation.title)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Continue with")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(targets) { agent in
                        TargetChip(agent: agent, selected: agent.id == target?.id) { targetID = agent.id }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Prompt \(target?.name ?? "the agent") starts with")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if promptIsEdited {
                        Button("Reset") { prompt = plan?.prompt ?? "" }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                            .help("Put the original prompt back")
                    }
                }
                editor($prompt, height: 86)
                Text("It can be edited. Keep the line that names the handoff file: that file has the conversation so far and the state of the working tree.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Your instructions (optional)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                editor($note, height: 92, placeholder: "What to focus on, what to leave alone, anything that is not in the conversation.")
                    .focused($noteFocused)
                Text("Added after the prompt. \(sourceName)'s session is left as it is.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                // Return adds a line in the instructions, so sending is Command-Return.
                Button("Hand Off") { submit() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(target == nil || plan == nil)
                    .help("Hand off (⌘↩)")
            }
        }
        .padding(22)
        .frame(width: 500)
        .onAppear {
            targetID = targets.contains { $0.id == rememberedTarget } ? rememberedTarget : (targets.first?.id ?? "")
            let made = Handoff.plan(for: conversation)
            plan = made
            prompt = made.prompt
            noteFocused = true
        }
    }

    private func editor(_ text: Binding<String>, height: CGFloat, placeholder: String = "") -> some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 5)
                .padding(.vertical, 8)
            if text.wrappedValue.isEmpty {
                Text(placeholder)
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.25)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }

    private func submit() {
        guard let target, let plan else { return }
        rememberedTarget = target.id
        model.handoff(conversation, to: target, plan: plan, prompt: prompt, note: note)
        dismiss()
    }
}

private struct TargetChip: View {
    let agent: AgentInfo
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: Theme.symbol(for: agent.id))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent(for: agent.id))
                Text(agent.name)
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Theme.accent(for: agent.id).opacity(0.18) : Theme.raised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? Theme.accent(for: agent.id).opacity(0.8) : Theme.hairline, lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
