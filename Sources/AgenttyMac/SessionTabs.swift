import AgenttyProtocol
import SwiftUI

/// Every running session and every open file as a tab above the middle pane,
/// to switch between them with one click or Command and a number.
struct SessionTabs: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var files: FilesModel

    var body: some View {
        if !model.sessions.isEmpty || !files.documents.isEmpty || model.diffTabFile != nil {
            HStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(Array(model.sessions.enumerated()), id: \.element.id) { index, session in
                                SessionTab(session: session, number: index + 1)
                                    .id("session-\(session.id)")
                            }
                            // Files come after the sessions and carry on their numbering.
                            ForEach(Array(files.documents.enumerated()), id: \.element.path) { index, document in
                                FileTab(document: document, number: model.sessions.count + index + 1)
                                    .id("file-" + document.path)
                            }
                            // One tab for the diff picked in the Git tab, last.
                            if let file = model.diffTabFile {
                                DiffTab(file: file, number: model.tabCount).id("diff")
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                    }
                    .onChange(of: model.selectedSession) { _, selected in
                        if let selected, files.active == nil { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("session-\(selected)") } }
                    }
                    .onChange(of: model.diffInFront) { _, front in
                        if front { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("diff") } }
                    }
                    .onChange(of: files.active) { _, path in
                        if let path { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("file-" + path) } }
                    }
                }
                Menu {
                    ForEach(model.installedAgents) { agent in
                        Button("New \(agent.name)") { model.launch(agent) }
                    }
                    Button("New Shell") { model.launch(nil) }
                } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .help("Start a session in \(model.workingDirectory)")
            }
            .background(Theme.panel)
            .overlay(alignment: .bottom) { Theme.hairline.frame(height: 1) }
        }
    }
}

private struct SessionTab: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var files: FilesModel
    let session: SessionInfo
    /// Place in the strip, counted from 1. The first nine have a shortcut.
    let number: Int
    @State private var hovering = false

    /// A file in front means no session's tab is the selected one.
    private var selected: Bool { model.selectedSession == session.id && files.active == nil && !model.diffInFront }
    private var agentID: String { session.agent ?? "shell" }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: Theme.symbol(for: agentID))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.accent(for: agentID))
            Text(session.displayName)
                .font(.system(size: 12, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 190, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            if model.foreignSizes[session.id] != nil {
                Image(systemName: "iphone").font(.system(size: 9.5)).foregroundStyle(.secondary)
            }
            // The close button takes the shortcut's place under the pointer,
            // so the tab does not change width.
            ZStack {
                if number <= 9 {
                    Text("⌘\(number)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .opacity(hovering ? 0 : 1)
                }
                Button { model.close(session.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(hovering ? 1 : 0)
                .help("End this session")
            }
            .frame(minWidth: 22)
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Color.white.opacity(0.12) : (hovering ? Color.white.opacity(0.05) : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.select(session: session) }
        .help("\(session.summary.map { "\(session.title): \($0)" } ?? session.title)\n\((session.cwd as NSString).abbreviatingWithTildeInPath)")
        .contextMenu {
            Button("End Session") { model.close(session.id) }
            CloseOthersButton(request: .init(keepSession: session.id))
            Divider()
            TabStripMenu()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(session.displayName)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

private struct FileTab: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var files: FilesModel
    let document: OpenDocument
    let number: Int
    @State private var hovering = false

    private var selected: Bool { files.active == document.path }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: document.isMarkdown ? "doc.text" : "doc")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(document.name)
                .font(.system(size: 12, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 190, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            if document.isDirty {
                // Unsaved changes.
                Circle().fill(Color.orange).frame(width: 6, height: 6)
            }
            ZStack {
                if number <= 9 {
                    Text("⌘\(number)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .opacity(hovering ? 0 : 1)
                }
                Button { files.requestClose(document.path) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(hovering ? 1 : 0)
                .help("Close this file")
            }
            .frame(minWidth: 22)
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Color.white.opacity(0.12) : (hovering ? Color.white.opacity(0.05) : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { files.active = document.path }
        .help((document.path as NSString).abbreviatingWithTildeInPath + (document.isDirty ? "\nUnsaved changes" : ""))
        .contextMenu {
            Button("Close") { files.requestClose(document.path) }
            Button("Close Other Files") { model.closeFileTabs(except: document.path) }
                .disabled(files.documents.count < 2 && model.diffTabFile == nil)
            CloseOthersButton(request: .init(keepFile: document.path))
            Divider()
            TabStripMenu()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(document.isDirty ? "\(document.name), unsaved changes" : document.name)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

private struct DiffTab: View {
    @EnvironmentObject private var model: AppModel
    let file: FileDiff
    let number: Int
    @State private var hovering = false

    private var selected: Bool { model.diffInFront }
    private var name: String { (file.path as NSString).lastPathComponent }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "plusminus")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(name)
                .font(.system(size: 12, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 190, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            Text(file.isStaged ? "staged" : "diff")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            ZStack {
                if number <= 9 {
                    Text("⌘\(number)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .opacity(hovering ? 0 : 1)
                }
                Button { model.closeDiffTab() } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(hovering ? 1 : 0)
                .help("Close this diff")
            }
            .frame(minWidth: 22)
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Color.white.opacity(0.12) : (hovering ? Color.white.opacity(0.05) : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.showDiffTab() }
        .help(file.path + (file.isStaged ? "\nStaged changes" : "\nChanges that are not staged"))
        .contextMenu {
            Button("Close") { model.closeDiffTab() }
            Button("Close Other Files") { model.closeFileTabs(keepDiff: true) }
                .disabled(model.files.documents.isEmpty)
            CloseOthersButton(request: .init(keepDiff: true))
            Divider()
            TabStripMenu()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Diff of \(name)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// What the menu of every tab ends with: closing many tabs at once.
struct TabStripMenu: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var files: FilesModel

    var body: some View {
        Button("Close All Files") { model.closeFileTabs() }
            .disabled(files.documents.isEmpty && model.diffTabFile == nil)
            .help("Close every file and diff. The terminals stay.")
        Button(model.sessions.isEmpty ? "Close All" : "Close All and End Sessions…") { model.closeTabs() }
            .disabled(model.tabCount == 0)
    }
}

/// Closes every other tab, sessions included, keeping the one named.
struct CloseOthersButton: View {
    @EnvironmentObject private var model: AppModel
    let request: AppModel.CloseRequest

    var body: some View {
        // The dots say a question follows, which it does when sessions would end.
        Button(model.sessionsEnded(by: request).isEmpty ? "Close Everything Else" : "Close Everything Else…") { model.closeTabs(request) }
            .disabled(model.tabCount < 2)
            .help("Close every other tab, terminals included")
    }
}
