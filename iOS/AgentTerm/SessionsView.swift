import AgentTermProtocol
import AgentTermTelemetry
import AgentTermTerminal
import SwiftUI
import UniformTypeIdentifiers

/// The paired Mac's folders and the sessions running in them.
struct SessionsView: View {
    @EnvironmentObject private var model: PhoneModel
    @State private var confirmingForget = false
    @State private var showingPrivacy = false

    var body: some View {
        NavigationStack(path: $model.path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if model.status != .connected {
                        StatusCard()
                    } else if model.hostMatch != .same {
                        VersionCard(match: model.hostMatch)
                    }
                    ForEach(model.groups) { group in
                        FolderSection(group: group)
                    }
                    if model.status == .connected {
                        // Any folder on the Mac, not only the listed ones.
                        Button {
                            model.showBrowser = true
                        } label: {
                            Label("Open Another Folder…", systemImage: "folder.badge.plus")
                                .font(.subheadline.weight(.medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline))
                        }
                    }
                    if model.status == .connected && model.folders.isEmpty {
                        Text("Add project folders in AgentTerm on your Mac and they show up here.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                    }
                    if model.status == .connected && model.agentsLoaded && model.installedAgents.isEmpty {
                        Text("No agent CLI was found on the Mac. You can still open a shell.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                    }
                    Text("\(AppVersion.label) · protocol \(agenttermProtocolVersion)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                        .accessibilityIdentifier("app-version")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(Palette.canvas.ignoresSafeArea())
            .navigationTitle(model.pairing?.name ?? "AgentTerm")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        // Every paired Mac, to switch between them.
                        Section("Macs") {
                            ForEach(model.hosts) { host in
                                Button {
                                    model.select(host)
                                } label: {
                                    Label(host.name, systemImage: host.id == model.pairing?.id ? "checkmark" : "desktopcomputer")
                                }
                            }
                            Button {
                                model.showPairSheet = true
                            } label: {
                                Label("Pair Another Mac…", systemImage: "plus")
                            }
                        }
                        NavigationLink(value: Route.allHistory) { Label("All Conversations", systemImage: "clock.arrow.circlepath") }
                        Button {
                            model.refreshAgents()
                        } label: {
                            Label("Check Agents Again", systemImage: "arrow.clockwise")
                        }
                        if let keepAwake = model.keepAwake {
                            // The same switch as in the Mac's Settings.
                            Toggle(isOn: Binding(get: { keepAwake }, set: { model.setKeepAwake($0) })) {
                                Label("Keep Mac Awake", systemImage: "cup.and.saucer")
                            }
                        }
                        Button {
                            showingPrivacy = true
                        } label: {
                            Label("Privacy…", systemImage: "hand.raised")
                        }
                        Button(role: .destructive) {
                            confirmingForget = true
                        } label: {
                            Label("Forget This Mac", systemImage: "xmark.circle")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityIdentifier("mac-menu")
                }
            }
            .sheet(isPresented: $model.showPairSheet) {
                NavigationStack {
                    PairView(addingAnother: true)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") { model.showPairSheet = false }
                            }
                        }
                }
                .environmentObject(model)
                .preferredColorScheme(.dark)
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .session(let id):
                    TerminalScreen(session: id)
                case .folder(let folder):
                    FolderScreen(folder: folder)
                case .file(let folder, let file, let staged):
                    PatchScreen(folder: folder, file: file, staged: staged)
                case .document(let path):
                    DocumentScreen(path: path)
                case .allHistory:
                    HistoryList(folder: nil)
                        .background(Palette.canvas.ignoresSafeArea())
                        .navigationTitle("All Conversations")
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
            .sheet(isPresented: $showingPrivacy) {
                PrivacySheet().preferredColorScheme(.dark)
            }
            .sheet(isPresented: $model.showBrowser) {
                BrowseSheet()
                    .environmentObject(model)
                    .preferredColorScheme(.dark)
            }
            .confirmationDialog("Forget this Mac?", isPresented: $confirmingForget, titleVisibility: .visible) {
                Button("Forget", role: .destructive) { model.forgetMac() }
            } message: {
                Text("Sessions keep running on \(model.pairing?.name ?? "the Mac"). To connect again you pair with it once more.")
            }
        }
        // On the stack, not on the list inside it: a sheet or alert attached
        // to the list cannot appear while another screen, such as a
        // terminal, is on top of it.
        .sheet(item: $model.sessionHandoff) { conversation in
            ConversationSheet(conversation: conversation, showsResume: false)
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
        .alert("AgentTerm", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.message ?? "")
        }
    }
}

/// Shown when the Mac's AgentTerm and this app are of different versions.
private struct VersionCard: View {
    @EnvironmentObject private var model: PhoneModel
    let match: ProtocolMatch

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text(match == .hostOlder ? "AgentTerm on \(model.pairing?.name ?? "the Mac") is an older version" : "This app is older than AgentTerm on \(model.pairing?.name ?? "the Mac")")
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(
                    match == .hostOlder
                        ? "Update AgentTerm on the Mac. If it was just updated, restart its host there. Until then some things will not work."
                        : "Update this app to the version that goes with the Mac's. Until then some things will not work."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.yellow.opacity(0.12)))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("version-card")
    }
}

/// What AgentTerm reports to its developer, and the switches for it.
private struct PrivacySheet: View {
    @EnvironmentObject private var preferences: TelemetryPreferences
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Send crash reports", isOn: $preferences.crashReports)
                } footer: {
                    Text(TelemetryPreferences.Wording.questionDetail)
                }
                Section {
                    Toggle("Share usage statistics", isOn: $preferences.usageStatistics)
                } footer: {
                    Text(TelemetryPreferences.Wording.usageDetail)
                }
                if !preferences.isAvailable {
                    Section { Text(TelemetryPreferences.Wording.unavailable).font(.footnote).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Privacy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

private struct StatusCard: View {
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        HStack(spacing: 12) {
            if model.status == .connecting {
                ProgressView()
            } else {
                Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(model.status == .connecting ? "Connecting to your Mac…" : "Can't reach your Mac")
                    .font(.subheadline.weight(.semibold))
                if model.status != .connecting {
                    Text("Check that Tailscale is connected here and on the Mac, and that AgentTerm is open there.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if model.status != .connecting {
                Button("Retry") { model.retry() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.panel))
    }
}

private struct FolderSection: View {
    @EnvironmentObject private var model: PhoneModel
    let group: FolderGroup
    /// The folder a dragged folder is over.
    @State private var folderDropTarget: String?
    /// What a dragged session is over: a session's or a group's id.
    @State private var dropTarget: String?
    @State private var renaming: TabGroup?
    @State private var newName = ""

    @ViewBuilder
    private func arrangeMenu(_ session: SessionInfo) -> some View {
        let id = session.layoutID
        let layout = model.sessionLayout
        Button {
            withAnimation { model.sessionLayout.setPinned(id, !layout.isPinned(id)) }
        } label: {
            Label(layout.isPinned(id) ? "Unpin" : "Pin", systemImage: layout.isPinned(id) ? "pin.slash" : "pin")
        }
        Button {
            withAnimation { _ = model.sessionLayout.newGroup(with: id) }
        } label: {
            Label("Add to New Group", systemImage: "plus.rectangle.on.rectangle")
        }
        let others = layout.groups.filter { $0.id != layout.group(of: id)?.id }
        if !others.isEmpty {
            Menu {
                ForEach(others) { other in
                    Button(other.name.isEmpty ? "Group" : other.name) { withAnimation { model.sessionLayout.add(id, toGroup: other.id) } }
                }
            } label: {
                Label("Add to Group", systemImage: "rectangle.stack")
            }
        }
        if layout.group(of: id) != nil {
            Button {
                withAnimation { model.sessionLayout.removeFromGroup(id) }
            } label: {
                Label("Remove from Group", systemImage: "rectangle.stack.badge.minus")
            }
        }
        Button {
            withAnimation { model.move(session, by: -1, in: group) }
        } label: {
            Label("Move Up", systemImage: "arrow.up")
        }
        .disabled(!model.canMove(session, by: -1, in: group))
        Button {
            withAnimation { model.move(session, by: 1, in: group) }
        } label: {
            Label("Move Down", systemImage: "arrow.down")
        }
        .disabled(!model.canMove(session, by: 1, in: group))
    }

    private func groupLabel(_ tabGroup: TabGroup, count: Int) -> some View {
        let color = GroupColor.color(tabGroup.color)
        return Button {
            withAnimation { model.sessionLayout.toggleCollapsed(tabGroup.id) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: tabGroup.isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 18)
                Text(tabGroup.name.isEmpty ? "Group" : tabGroup.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text("\(count)").font(.system(size: 12, design: .monospaced)).opacity(0.7)
                Spacer(minLength: 0)
            }
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(color.opacity(dropTarget == tabGroup.id ? 0.3 : 0.12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Group \(tabGroup.name), \(count) sessions" + (tabGroup.isCollapsed ? ", collapsed" : ""))
        .accessibilityIdentifier("session-group")
        .contextMenu {
            Button {
                newName = tabGroup.name
                renaming = tabGroup
            } label: {
                Label("Rename Group…", systemImage: "pencil")
            }
            // A picker, so the menu ticks the color in use. The dots are
            // images with their own color; a menu tints symbols otherwise.
            Picker(selection: Binding(get: { tabGroup.color }, set: { model.sessionLayout.setColor($0, of: tabGroup.id) })) {
                ForEach(TabLayout.colors, id: \.self) { name in
                    Label {
                        Text(name.capitalized)
                    } icon: {
                        Image(uiImage: GroupColor.swatch(name))
                    }.tag(name)
                }
            } label: {
                Label("Color", systemImage: "paintpalette")
            }
            .pickerStyle(.menu)
            Button {
                withAnimation { model.sessionLayout.ungroup(tabGroup.id) }
            } label: {
                Label("Ungroup", systemImage: "rectangle.stack.badge.minus")
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: group.path == nil ? "house.fill" : "folder.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.tint)
                Text(group.name)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                    .accessibilityIdentifier("folder-name")
                Spacer(minLength: 0)
                if let path = group.path {
                    // The folder's git changes and conversations, as in the
                    // Mac's side panel.
                    NavigationLink(value: Route.folder(path)) {
                        HStack(spacing: 4) {
                            Text("Git, History, Files")
                            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                        }
                        .font(.footnote.weight(.medium))
                    }
                    .accessibilityIdentifier("folder-details")
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .overlay(alignment: .top) {
                // Where a dragged folder will land.
                if let path = group.path, folderDropTarget == path { Palette.tint.frame(height: 2.5).offset(y: -6) }
            }
            .modifier(FolderArranging(path: group.path, dropTarget: $folderDropTarget))

            VStack(spacing: 0) {
                ForEach(model.items(for: group)) { item in
                    switch item {
                    case .label(let tabGroup, let count):
                        groupLabel(tabGroup, count: count)
                            .onDrop(of: [.text], delegate: SessionDropDelegate(place: .group(tabGroup.id), model: model, dropTarget: $dropTarget))
                        Palette.hairline.frame(height: 1)
                    case .session(let session):
                        NavigationLink(value: Route.session(session.id)) {
                            SessionRow(session: session)
                        }
                        .buttonStyle(.plain)
                        .overlay(alignment: .top) {
                            // Where a dragged session will land.
                            if dropTarget == session.layoutID { Palette.tint.frame(height: 2.5) }
                        }
                        .onDrag {
                            model.draggedFolder = nil
                            model.draggedSession = session.layoutID
                            return NSItemProvider(object: session.layoutID as NSString)
                        }
                        .onDrop(of: [.text], delegate: SessionDropDelegate(place: .before(session.layoutID), model: model, dropTarget: $dropTarget))
                        .contextMenu {
                            arrangeMenu(session)
                            Divider()
                            if model.canHandOff(session) {
                                Button {
                                    model.requestHandoff(session: session)
                                } label: {
                                    Label("Hand Off…", systemImage: "arrowshape.turn.up.right")
                                }
                            }
                            Button(role: .destructive) {
                                model.end(session.id)
                            } label: {
                                Label("End Session", systemImage: "xmark.circle")
                            }
                        }
                        Palette.hairline.frame(height: 1).padding(.leading, 38)
                    }
                }
                LaunchRow(folder: group.path)
            }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.panel))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .alert("Rename Group", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Rename") { if let renaming { model.sessionLayout.rename(renaming.id, to: newName) } }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}

private struct SessionRow: View {
    @EnvironmentObject private var model: PhoneModel
    let session: SessionInfo

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: AgentStyle.symbol(for: model.agentID(for: session)))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AgentStyle.accent(for: model.agentID(for: session)))
                .frame(width: 18)
            if model.sessionLayout.isPinned(session.layoutID) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Pinned")
            }
            // The conversation's title once the agent has saved one, the
            // agent's name until then.
            Text(session.displayName)
                .font(.body)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text("\(session.size.cols)×\(session.size.rows)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.tertiary)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .overlay(alignment: .leading) {
            // The color of the group the session is in.
            if let tabGroup = model.sessionLayout.group(of: session.layoutID) {
                GroupColor.color(tabGroup.color).frame(width: 3)
            }
        }
    }
}

/// A listed folder's heading can be dragged onto another's, to go before
/// it, and has a menu to move it a place up or down or take it off the list.
private struct FolderArranging: ViewModifier {
    @EnvironmentObject private var model: PhoneModel
    let path: String?
    @Binding var dropTarget: String?

    func body(content: Content) -> some View {
        if let path, model.folders.contains(path) {
            content
                .onDrag {
                    model.draggedSession = nil
                    model.draggedFolder = path
                    return NSItemProvider(object: path as NSString)
                }
                .onDrop(of: [.text], delegate: FolderDropDelegate(before: path, model: model, dropTarget: $dropTarget))
                .contextMenu {
                    Button {
                        model.moveFolder(path, by: -1)
                    } label: {
                        Label("Move Up", systemImage: "arrow.up")
                    }
                    .disabled(!model.canMoveFolder(path, by: -1))
                    Button {
                        model.moveFolder(path, by: 1)
                    } label: {
                        Label("Move Down", systemImage: "arrow.down")
                    }
                    .disabled(!model.canMoveFolder(path, by: 1))
                    Button(role: .destructive) {
                        model.removeFolder(path)
                    } label: {
                        Label("Remove from List", systemImage: "minus.circle")
                    }
                }
        } else {
            content
        }
    }
}

private struct FolderDropDelegate: DropDelegate {
    let before: String
    let model: PhoneModel
    @Binding var dropTarget: String?

    func validateDrop(info: DropInfo) -> Bool { model.draggedFolder != nil }

    func dropEntered(info: DropInfo) {
        if model.draggedFolder != before { dropTarget = before }
    }

    func dropExited(info: DropInfo) {
        if dropTarget == before { dropTarget = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dropTarget = nil
        guard let path = model.draggedFolder else { return false }
        model.draggedFolder = nil
        model.moveFolder(path, before: before)
        return true
    }
}

/// A session dragged in the list is dropped on another, to go before it and
/// take on its place (pinned, or in its group), or on a group's label, to join it.
private struct SessionDropDelegate: DropDelegate {
    enum Place {
        case before(String), group(String)

        var key: String {
            switch self {
            case .before(let id), .group(let id): return id
            }
        }
    }

    let place: Place
    let model: PhoneModel
    @Binding var dropTarget: String?

    func validateDrop(info: DropInfo) -> Bool { model.draggedSession != nil }

    func dropEntered(info: DropInfo) {
        if case .before(let id) = place, id == model.draggedSession { return }
        dropTarget = place.key
    }

    func dropExited(info: DropInfo) {
        if dropTarget == place.key { dropTarget = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dropTarget = nil
        guard let id = model.draggedSession else { return false }
        model.draggedSession = nil
        withAnimation {
            switch place {
            case .before(let target): model.sessionLayout.move(id, before: target)
            case .group(let group): model.sessionLayout.add(id, toGroup: group)
            }
        }
        return true
    }
}

enum GroupColor {
    static func swatch(_ name: String) -> UIImage {
        (UIImage(systemName: "circle.fill") ?? UIImage()).withTintColor(UIColor(color(name)), renderingMode: .alwaysOriginal)
    }

    static func color(_ name: String) -> Color {
        switch name {
        case "blue": return Color(red: 0.36, green: 0.58, blue: 0.98)
        case "green": return Color(red: 0.36, green: 0.78, blue: 0.50)
        case "orange": return Color(red: 0.96, green: 0.62, blue: 0.30)
        case "red": return Color(red: 0.94, green: 0.42, blue: 0.44)
        case "purple": return Color(red: 0.68, green: 0.52, blue: 0.96)
        case "teal": return Color(red: 0.30, green: 0.76, blue: 0.76)
        case "pink": return Color(red: 0.95, green: 0.50, blue: 0.74)
        default: return Color(white: 0.62)
        }
    }
}

/// One tap starts an agent in this folder.
private struct LaunchRow: View {
    @EnvironmentObject private var model: PhoneModel
    let folder: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.installedAgents) { agent in
                    chip(title: agent.name, id: agent.id) { model.launch(agent, in: folder) }
                }
                chip(title: "Shell", id: "shell") { model.launch(nil, in: folder) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
        .disabled(model.status != .connected)
        .opacity(model.status == .connected ? 1 : 0.45)
    }

    private func chip(title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: AgentStyle.symbol(for: id))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AgentStyle.accent(for: id))
                Text(title)
                    .font(.system(size: 14, weight: .medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(Palette.raised))
            .overlay(Capsule().strokeBorder(Palette.hairline))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Start \(title)")
    }
}
