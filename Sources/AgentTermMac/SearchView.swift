import AgentTermProtocol
import SwiftUI

/// The search of the folder's files, at the top of the Files tab (#45):
/// a field, by name or by text, and what was found in place of the tree.
struct SearchField: View {
    @EnvironmentObject private var files: FilesModel
    @ObservedObject var search: SearchModel
    @FocusState private var focused: Bool

    private var count: Int { search.mode == .names ? search.files.count : search.matches.count }

    /// Opens the row the arrow keys are on.
    private func openSelected() {
        if search.mode == .names {
            guard search.files.indices.contains(search.selection), let path = search.path(of: search.files[search.selection]) else { return }
            files.open(path)
        } else {
            guard search.matches.indices.contains(search.selection) else { return }
            let match = search.matches[search.selection]
            if let path = search.path(of: match.file) { files.open(path, line: match.line) }
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
            TextField(search.mode == .names ? "Go to file" : "Find in files", text: $search.query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($focused)
                .onSubmit(openSelected)
                .onKeyPress(.downArrow) {
                    search.selection = min(search.selection + 1, max(count - 1, 0))
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    search.selection = max(search.selection - 1, 0)
                    return .handled
                }
                .onKeyPress(.escape) {
                    search.hide()
                    return .handled
                }
                .accessibilityIdentifier("search-field")
            if search.mode == .text {
                Toggle("Aa", isOn: $search.caseSensitive)
                    .toggleStyle(.button)
                    .controlSize(.mini)
                    .help("Match upper and lower case")
                    .accessibilityLabel("Match Case")
                    .accessibilityIdentifier("search-case")
            }
            Picker("Search", selection: Binding(get: { search.mode }, set: { search.setMode($0) })) {
                Text("Name").tag(SearchModel.Mode.names)
                Text("Text").tag(SearchModel.Mode.text)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.mini)
            .fixedSize()
            .accessibilityIdentifier("search-mode")
            Button {
                search.hide()
            } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close the search")
            .accessibilityLabel("Close Search")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.04))
        .onChange(of: search.focusToken, initial: true) { _, _ in focused = true }
    }
}

/// What a search found: files, or lines file by file. A click opens the
/// file, at the line for a line.
struct SearchResults: View {
    @EnvironmentObject private var files: FilesModel
    @ObservedObject var search: SearchModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if search.mode == .names { names } else { lines }
                    }
                    .padding(6)
                }
                .onChange(of: search.selection) { _, selection in scroll.scrollTo(selection) }
            }
            Theme.hairline.frame(height: 1)
            HStack(spacing: 6) {
                Text(summary).font(.system(size: 10.5)).foregroundStyle(search.problem == nil ? Color.secondary : Color.orange).lineLimit(2)
                Spacer(minLength: 0)
                if search.mode == .text, search.isSearching {
                    Button("Stop") { search.stop() }.controlSize(.mini).accessibilityIdentifier("search-stop")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("search-summary")
        }
    }

    private var summary: String {
        if let problem = search.problem { return problem }
        if search.mode == .names { return TextMatch.summary(ofFiles: search.files.count, among: search.among, query: search.query) }
        if search.query.isEmpty { return "Type a word or a phrase. It is searched for as written." }
        return TextMatch.summary(of: search.matches, truncated: search.truncated, searching: search.isSearching)
    }

    @ViewBuilder private var names: some View {
        ForEach(Array(search.files.enumerated()), id: \.offset) { index, file in
            SearchRow(selected: index == search.selection) {
                Image(systemName: "doc").font(.system(size: 10.5)).foregroundStyle(.secondary).frame(width: 14)
                Text((file as NSString).lastPathComponent).font(.system(size: 12)).lineLimit(1)
                Text((file as NSString).deletingLastPathComponent).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            } action: {
                search.selection = index
                if let path = search.path(of: file) { files.open(path) }
            }
            .id(index)
            .help(file)
            .accessibilityLabel(file)
            .accessibilityIdentifier("found-" + file)
        }
    }

    @ViewBuilder private var lines: some View {
        // Numbered as the matches are, which is what the arrow keys walk.
        let numbered = Array(search.matches.enumerated())
        ForEach(TextMatch.byFile(search.matches), id: \.file) { group in
            HStack(spacing: 6) {
                Image(systemName: "doc").font(.system(size: 10.5)).foregroundStyle(.secondary)
                Text((group.file as NSString).lastPathComponent).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                Text((group.file as NSString).deletingLastPathComponent).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                Spacer(minLength: 0)
                Text("\(group.lines.count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 2)
            .help(group.file)
            ForEach(group.lines, id: \.self) { match in
                let index = numbered.first { $0.element == match }?.offset ?? 0
                SearchRow(selected: index == search.selection) {
                    Text("\(match.line)").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary).frame(minWidth: 26, alignment: .trailing)
                    marked(match).font(.system(size: 11.5, design: .monospaced)).lineLimit(1)
                } action: {
                    search.selection = index
                    if let path = search.path(of: match.file) { files.open(path, line: match.line) }
                }
                .id(index)
                .accessibilityLabel("\(match.file), line \(match.line): \(match.text)")
                .accessibilityIdentifier("match-\(match.file):\(match.line)")
            }
        }
    }

    /// The line with what was searched for standing out.
    private func marked(_ match: TextMatch) -> Text {
        let characters = Array(match.text)
        let start = min(max(match.start, 0), characters.count)
        let end = min(start + match.length, characters.count)
        return Text(String(characters[..<start])).foregroundColor(.secondary)
            + Text(String(characters[start..<end])).foregroundColor(.yellow).bold()
            + Text(String(characters[end...])).foregroundColor(.secondary)
    }
}

private struct SearchRow<Content: View>: View {
    let selected: Bool
    @ViewBuilder let content: () -> Content
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selected ? Color.white.opacity(0.11) : (hovering ? Color.white.opacity(0.05) : .clear)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, action)
    }
}
