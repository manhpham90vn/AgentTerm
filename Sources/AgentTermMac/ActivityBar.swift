import AgentTermProtocol
import AppKit
import SwiftUI

/// The bar at the window's left edge: Sessions, History, Schedules and
/// Settings, the window's places, as the iPhone's tabs are. The place shown hides
/// its list when pressed again.
struct ActivityBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 4) {
            item(.sessions, "Sessions", "terminal")
            item(.history, "History", "clock.arrow.circlepath")
            item(.schedules, "Schedules", "calendar.badge.clock")
            Spacer(minLength: 0)
            item(.settings, "Settings", "gearshape")
        }
        .padding(.vertical, 8)
        .frame(width: 46)
        .frame(maxHeight: .infinity)
        .background(Theme.activityBar)
    }

    private func item(_ place: AppModel.Place, _ title: String, _ symbol: String) -> some View {
        ActivityBarItem(
            title: title, symbol: symbol, selected: model.place == place, listShown: model.showSidebar,
            shortcut: place == .settings ? " (⌘,)" : ""
        ) { model.show(place) }
        .accessibilityIdentifier("place-\(place.rawValue)")
    }
}

private struct ActivityBarItem: View {
    let title: String
    let symbol: String
    let selected: Bool
    let listShown: Bool
    let shortcut: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(selected ? Color.primary : (hovering ? Color.primary.opacity(0.85) : Color.secondary))
                .frame(width: 46, height: 40)
                .overlay(alignment: .leading) {
                    // Which place is shown, as VS Code marks it.
                    if selected { Rectangle().fill(Color.accentColor).frame(width: 2) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(selected && listShown ? "Hide the list of \(title)" : title + shortcut)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// History's list, every conversation of the folder in front or of the Mac.
struct HistorySidebar: View {
    var body: some View {
        VStack(spacing: 0) {
            SidebarTitle("HISTORY")
            HistoryView()
        }
        .background(Theme.panel)
    }
}

/// Settings' panes, the one shown in the middle of the window.
struct SettingsSections: View {
    @EnvironmentObject private var model: AppModel

    static let panes: [(tag: String, title: String, symbol: String)] = [
        ("general", "General", "gearshape"), ("git", "Git", "arrow.triangle.branch"), ("permissions", "Permissions", "lock.shield"),
        ("privacy", "Privacy", "hand.raised"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarTitle("SETTINGS")
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Self.panes, id: \.tag) { pane in
                    SettingsSectionRow(title: pane.title, symbol: pane.symbol, selected: model.settingsTab == pane.tag) {
                        model.settingsTab = pane.tag
                    }
                    .accessibilityIdentifier("settings-\(pane.tag)")
                }
            }
            .padding(.horizontal, 8)
            Spacer(minLength: 0)
        }
        .background(Theme.panel)
    }
}

private struct SettingsSectionRow: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? .primary : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selected ? Color.white.opacity(0.11) : (hovering ? Color.white.opacity(0.05) : .clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The pane of Settings chosen in its list, in the middle of the window.
struct SettingsPane: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            switch model.settingsTab {
            case "git": ScrollView { GitSettingsView() }
            case "permissions": ScrollView { PermissionsView() }
            case "privacy": ScrollView { PrivacySettingsView() }
            default: SettingsView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.canvas)
    }
}

/// The small capitals at the top of a list in the sidebar.
struct SidebarTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        HStack {
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }
}

/// The conversation picked in History, in the middle of the window, as the
/// iPhone shows one: whose it is, where it ran, and what can be done with
/// it.
struct ConversationDetail: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            // Only one that is still listed: a refresh may have dropped it.
            if let picked = model.historySelection, let conversation = model.history?.first(where: { $0.id == picked.id }) ?? Optional(picked) {
                ScrollView {
                    ConversationCard(conversation: conversation)
                        .padding(28)
                        .frame(maxWidth: 680, alignment: .topLeading)
                        .frame(maxWidth: .infinity)
                }
                .id(conversation.id)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 30)).foregroundStyle(.tertiary)
                    Text("Choose a conversation").font(.system(size: 14, weight: .semibold))
                    Text("Resume it, or hand it off to another agent.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.canvas)
    }

}

/// A past conversation, whose it is, where it ran, and what can be done
/// with it: in History's middle, or in a sheet over Sessions when picked in
/// the side panel.
struct ConversationCard: View {
    @EnvironmentObject private var model: AppModel
    let conversation: Conversation
    @State private var copied = false

    var body: some View {
        let name = model.agents.first { $0.id == conversation.agent }?.name ?? conversation.agent
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Circle().fill(Theme.accent(for: conversation.agent)).frame(width: 8, height: 8)
                    Text(name).font(.system(size: 12, weight: .semibold))
                    Text("· " + conversation.updatedAt.formatted(.relative(presentation: .named)))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Text(conversation.title)
                    .font(.system(size: 18, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Label((conversation.cwd as NSString).abbreviatingWithTildeInPath, systemImage: "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            HStack(spacing: 10) {
                Button {
                    model.resume(conversation)
                    model.panelConversation = nil
                    model.show(.sessions, toggling: false)
                } label: {
                    Label("Resume in \(name)", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .help("Continue this conversation in a new session")
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(conversation.resumeCommand, forType: .string)
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy Resume Command", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .help(conversation.resumeCommand)
            }
            Theme.hairline.frame(height: 1)
            HandoffSheet(conversation: conversation, inline: true)
        }
    }
}

/// A conversation picked in the side panel's History, over Sessions.
struct ConversationSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let conversation: Conversation

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding([.horizontal, .top], 14)
            ScrollView {
                ConversationCard(conversation: conversation)
                    .padding(.horizontal, 26)
                    .padding(.bottom, 24)
            }
        }
        .frame(width: 600, height: 740)
    }
}
