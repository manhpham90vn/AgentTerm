import AgentTermProtocol
import SwiftUI
import UniformTypeIdentifiers

/// Every running session and every open file as a tab above the middle pane,
/// to switch between them with one click or Command and a number.
struct SessionTabs: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var files: FilesModel

    /// A tab's 25 points and 6 above and below.
    private static let stripHeight: CGFloat = 37

    /// What a dragged tab is over: a tab's id, a group's id, or "end".
    @State private var dropTarget: String?

    @ViewBuilder
    private func tab(_ id: String) -> some View {
        let number = (model.visibleTabs.firstIndex(of: id) ?? 99) + 1
        Group {
            if let session = model.session(forTab: id) {
                SessionTab(session: session, number: number)
            } else if let document = model.document(forTab: id) {
                FileTab(document: document, number: number)
            } else if id == TabID.diff, let file = model.diffTabFile {
                DiffTab(file: file, number: number)
            }
        }
        .modifier(TabChrome(id: id, dropTarget: $dropTarget))
    }

    var body: some View {
        if !model.sessions.isEmpty || !files.documents.isEmpty || model.diffTabFile != nil {
            HStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(Array(model.tabLayout.items(front: model.frontTabID).enumerated()), id: \.offset) { _, item in
                                switch item {
                                case .group(let group, let count):
                                    GroupLabel(group: group, count: count, dropTarget: $dropTarget)
                                case .tab(let id):
                                    if model.liveTabIDs.contains(id) { tab(id).id(id) }
                                }
                            }
                            // Room after the last tab to drop one at the end.
                            Color.clear.frame(width: 28, height: 24)
                                .overlay(alignment: .leading) { if dropTarget == "end" { InsertionMark() } }
                                .onDrop(of: [TabDrag.type], delegate: TabDropDelegate(place: .end, model: model, dropTarget: $dropTarget))
                        }
                        .padding(.horizontal, 8)
                        // One fixed height for the row and for the strip:
                        // the strip scrolls sideways only, and with nothing
                        // taller than it there is nothing to move up or down.
                        .frame(height: Self.stripHeight)
                        .background(WheelScrollsSideways())
                    }
                    .frame(height: Self.stripHeight)
                    .scrollBounceBehavior(.basedOnSize, axes: .vertical)
                    .onChange(of: model.frontTabID) { _, front in
                        if let front { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(front) } }
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
            AgentStateMark(session: session)
            if model.foreignSizes[session.id] != nil {
                Image(systemName: "iphone").font(.system(size: 9.5)).foregroundStyle(.secondary)
            }
            // The close button takes the shortcut's place under the pointer,
            // so the tab does not change width.
            TabTrailing(id: TabID.session(session), number: number, hovering: hovering, closeHelp: "End this session") { model.close(session.id) }
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
            TabArrangeMenu(id: TabID.session(session))
            Divider()
            Button("End Session") { model.requestEnd(session.id) }
            CloseOthersButton(request: .init(keepSession: session.id))
            TabStripMenu()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(AgentStateMark.label(session.displayName, session))
        .accessibilityIdentifier("tab-\(session.id)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        // The tab's menu opens under the pointer only: what it holds is
        // offered as the tab's own actions too.
        .accessibilityAction { model.select(session: session) }
        .accessibilityAction(named: "End Session") { model.requestEnd(session.id) }
        .accessibilityAction(named: "Close Other Tabs") { model.closeTabs(.init(keepSession: session.id)) }
        .accessibilityAction(named: "Close All Tabs") { model.closeTabs() }
        .accessibilityAction(named: "Hand Off") { model.requestHandoff(session: session) }
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
            TabTrailing(id: TabID.file(document.path), number: number, hovering: hovering, closeHelp: "Close this file") { files.requestClose(document.path) }
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
            TabArrangeMenu(id: TabID.file(document.path))
            Divider()
            Button("Close File") { files.requestClose(document.path) }
            CloseOthersButton(request: .init(keepFile: document.path))
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
            TabTrailing(id: TabID.diff, number: number, hovering: hovering, closeHelp: "Close this diff") { model.closeDiffTab() }
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
            TabArrangeMenu(id: TabID.diff)
            Divider()
            Button("Close Diff") { model.closeDiffTab() }
            CloseOthersButton(request: .init(keepDiff: true))
            TabStripMenu()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Diff of \(name)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// What the menu of every tab ends with: closing many tabs at once. With
/// "close this one" and "close the others" before it, that makes four ways
/// to close, each with a different reach, and no two that do the same.
struct TabStripMenu: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var files: FilesModel

    var body: some View {
        Button("Close All Files") { model.closeFileTabs() }
            .disabled(files.documents.isEmpty && model.diffTabFile == nil)
            .help("Close every file and diff. The terminals stay.")
        Button(model.sessionsEnded(by: .init()).isEmpty ? "Close All Tabs" : "Close All Tabs…") { model.closeTabs() }
            .disabled(model.tabCount == 0)
            .help("Close every tab, ending the sessions. Pinned tabs stay.")
    }
}

/// Closes every other tab, sessions included, keeping the one named.
struct CloseOthersButton: View {
    @EnvironmentObject private var model: AppModel
    let request: AppModel.CloseRequest

    var body: some View {
        // The dots say a question follows, which it does when sessions would end.
        Button(model.sessionsEnded(by: request).isEmpty ? "Close Other Tabs" : "Close Other Tabs…") { model.closeTabs(request) }
            .disabled(model.tabCount < 2)
            .help("Close every other tab, ending the other sessions. Pinned tabs stay.")
    }
}

// MARK: Arranging tabs

enum TabDrag {
    /// What a dragged tab carries: plain data, which a terminal or an editor
    /// does not take for text to insert. A type of the app's own would have
    /// to be declared in the bundle to be accepted by a drop at all, and
    /// the tab is known from `AppModel.draggedTab` anyway.
    static let type = UTType.data
}

/// The end of a tab: its shortcut, which gives way to the close button under
/// the pointer. A pinned tab shows a pin instead and is closed from its menu.
private struct TabTrailing: View {
    @EnvironmentObject private var model: AppModel
    let id: String
    let number: Int
    let hovering: Bool
    let closeHelp: String
    let close: () -> Void

    var body: some View {
        ZStack {
            if model.tabLayout.isPinned(id) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(45))
                    .help("Pinned. Closing many tabs at once leaves it open.")
            } else {
                if number <= 9 {
                    Text("⌘\(number)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .opacity(hovering ? 0 : 1)
                }
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(hovering ? 1 : 0)
                .help(closeHelp)
            }
        }
        .frame(minWidth: model.tabLayout.isPinned(id) ? 14 : 22)
    }
}

/// Where a dragged tab will land.
private struct InsertionMark: View {
    var body: some View {
        Capsule().fill(Color.accentColor).frame(width: 2.5, height: 20).offset(x: -3.25)
    }
}

/// What every tab has on top of its own looks: the line of its group's
/// color, and being dragged and dropped on.
private struct TabChrome: ViewModifier {
    @EnvironmentObject private var model: AppModel
    let id: String
    @Binding var dropTarget: String?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let group = model.tabLayout.group(of: id) {
                    Capsule().fill(TabColors.color(group.color)).frame(height: 2).padding(.horizontal, 6).offset(y: 3)
                }
            }
            .overlay(alignment: .leading) { if dropTarget == id { InsertionMark() } }
            .onDrag {
                model.draggedFolder = nil
                model.draggedTab = id
                let provider = NSItemProvider()
                provider.registerDataRepresentation(forTypeIdentifier: TabDrag.type.identifier, visibility: .ownProcess) { done in
                    done(Data(id.utf8), nil)
                    return nil
                }
                return provider
            }
            .onDrop(of: [TabDrag.type], delegate: TabDropDelegate(place: .before(id), model: model, dropTarget: $dropTarget))
    }
}

private struct TabDropDelegate: DropDelegate {
    enum Place {
        case before(String), group(String), end

        var key: String {
            switch self {
            case .before(let id): return id
            case .group(let id): return id
            case .end: return "end"
            }
        }
    }

    let place: Place
    let model: AppModel
    @Binding var dropTarget: String?

    func validateDrop(info: DropInfo) -> Bool { model.draggedTab != nil }

    func dropEntered(info: DropInfo) {
        if case .before(let id) = place, id == model.draggedTab { return }
        dropTarget = place.key
    }

    func dropExited(info: DropInfo) {
        if dropTarget == place.key { dropTarget = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dropTarget = nil
        guard let id = model.draggedTab else { return false }
        model.draggedTab = nil
        withAnimation(.easeOut(duration: 0.15)) {
            switch place {
            case .before(let target): model.moveTab(id, before: target)
            case .group(let group): model.addTab(id, toGroup: group)
            case .end: model.moveTab(id, before: nil)
            }
        }
        return true
    }
}

/// The label a group's tabs follow. A click folds the group away.
private struct GroupLabel: View {
    @EnvironmentObject private var model: AppModel
    let group: TabGroup
    let count: Int
    @Binding var dropTarget: String?
    @State private var renaming = false
    @State private var name = ""

    private var color: Color { TabColors.color(group.color) }

    var body: some View {
        HStack(spacing: 4) {
            Text(group.name.isEmpty ? "Group" : group.name)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: 140)
                .fixedSize(horizontal: true, vertical: false)
            if group.isCollapsed {
                Text("\(count)").font(.system(size: 10, weight: .medium, design: .monospaced)).opacity(0.7)
            }
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color.opacity(dropTarget == group.id ? 0.34 : 0.16)))
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { model.tabLayout.toggleCollapsed(group.id) } }
        .onDrop(of: [TabDrag.type], delegate: TabDropDelegate(place: .group(group.id), model: model, dropTarget: $dropTarget))
        .help(group.isCollapsed ? "Show the \(count) tabs of this group" : "Fold this group away. Drop a tab here to add it.")
        .contextMenu {
            Button(group.isCollapsed ? "Expand Group" : "Collapse Group") { model.tabLayout.toggleCollapsed(group.id) }
            Button("Rename Group…") {
                name = group.name
                renaming = true
            }
            // A picker, so the menu ticks the color in use, and a drawn
            // swatch, because a menu shows symbols in its own one color.
            Picker("Color", selection: Binding(get: { group.color }, set: { model.tabLayout.setColor($0, of: group.id) })) {
                ForEach(TabLayout.colors, id: \.self) { name in
                    Label {
                        Text(name.capitalized)
                    } icon: {
                        Image(nsImage: TabColors.swatch(name))
                    }.tag(name)
                }
            }
            .pickerStyle(.menu)
            Divider()
            Button("Ungroup") { model.tabLayout.ungroup(group.id) }
                .help("The tabs stay open, in no group")
        }
        .alert("Rename Group", isPresented: $renaming) {
            TextField("Name", text: $name)
            Button("Rename") { model.tabLayout.rename(group.id, to: name) }
            Button("Cancel", role: .cancel) {}
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Group \(group.name), \(count) tabs" + (group.isCollapsed ? ", collapsed" : ""))
        .accessibilityAddTraits(.isButton)
        // A tap gesture alone is not something VoiceOver can press.
        .accessibilityAction { model.tabLayout.toggleCollapsed(group.id) }
    }
}

/// The part of a tab's menu that arranges it: pin, group, move.
struct TabArrangeMenu: View {
    @EnvironmentObject private var model: AppModel
    let id: String

    var body: some View {
        let layout = model.tabLayout
        let visible = model.visibleTabs
        let index = visible.firstIndex(of: id)
        Button(layout.isPinned(id) ? "Unpin Tab" : "Pin Tab") { model.setTabPinned(id, !layout.isPinned(id)) }
        Button("Add to New Group") { model.newTabGroup(with: id) }
        let others = layout.groups.filter { $0.id != layout.group(of: id)?.id }
        if !others.isEmpty {
            Menu("Add to Group") {
                ForEach(others) { group in
                    Button(group.name.isEmpty ? "Group" : group.name) { model.addTab(id, toGroup: group.id) }
                }
            }
        }
        if layout.group(of: id) != nil {
            Button("Remove from Group") { model.tabLayout.removeFromGroup(id) }
        }
        Divider()
        Button("Move Left") { model.moveTab(id, by: -1) }.disabled(index == nil || index == 0)
        Button("Move Right") { model.moveTab(id, by: 1) }.disabled(index == nil || index == visible.count - 1)
    }
}

/// Lets a mouse wheel move the strip of tabs sideways.
///
/// The strip scrolls sideways only, and a wheel turns up and down: with a
/// mouse there was no way to reach the tabs past the edge. A turn of the
/// wheel over the strip now moves it sideways, as in a browser. A trackpad's
/// own sideways swipe is left to the scroll view.
private struct WheelScrollsSideways: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class Probe: NSView {
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

        /// Returns nil for an event that was used here.
        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let scrollView = enclosingScrollView, event.window === window, let document = scrollView.documentView else { return event }
            let place = scrollView.convert(event.locationInWindow, from: nil)
            guard scrollView.bounds.contains(place) else { return event }
            // Mostly up and down: that is a wheel, or a swipe that was not
            // meant sideways. Sideways motion is the scroll view's own.
            let vertical = event.scrollingDeltaY
            guard abs(vertical) > abs(event.scrollingDeltaX), vertical != 0 else { return event }
            let step = event.hasPreciseScrollingDeltas ? vertical : vertical * 12
            let clip = scrollView.contentView
            let furthest = max(0, document.frame.width - clip.bounds.width)
            var origin = clip.bounds.origin
            origin.x = min(max(0, origin.x - step), furthest)
            clip.scroll(to: origin)
            scrollView.reflectScrolledClipView(clip)
            return nil
        }
    }
}
