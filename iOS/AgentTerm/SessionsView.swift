import AgentTermProtocol
import AgentTermTelemetry
import AgentTermTerminal
import SwiftUI
import UniformTypeIdentifiers

/// The paired Mac's folders and the sessions running in them.
struct SessionsView: View {
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        NavigationStack(path: $model.path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if model.status != .connected {
                        StatusCard()
                    } else if model.hostMatch != .same {
                        VersionCard(match: model.hostMatch)
                    }
                    if model.status == .connected {
                        // Said in words, rather than shown as a list that
                        // emptied: the host on the Mac stopped, and its
                        // sessions ended with it.
                        ForEach(model.failures) { failure in
                            FailureCard(failure: failure)
                        }
                    }
                    if model.status == .connected {
                        // How the Mac is doing: the Mac this phone is
                        // connected to, not the phone itself.
                        SystemStatsPanel(store: model.system, large: true) { figures in
                            figures
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.panel))
                        }
                    }
                    if model.status == .connected && !model.sessionsKnown {
                        // Connected, and the Mac has not said yet what is on it.
                        LoadingView("Loading the sessions…").frame(height: 120)
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
                    // Back to the list of Macs, to look at another one.
                    Button {
                        model.showMacs()
                    } label: {
                        Image(systemName: "desktopcomputer")
                    }
                    .accessibilityLabel("Macs")
                    .accessibilityIdentifier("mac-menu")
                }
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
                }
            }
            .sheet(isPresented: $model.showBrowser) {
                BrowseSheet()
                    .environmentObject(model)
                    .preferredColorScheme(.dark)
            }
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

/// A part of AgentTerm on the Mac that stopped without being asked to.
private struct FailureCard: View {
    @EnvironmentObject private var model: PhoneModel
    let failure: PartFailure

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(failure.headline(on: model.pairing?.name ?? "the Mac"))
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(failure.details)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("failure-card")
            Spacer(minLength: 0)
            Button("Dismiss") { model.dismiss(failure) }
                .font(.footnote.weight(.semibold))
                .accessibilityIdentifier("failure-dismiss")
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.orange.opacity(0.12)))
    }
}

/// What AgentTerm reports to its developer, and the switches for it.
/// Which agent writes commit messages on the Mac, and how it is asked: the
/// same settings as the Mac's Settings > Git, kept by the Mac.
struct CommitWriterSheet: View {
    @EnvironmentObject private var model: PhoneModel
    @Environment(\.dismiss) private var dismiss
    @State private var agent = ""
    @State private var modelName = ""
    @State private var prompt = ""

    private var writerID: String? { CommitWriterSettings(agent: agent.isEmpty ? nil : agent).writer(among: model.agents)?.id }

    private func save() {
        let name = modelName.trimmingCharacters(in: .whitespaces)
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        model.setCommitWriter(
            CommitWriterSettings(
                agent: agent.isEmpty ? nil : agent, model: name.isEmpty ? nil : name,
                prompt: text.isEmpty || text == CommitWriterSettings.defaultPrompt ? nil : text))
        dismiss()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(
                        "Agent",
                        selection: Binding(
                            get: { agent },
                            set: {
                                // A model belongs to an agent: another agent starts on its own.
                                if $0 != agent { modelName = "" }
                                agent = $0
                            })
                    ) {
                        Text(model.installedAgents.first.map { "First installed (\($0.name))" } ?? "First installed").tag("")
                        ForEach(model.installedAgents) { agent in
                            Text(agent.name).tag(agent.id)
                        }
                        // One that was chosen and is gone since still has to
                        // be among the choices, or the picker shows none.
                        if !agent.isEmpty, !model.installedAgents.contains(where: { $0.id == agent }) {
                            Text("\(model.agents.first { $0.id == agent }?.name ?? agent) (not installed)").tag(agent)
                        }
                    }
                    TextField(writerID.flatMap(CommitWriterSettings.defaultModel) ?? "Agent's default model", text: $modelName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("commit-writer-model")
                } footer: {
                    Text("The Write button of a folder's Git tab asks this agent, on the Mac, for the message of what is staged. It never commits by itself.")
                }
                Section {
                    TextEditor(text: $prompt)
                        .frame(minHeight: 180)
                        .font(.callout)
                        .accessibilityIdentifier("commit-writer-prompt")
                    Button("Reset to Default") { prompt = CommitWriterSettings.defaultPrompt }
                        .disabled(prompt == CommitWriterSettings.defaultPrompt)
                } header: {
                    Text("Prompt")
                } footer: {
                    Text("What the agent is told, before the staged changes. Say here which style and language you want.")
                }
            }
            .navigationTitle("Commit Messages")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDismissButton()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
            }
            .onAppear {
                agent = model.commitWriter.agent ?? ""
                modelName = model.commitWriter.model ?? ""
                prompt = model.commitWriter.effectivePrompt
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
                if let path = group.path {
                    // One way in to what the Mac's side panel holds for the
                    // folder. Its screen has the tabs: Git, History, Files.
                    NavigationLink(value: Route.folder(path)) {
                        HStack(spacing: 12) {
                            Image(systemName: "square.stack.3d.up")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Palette.tint)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Changes, History and Files")
                                    .font(.body)
                                    .lineLimit(1)
                                Text("Commit and push, past conversations, edit files")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Changes, History and Files of \(group.name)")
                    .accessibilityIdentifier("folder-details")
                    Palette.hairline.frame(height: 1)
                }
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
                LaunchGrid(folder: group.path)
                    .padding(.horizontal, 6)
                    .padding(.top, 12)
                    .padding(.bottom, 10)
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
