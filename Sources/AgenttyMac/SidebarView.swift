import AgenttyProtocol
import AgenttyTerminal
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("FOLDERS")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button { model.addFolder() } label: {
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
                        ForEach(model.sessions(in: folder)) { session in
                            SessionRow(session: session)
                        }
                    }
                    if !model.looseSessions.isEmpty {
                        Text("OTHER")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.top, 14)
                            .padding(.bottom, 4)
                        ForEach(model.looseSessions) { session in
                            SessionRow(session: session, showsPath: true)
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
        }
        .background(Theme.panel)
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
            model.selectedSession = model.sessions(in: folder).last?.id
        }
        .help(folder.path)
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path) }
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

    private var agentID: String {
        model.agents.first { $0.name == session.title }?.id ?? "shell"
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Theme.accent(for: agentID))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
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
                Button { model.requestHandoff(session: session) } label: {
                    Image(systemName: "arrowshape.turn.up.right.fill").font(.system(size: 9.5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Give this session's work to another agent")
            }
            if hovering {
                Button { model.close(session.id) } label: {
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
    }
}
