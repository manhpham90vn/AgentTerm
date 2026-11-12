import AgentTermProtocol
import AgentTermTerminal
import SwiftUI

/// What can be started in a folder, as one row of round buttons: the
/// agents installed on the Mac, a shell, and the Mac's SSH hosts. They share
/// the width between them, so all of them are in view with nothing to scroll.
struct LaunchGrid: View {
    @EnvironmentObject private var model: PhoneModel
    let folder: String?
    /// Said after "Start Claude Code" to assistive tools: " here" in the folder picker.
    var labelSuffix = ""
    /// SSH sessions do not belong to a folder, so the folder picker leaves them out.
    var showsSSH = true

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(model.installedAgents) { agent in
                Button {
                    model.launch(agent, in: folder)
                } label: {
                    item(Self.shortName(agent), id: agent.id)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Start \(agent.name)\(labelSuffix)")
            }
            Button {
                model.launch(nil, in: folder)
            } label: {
                item("Shell", id: "shell")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Start Shell\(labelSuffix)")
            if showsSSH, !model.sshHosts.isEmpty {
                // The hosts of the Mac's SSH configuration: the session
                // runs on the Mac, which is the way to that host.
                Menu {
                    Section("Hosts in the Mac's ~/.ssh/config") {
                        ForEach(model.sshHosts, id: \.self) { host in
                            Button(host) { model.connectSSH(host) }
                        }
                    }
                } label: {
                    item("SSH", id: "ssh")
                }
                .foregroundStyle(.primary)
                .accessibilityLabel("Start SSH")
                .accessibilityIdentifier("ssh-menu")
            }
        }
        .disabled(model.status != .connected)
        .opacity(model.status == .connected ? 1 : 0.45)
    }

    /// The first word of an agent's name, which is what fits under a
    /// button: "Claude", "Codex", "Antigravity", "Copilot".
    static func shortName(_ agent: AgentInfo) -> String {
        agent.name.split(separator: " ").first.map(String.init) ?? agent.name
    }

    /// One thing to start: its symbol in a circle of its own color, over its name.
    private func item(_ title: String, id: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: AgentStyle.symbol(for: id))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(AgentStyle.accent(for: id))
                .frame(width: 44, height: 44)
                .background(Circle().fill(AgentStyle.accent(for: id).opacity(0.15)))
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}
