import AgentTermHost
import AgentTermProtocol
import AppKit
import SwiftUI

/// Asks who should take over a conversation and what they should know.
struct HandoffSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let conversation: Conversation
    /// In the middle of the window, under a conversation picked in History,
    /// rather than in a sheet: no Cancel, and handing off goes to Sessions.
    var inline = false

    /// The agent picked last time is offered first.
    @AppStorage("handoffTarget") private var rememberedTarget = ""
    @State private var targetID = ""
    @State private var note = ""
    /// Made once when the sheet opens, so the file named in the prompt is
    /// the file that gets written.
    @State private var plan: Handoff.Plan?
    /// On another Mac the plan is that Mac's host's: this names it.
    @State private var remotePlan: String?
    @State private var prompt = ""
    @FocusState private var noteFocused: Bool

    private var promptIsEdited: Bool { plan.map { prompt != $0.prompt } ?? false }

    /// Where the receiving agent starts. Empty means the conversation's folder.
    @State private var folder = ""

    private var destination: String { folder.isEmpty ? conversation.cwd : folder }
    /// The conversation's own folder first, then the other listed ones.
    /// Repositories directly inside the conversation's folder. An agent that
    /// was started in a folder of projects usually worked in one of them,
    /// and that is where it is most useful to carry on.
    @State private var nested: [String] = []
    /// A folder picked with "Choose…".
    @State private var chosen: String?
    /// The other Mac's folders, picked from its listing.
    @State private var browsing = false

    /// The conversation's own folder first, then the repositories inside it,
    /// the other listed folders, and one picked by hand.
    private var folderChoices: [String] {
        var paths = [conversation.cwd]
        let inside = model.isRemote ? model.repositories[conversation.cwd] ?? [] : nested
        for path in inside + model.folders.map(\.path) + [chosen].compactMap({ $0 }) where !paths.contains(path) { paths.append(path) }
        return paths
    }

    private func label(for path: String) -> String {
        if path == conversation.cwd { return (path as NSString).lastPathComponent + " (this conversation's folder)" }
        if path.hasPrefix(conversation.cwd + "/") { return (conversation.cwd as NSString).lastPathComponent + "/" + path.dropFirst(conversation.cwd.count + 1) }
        return (path as NSString).abbreviatingWithTildeInPath
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: destination)
        panel.prompt = "Choose"
        panel.message = "Choose the folder the agent continues in"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.standardizedFileURL.path
        chosen = path == conversation.cwd ? nil : path
        folder = path == conversation.cwd ? "" : path
    }

    /// The folders right under `directory` that are git repositories, by name.
    private static func repositories(in directory: String) -> [String] {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: directory)) ?? []).prefix(400)
        return names.filter { !$0.hasPrefix(".") }.map { directory + "/" + $0 }
            .filter { fm.fileExists(atPath: $0 + "/.git") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    private var targets: [AgentInfo] { model.handoffTargets(from: conversation.agent, sameFolder: destination == conversation.cwd) }
    private var target: AgentInfo? { targets.first { $0.id == targetID } ?? targets.first }
    private var sourceName: String { model.agents.first { $0.id == conversation.agent }?.name ?? conversation.agent }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if inline {
                Text("Hand Off to Another Agent")
                    .font(.system(size: 14, weight: .semibold))
            } else {
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
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Continue in")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Picker("Folder", selection: $folder) {
                        ForEach(folderChoices, id: \.self) { path in
                            Text(label(for: path)).tag(path == conversation.cwd ? "" : path)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("The folder the receiving agent starts in")
                    // An open panel shows this Mac's disk; another Mac's is
                    // browsed through its host.
                    Button("Choose…") { if model.isRemote { browsing = true } else { chooseFolder() } }
                        .controlSize(.small)
                        .help("Start it in any other folder")
                }
                if destination != conversation.cwd {
                    Text("The agent starts in \((destination as NSString).abbreviatingWithTildeInPath), with the conversation so far. The folder is added to the list.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
                if targets.isEmpty {
                    Text("No other agent is installed to hand this off to.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
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
                if plan == nil {
                    // Another Mac's host works it out.
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Preparing the handoff…").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 86)
                } else {
                    editor($prompt, height: 86)
                }
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
                if !inline {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                // Return adds a line in the instructions, so sending is Command-Return.
                Button("Hand Off") { submit() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(target == nil || plan == nil)
                    .help("Hand off (⌘↩)")
            }
        }
        .padding(inline ? 0 : 22)
        .frame(width: inline ? nil : 500)
        .onAppear {
            targetID = targets.contains { $0.id == rememberedTarget } ? rememberedTarget : (targets.first?.id ?? "")
            noteFocused = !inline
            if model.isRemote {
                // The folders and the handoff file are on the other Mac.
                model.requestRemoteHandoffPlan(for: conversation)
                model.askRepositories(in: conversation.cwd)
                return
            }
            nested = Self.repositories(in: conversation.cwd)
            let made = Handoff.plan(for: conversation)
            plan = made
            prompt = made.prompt
        }
        .sheet(isPresented: $browsing) {
            BrowseFoldersSheet(
                onPick: { path in
                    chosen = path == conversation.cwd ? nil : path
                    folder = path == conversation.cwd ? "" : path
                }, start: destination, pickTitle: "Continue Here")
        }
        .onChange(of: model.remoteHandoffPlan) { _, made in
            guard model.isRemote, let made, plan == nil else { return }
            remotePlan = made.id
            plan = Handoff.Plan(relativePath: "", prompt: made.prompt)
            prompt = made.prompt
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
        if model.isRemote {
            guard let remotePlan else { return }
            model.handoffOnRemote(
                conversation, to: target, plan: remotePlan, prompt: promptIsEdited ? prompt : nil, note: note, in: folder.isEmpty ? nil : folder)
            done()
            return
        }
        model.handoff(conversation, to: target, plan: plan, prompt: prompt, note: note, in: folder.isEmpty ? nil : folder)
        done()
    }

    /// The receiving agent's session is what is looked at next.
    private func done() {
        if inline {
            model.panelConversation = nil
            model.show(.sessions, toggling: false)
        } else {
            dismiss()
        }
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
