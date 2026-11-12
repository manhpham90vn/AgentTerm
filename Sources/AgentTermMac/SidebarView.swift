import AgentTermProtocol
import AgentTermTerminal
import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    /// What a dragged folder is over: a folder's path, or "end".
    @State private var dropTarget: String?

    var body: some View {
        VStack(spacing: 0) {
            MacSwitcher()
                .padding(.horizontal, 14)
                .padding(.top, 12)
            HStack {
                Text("FOLDERS")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.addFolder()
                } label: {
                    Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Add a folder")
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.folders) { folder in
                        FolderRow(folder: folder)
                            .overlay(alignment: .top) {
                                // Where a dragged folder will land.
                                if dropTarget == folder.path { Capsule().fill(Color.accentColor).frame(height: 2.5).padding(.horizontal, 2) }
                            }
                            .onDrag {
                                model.draggedTab = nil
                                model.draggedFolder = folder.path
                                // Plain data: a terminal does not take it for text to insert.
                                let provider = NSItemProvider()
                                provider.registerDataRepresentation(forTypeIdentifier: UTType.data.identifier, visibility: .ownProcess) { done in
                                    done(Data(folder.path.utf8), nil)
                                    return nil
                                }
                                return provider
                            }
                            .onDrop(of: [.data, .fileURL], delegate: FolderDropDelegate(before: folder.path, model: model, dropTarget: $dropTarget))
                        ForEach(model.sessions(in: folder)) { session in
                            SessionRow(session: session)
                                .modifier(SessionArranging(session: session, dropTarget: $dropTarget))
                        }
                    }
                    if !model.folders.isEmpty {
                        // Room under the last folder to drop one at the end.
                        Color.clear.frame(height: 18)
                            .overlay(alignment: .top) {
                                if dropTarget == "end" { Capsule().fill(Color.accentColor).frame(height: 2.5).padding(.horizontal, 2) }
                            }
                            .contentShape(Rectangle())
                            .onDrop(of: [.data, .fileURL], delegate: FolderDropDelegate(before: nil, model: model, dropTarget: $dropTarget))
                    }
                    if !model.looseSessions.isEmpty {
                        Text("OTHER")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.top, 14)
                            .padding(.bottom, 4)
                        ForEach(model.inTabOrder(model.looseSessions)) { session in
                            SessionRow(session: session, showsPath: true)
                                .modifier(SessionArranging(session: session, dropTarget: $dropTarget))
                        }
                    }
                    if model.folders.isEmpty && model.looseSessions.isEmpty {
                        Text("No folders yet.\nAdd one to keep its agents and changes together.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.top, 6)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }

            // Bottom left corner: the way into Settings, permissions included.
            Theme.hairline.frame(height: 1)
            SettingsLink { SettingsRowLabel() }
                .buttonStyle(.plain)
                .help("Settings and the permissions agents need (⌘,)")
                .padding(8)
        }
        .background(Theme.panel)
        // A folder dragged in from the Finder is added to the list.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            FolderDropDelegate.addFolders(from: providers, to: model)
        }
    }
}

/// A session in the list can be dragged onto another to go before it. That
/// is the same move as dragging its tab in the strip: it takes on the place
/// it lands in, pinned or in a group, and the phones see the new order.
private struct SessionArranging: ViewModifier {
    @EnvironmentObject private var model: AppModel
    let session: SessionInfo
    @Binding var dropTarget: String?

    private var id: String { TabID.session(session) }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if dropTarget == id { Capsule().fill(Color.accentColor).frame(height: 2.5).padding(.leading, 22).padding(.trailing, 2) }
            }
            .onDrag {
                model.draggedFolder = nil
                model.draggedTab = id
                let provider = NSItemProvider()
                provider.registerDataRepresentation(forTypeIdentifier: UTType.data.identifier, visibility: .ownProcess) { done in
                    done(Data(id.utf8), nil)
                    return nil
                }
                return provider
            }
            .onDrop(of: [.data], delegate: SessionRowDropDelegate(target: id, model: model, dropTarget: $dropTarget))
            .contextMenu {
                let shown = model.inTabOrder(model.sessions.filter { $0.cwd == session.cwd }).map(TabID.session)
                let index = shown.firstIndex(of: id)
                Button("Move Up") { if let index, index > 0 { model.moveTab(id, before: shown[index - 1]) } }
                    .disabled(index == nil || index == 0)
                Button("Move Down") { if let index, index < shown.count - 1 { model.tabLayout.move(id, after: shown[index + 1]) } }
                    .disabled(index == nil || index == shown.count - 1)
                Divider()
                Button(model.tabLayout.isPinned(id) ? "Unpin" : "Pin") { model.setTabPinned(id, !model.tabLayout.isPinned(id)) }
                Divider()
                Button("End Session") { model.close(session.id) }
            }
    }
}

private struct SessionRowDropDelegate: DropDelegate {
    let target: String
    let model: AppModel
    @Binding var dropTarget: String?

    func validateDrop(info: DropInfo) -> Bool { model.draggedTab != nil && model.draggedFolder == nil }

    func dropEntered(info: DropInfo) {
        if model.draggedTab != target { dropTarget = target }
    }

    func dropExited(info: DropInfo) {
        if dropTarget == target { dropTarget = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dropTarget = nil
        guard let id = model.draggedTab else { return false }
        model.draggedTab = nil
        withAnimation(.easeOut(duration: 0.15)) { model.moveTab(id, before: target) }
        return true
    }
}

/// A folder of the list dropped on another goes before it. A folder dragged
/// in from elsewhere, the Finder for one, is added.
private struct FolderDropDelegate: DropDelegate {
    /// The folder to go before; nil is the end of the list.
    let before: String?
    let model: AppModel
    @Binding var dropTarget: String?

    private var key: String { before ?? "end" }

    func validateDrop(info: DropInfo) -> Bool {
        model.draggedFolder != nil || (model.draggedTab == nil && info.hasItemsConforming(to: [.fileURL]))
    }

    func dropEntered(info: DropInfo) {
        if model.draggedFolder != nil, model.draggedFolder != before { dropTarget = key }
    }

    func dropExited(info: DropInfo) {
        if dropTarget == key { dropTarget = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: model.draggedFolder != nil ? .move : .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        dropTarget = nil
        if let path = model.draggedFolder {
            model.draggedFolder = nil
            model.moveFolder(path, before: before)
            return true
        }
        return Self.addFolders(from: info.itemProviders(for: [.fileURL]), to: model)
    }

    @discardableResult
    static func addFolders(from providers: [NSItemProvider], to model: AppModel) -> Bool {
        guard !providers.isEmpty else { return false }
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { model.addFolders([url]) }
            }
        }
        return true
    }
}

private struct RowBackground: ViewModifier {
    let selected: Bool
    let hovering: Bool

    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Color.white.opacity(0.11) : (hovering ? Color.white.opacity(0.05) : .clear))
        )
    }
}

struct FolderRow: View {
    @EnvironmentObject private var model: AppModel
    let folder: Folder
    @State private var hovering = false

    private var isSelected: Bool { model.selectedFolder == folder.path && model.selectedSession == nil }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "folder.fill")
                .font(.system(size: 12))
                .foregroundStyle(model.selectedFolder == folder.path ? Color.accentColor : .secondary)
            Text(folder.name)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .modifier(RowBackground(selected: isSelected, hovering: hovering))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            model.selectedFolder = folder.path
            // Jump to this folder's most recent session, or its launch screen.
            model.selectedSession = model.sessions.last { $0.cwd == folder.path }?.id
        }
        .help(folder.path)
        .contextMenu {
            // A folder of another Mac is not in this Mac's Finder.
            if !model.isRemote {
                Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path) }
                Divider()
            }
            Button("Move Up") { model.moveFolder(folder, by: -1) }
                .disabled(model.folders.first == folder)
            Button("Move Down") { model.moveFolder(folder, by: 1) }
                .disabled(model.folders.last == folder)
            Divider()
            Button("Remove from List") { model.remove(folder) }
        }
        .padding(.top, 4)
    }
}

struct SessionRow: View {
    @EnvironmentObject private var model: AppModel
    let session: SessionInfo
    var showsPath = false
    @State private var hovering = false

    private var agentID: String { session.agent ?? "shell" }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: Theme.symbol(for: agentID))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.accent(for: agentID))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                // The conversation's title once the agent has saved one,
                // the agent's name until then.
                Text(session.displayName)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if showsPath {
                    Text((session.cwd as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 0)
            if model.foreignSizes[session.id] != nil {
                Image(systemName: "iphone")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .help("Sized for another device")
            }
            if hovering, let agent = model.agentID(of: session), !model.handoffTargets(from: agent).isEmpty {
                Button {
                    model.requestHandoff(session: session)
                } label: {
                    Image(systemName: "arrowshape.turn.up.right.fill").font(.system(size: 9.5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Give this session's work to another agent")
            }
            if hovering {
                Button {
                    model.close(session.id)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("End this session")
            }
        }
        .padding(.leading, showsPath ? 8 : 24)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .modifier(RowBackground(selected: model.selectedSession == session.id, hovering: hovering))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.select(session: session) }
        .help(session.summary.map { "\(session.title): \($0)" } ?? session.title)
    }
}

/// The Settings row at the foot of the sidebar.
private struct SettingsRowLabel: View {
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.12)))
            Text("Settings")
                .font(.system(size: 13, weight: .medium))
            Spacer(minLength: 0)
            Text(AppVersion.current == "dev" ? "dev" : "v" + AppVersion.current)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .help("\(AppVersion.label), protocol \(agenttermProtocolVersion)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering ? Color.white.opacity(0.10) : Color.white.opacity(0.05))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
