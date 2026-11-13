import AgentTermFirebase
import AgentTermProtocol
import AgentTermTelemetry
import SwiftUI

@main
struct AgentTermApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    /// Stay in the menu bar when the window is closed, instead of quitting.
    @AppStorage(MenuBarMode.key) private var staysInMenuBar = MenuBarMode.defaultValue

    init() {
        // Before anything is shown: the question about crash reports
        // depends on whether this build can report at all.
        FirebaseSink.start()
        Telemetry.shared.record(.appOpen)
    }

    var body: some Scene {
        Window(AppChannel.current.appName, id: "main") {
            RootView()
                .modifier(CrashReportQuestion())
                .environmentObject(model)
                .environmentObject(model.files)
                .preferredColorScheme(.dark)
                .frame(minWidth: 940, minHeight: 540)
        }
        .defaultSize(width: 1440, height: 860)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Shell") { model.launch(nil) }
                    .keyboardShortcut("t")
                ForEach(Array(model.installedAgents.enumerated()), id: \.element.id) { index, agent in
                    Button("New \(agent.name)") { model.launch(agent) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .shift])
                }
                if !model.sshHosts.isEmpty {
                    Menu("New SSH Session") {
                        ForEach(model.sshHosts, id: \.self) { host in
                            Button(host) { model.connectSSH(host) }
                        }
                    }
                }
                Divider()
                Button("Add Folder…") { model.addFolder() }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                SaveCommand(files: model.files)
            }
            CommandMenu("Tab") {
                TabCommands(model: model, files: model.files)
            }
            CommandGroup(after: .sidebar) {
                Button("Bigger Text") { model.changeFontSize(by: 1) }
                    .keyboardShortcut("+")
                    .disabled(model.terminalFontSize >= AppModel.fontSizes.upperBound)
                Button("Smaller Text") { model.changeFontSize(by: -1) }
                    .keyboardShortcut("-")
                    .disabled(model.terminalFontSize <= AppModel.fontSizes.lowerBound)
                Button("Actual Size") { model.changeFontSize(by: nil) }
                    .keyboardShortcut("0")
                    .disabled(model.terminalFontSize == AppModel.defaultFontSize)
                Divider()
                Button(model.showSidebar ? "Hide Folders" : "Show Folders") { model.showSidebar.toggle() }
                    .keyboardShortcut("s", modifiers: [.command, .control])
                Button(model.showDiff ? "Hide Side Panel" : "Show Side Panel") { model.showDiff.toggle() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }

        // The icon in the menu bar, while the setting is on.
        MenuBarExtra(AppChannel.current.appName, systemImage: AppChannel.current == .release ? "terminal.fill" : "terminal", isInserted: $staysInMenuBar) {
            MenuBarMenu(model: model)
        }

        Settings {
            SettingsTabs()
                .environmentObject(model)
        }
    }
}

/// Whether AgentTerm stays in the menu bar when its window is closed.
enum MenuBarMode {
    static let key = "staysInMenuBar"
    static let defaultValue = true
    static var isOn: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? defaultValue }
}

/// What the menu bar icon opens: the way back to the window, the sessions
/// that are running, and Quit.
private struct MenuBarMenu: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open \(AppChannel.current.appName)") { showWindow() }
        Divider()
        if model.sessions.isEmpty {
            Text("No sessions running")
        } else {
            Text(model.sessions.count == 1 ? "1 session running" : "\(model.sessions.count) sessions running")
            ForEach(model.sessions) { session in
                Button(session.displayName) {
                    showWindow()
                    model.select(session: session)
                }
            }
        }
        Divider()
        ForEach(model.installedAgents) { agent in
            Button("New \(agent.name)") {
                showWindow()
                model.launch(agent)
            }
        }
        Button("New Shell") {
            showWindow()
            model.launch(nil)
        }
        if !model.sshHosts.isEmpty {
            Menu("New SSH Session") {
                ForEach(model.sshHosts, id: \.self) { host in
                    Button(host) {
                        showWindow()
                        model.connectSSH(host)
                    }
                }
            }
        }
        if let keepAwake = model.keepAwake {
            Divider()
            Toggle("Keep Mac Awake", isOn: Binding(get: { keepAwake }, set: { model.setKeepAwake($0) }))
            if keepAwake, let until = model.keepAwakeOptions.until {
                Text("Until \(until.formatted(date: .omitted, time: .shortened))")
            }
        }
        Divider()
        Button("Pair Device…") {
            showWindow()
            model.showPairing = true
        }
        .disabled(model.isRemote)
        SettingsLink { Text("Settings and Permissions…") }
        Divider()
        Button("Quit \(AppChannel.current.appName)") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func showWindow() {
        // Back in the Dock, then the window, then in front of other apps.
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// The panes of the Settings window. The one last looked at comes back.
/// Asks once, at the first launch of a build that can send them, whether
/// crash reports may be sent. Until answered, none are.
private struct CrashReportQuestion: ViewModifier {
    @StateObject private var preferences = TelemetryPreferences()

    func body(content: Content) -> some View {
        content.alert(TelemetryPreferences.Wording.question, isPresented: $preferences.needsAsking) {
            Button("Send Crash Reports") { preferences.answer(sendCrashReports: true) }
            Button("Don't Send", role: .cancel) { preferences.answer(sendCrashReports: false) }
        } message: {
            Text(TelemetryPreferences.Wording.questionDetail + "\n\nYou can change this, and usage statistics, in Settings > Privacy.")
        }
    }
}

private struct SettingsTabs: View {
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            SettingsView().tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            GitSettingsView().tabItem { Label("Git", systemImage: "arrow.triangle.branch") }.tag("git")
            PermissionsView().tabItem { Label("Permissions", systemImage: "lock.shield") }.tag("permissions")
            PrivacySettingsView().tabItem { Label("Privacy", systemImage: "hand.raised") }.tag("privacy")
        }
    }
}

private struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(MenuBarMode.key) private var staysInMenuBar = MenuBarMode.defaultValue
    @AppStorage(SystemStats.temperatureUnitKey) private var temperatureUnit = SystemStats.celsius

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsHeader(symbol: "gearshape.fill", tint: .gray, title: "General", subtitle: "How \(AppChannel.current.appName) behaves on this Mac.")
            SettingsCard {
                Toggle(isOn: $staysInMenuBar) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Stay in the menu bar when the window is closed")
                            .font(.system(size: 13, weight: .medium))
                        Text(
                            staysInMenuBar
                                ? "Closing the window leaves the app running, with an icon in the menu bar to open it again. Quit from that menu or with ⌘Q."
                                : "Closing the window quits the app. Sessions keep running either way: the host that holds them is a separate program."
                        )
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                // The words next to a switch are its label only to the eye.
                .accessibilityLabel("Stay in the menu bar when the window is closed")
                .accessibilityIdentifier("menu-bar")
            }
            if let startAtLogin = model.startAtLogin {
                SettingsCard {
                    Toggle(isOn: Binding(get: { startAtLogin }, set: { model.setStartAtLogin($0) })) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Start the host when you log in")
                                .font(.system(size: 13, weight: .medium))
                            Text(
                                "After the Mac restarts, your iPhone can reach it without this app being opened first. Only the host starts, with no window; the app uses it when you open it."
                            )
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.switch)
                    .accessibilityLabel("Start the host when you log in")
                    .accessibilityIdentifier("start-at-login")
                }
            }
            if let agentShells = model.agentShells {
                SettingsCard {
                    Toggle(isOn: Binding(get: { agentShells }, set: { model.setAgentShells($0) })) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Agents can open shells you see")
                                .font(.system(size: 13, weight: .medium))
                            Text(
                                "Claude Code, Codex, Copilot CLI and Antigravity get AgentTerm's MCP server in their own settings. An agent can then open a shell as a tab here, an SSH session or a dev server, and work in it while you watch and type. It reaches only the shells it opened, and cannot start agents. Turning this off removes the server from their settings."
                            )
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.switch)
                    .accessibilityLabel("Agents can open shells you see")
                    .accessibilityIdentifier("agent-shells")
                }
            }
            if let keepAwake = model.keepAwake {
                SettingsCard {
                    Toggle(isOn: Binding(get: { keepAwake }, set: { model.setKeepAwake($0) })) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Keep the Mac awake while sessions are running")
                                .font(.system(size: 13, weight: .medium))
                            Text(
                                "The Mac does not go to sleep by itself while a session is open, so agents keep working and your iPhone can still reach them. Closing the lid still puts the Mac to sleep. With no session open the Mac sleeps as usual."
                            )
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.switch)
                    .accessibilityLabel("Keep the Mac awake while sessions are running")
                    .accessibilityIdentifier("keep-awake")
                    KeepAwakeOptionsView(isOn: keepAwake)
                }
            }
            SettingsCard {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Temperature").font(.system(size: 13, weight: .medium))
                        Text("The unit of the Mac's temperature in the line under the launch buttons. The iPhone app follows.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Picker("Temperature", selection: Binding(get: { temperatureUnit }, set: { unit in model.setDisplay { $0.temperatureUnit = unit } })) {
                        Text("Celsius (°C)").tag(SystemStats.celsius)
                        Text("Fahrenheit (°F)").tag(SystemStats.fahrenheit)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            SettingsCard {
                HStack {
                    Text("Version").font(.system(size: 13, weight: .medium))
                    Spacer()
                    // The iPhone app has to be of a version that speaks the same protocol.
                    Text("\(AppVersion.current) · protocol \(agenttermProtocolVersion)")
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Divider().padding(.vertical, 10)
                HStack(spacing: 16) {
                    Text("About").font(.system(size: 13, weight: .medium))
                    Spacer()
                    Link(destination: ProjectLinks.page) { Label("Project page", systemImage: "globe") }
                        .help(ProjectLinks.page.absoluteString)
                    Link(destination: ProjectLinks.source) { Label("Source on GitHub", systemImage: "chevron.left.forwardslash.chevron.right") }
                        .help(ProjectLinks.source.absoluteString)
                }
                .font(.system(size: 12.5))
            }
        }
        .padding(24)
        .frame(width: 600, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// How the Mac is kept awake: for how long, the display too, only on
/// power. The host keeps these, so the iPhone shows the same.
private struct KeepAwakeOptionsView: View {
    @EnvironmentObject private var model: AppModel
    let isOn: Bool

    private func binding<Value>(_ keyPath: WritableKeyPath<KeepAwakeOptions, Value>) -> Binding<Value> {
        Binding(
            get: { model.keepAwakeOptions[keyPath: keyPath] },
            set: {
                var options = model.keepAwakeOptions
                options[keyPath: keyPath] = $0
                model.setKeepAwakeOptions(options)
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Divider().padding(.vertical, 4)
            HStack {
                Text("Turn off by itself").font(.system(size: 12.5))
                Spacer()
                if isOn, let until = model.keepAwakeOptions.until {
                    Text("Ends at \(until.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Picker("Turn off by itself", selection: binding(\.minutes)) {
                    ForEach(KeepAwakeOptions.durations, id: \.self) { minutes in
                        Text(minutes == nil ? "Never" : "After \(KeepAwakeOptions.label(minutes: minutes))").tag(minutes)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            Toggle(isOn: binding(\.display)) {
                Text("Keep the display on too").font(.system(size: 12.5))
            }
            Toggle(isOn: binding(\.onlyOnPower)) {
                Text("Only while the Mac is plugged in").font(.system(size: 12.5))
            }
            Toggle(isOn: binding(\.onlyWhileWorking)) {
                Text("Only while an agent is working").font(.system(size: 12.5))
            }
            .help("An agent that waits for you, is done, or a shell, does not keep the Mac awake")
        }
        .toggleStyle(.checkbox)
    }
}

/// Which agent writes commit messages in the Git tab, and how it is asked.
/// The host keeps these, so the iPhone's Write button does the same.
private struct GitSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var modelName = ""
    @State private var prompt = ""
    /// The same choice the button in a diff's header makes.
    @AppStorage("diffLayout") private var diffLayout = "unified"
    /// The same choice the button above the list of changes makes.
    @AppStorage(DisplaySettings.changesViewKey) private var changesView = "list"

    private var agent: Binding<String> {
        Binding(
            get: { model.commitWriter.agent ?? "" },
            set: {
                var settings = model.commitWriter
                settings.agent = $0.isEmpty ? nil : $0
                // A model belongs to an agent: another agent starts on its own.
                settings.model = nil
                modelName = ""
                model.setCommitWriter(settings)
            })
    }

    /// The agent that writes when none is chosen.
    private var firstInstalled: AgentInfo? { model.installedAgents.first }
    private var writerID: String? { model.commitWriter.writer(among: model.agents)?.id }
    private var isChanged: Bool {
        modelName.trimmingCharacters(in: .whitespaces) != (model.commitWriter.model ?? "") || prompt != model.commitWriter.effectivePrompt
    }

    private func load() {
        modelName = model.commitWriter.model ?? ""
        prompt = model.commitWriter.effectivePrompt
    }

    private func save() {
        var settings = model.commitWriter
        let name = modelName.trimmingCharacters(in: .whitespaces)
        settings.model = name.isEmpty ? nil : name
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.prompt = text.isEmpty || text == CommitWriterSettings.defaultPrompt ? nil : text
        model.setCommitWriter(settings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsHeader(
                symbol: "sparkles", tint: .purple, title: "Commit Messages",
                subtitle: "The Write button of the Git tab asks an agent for the message of what is staged. It never commits by itself.")
            SettingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Agent").font(.system(size: 13, weight: .medium))
                        Spacer()
                        Picker("Agent", selection: agent) {
                            Text(firstInstalled.map { "First installed (\($0.name))" } ?? "First installed").tag("")
                            ForEach(model.installedAgents) { agent in
                                Text(agent.name).tag(agent.id)
                            }
                            // One that was chosen and is gone since still has
                            // to be among the choices, or the picker shows none.
                            if let chosen = model.commitWriter.agent, !model.installedAgents.contains(where: { $0.id == chosen }) {
                                Text("\(model.agents.first { $0.id == chosen }?.name ?? chosen) (not installed)").tag(chosen)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Model").font(.system(size: 13, weight: .medium))
                            Text("As the agent's --model option takes it. Empty uses a cheap model where one is known, else the agent's own.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 12)
                        TextField(writerID.flatMap(CommitWriterSettings.defaultModel) ?? "Agent's default", text: $modelName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 190)
                            .onSubmit(save)
                            .accessibilityLabel("Model")
                    }
                }
            }
            SettingsCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Prompt").font(.system(size: 13, weight: .medium))
                    Text("What the agent is told. The staged changes follow it. Say here which style and language you want.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    TextEditor(text: $prompt)
                        .font(.system(size: 12))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(height: 150)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06)))
                        .accessibilityLabel("Prompt")
                    HStack {
                        Button("Reset to Default") {
                            prompt = CommitWriterSettings.defaultPrompt
                            save()
                        }
                        .disabled(prompt == CommitWriterSettings.defaultPrompt && model.commitWriter.prompt == nil)
                        Spacer()
                        Button("Save", action: save)
                            .keyboardShortcut("s")
                            .disabled(!isChanged)
                    }
                    .controlSize(.small)
                }
            }
            SettingsCard {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Show diffs as").font(.system(size: 13, weight: .medium))
                        Text("How a diff opens. The button in a diff's header switches for that moment and is remembered too.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Picker("Show diffs as", selection: Binding(get: { diffLayout }, set: { layout in model.setDisplay { $0.diffLayout = layout } })) {
                        Text("One panel").tag("unified")
                        Text("Two panels, side by side").tag("split")
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Divider().padding(.vertical, 10)
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Show changes as").font(.system(size: 13, weight: .medium))
                        Text("The changed files of the Git tab: one flat list, or grouped by folder. The button above the list switches too.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Picker("Show changes as", selection: Binding(get: { changesView }, set: { view in model.setDisplay { $0.changesView = view } })) {
                        Text("Flat list").tag("list")
                        Text("By folder").tag("tree")
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            Label(
                "The agent runs once, without a terminal and with no way to change your files, in a folder of AgentTerm's own, so it leaves no conversation in your project. Large changes are cut down before they are sent.",
                systemImage: "info.circle"
            )
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: 600, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: load)
        .onChange(of: model.commitWriter) { old, new in
            // The settings changed, here through the agent's picker or on
            // the iPhone. What is being edited and not saved yet stays as
            // it was typed; only a field that still showed the old value follows.
            if modelName.trimmingCharacters(in: .whitespaces) == (old.model ?? "") { modelName = new.model ?? "" }
            if prompt == old.effectivePrompt { prompt = new.effectivePrompt }
        }
    }
}

/// What AgentTerm reports to its developer, and the switches for it.
private struct PrivacySettingsView: View {
    @StateObject private var preferences = TelemetryPreferences()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsHeader(
                symbol: "hand.raised.fill", tint: .blue, title: "Privacy",
                subtitle: "What \(AppChannel.current.appName) reports to its developer. Your terminals, prompts and files are never part of it.")
            SettingsCard {
                Toggle(isOn: $preferences.crashReports) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Send crash reports").font(.system(size: 13, weight: .medium))
                        Text(TelemetryPreferences.Wording.questionDetail)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
            }
            SettingsCard {
                Toggle(isOn: $preferences.usageStatistics) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Share usage statistics").font(.system(size: 13, weight: .medium))
                        Text(TelemetryPreferences.Wording.usageDetail)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
            }
            if !preferences.isAvailable {
                Label(TelemetryPreferences.Wording.unavailable, systemImage: "info.circle")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .frame(width: 600, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Title of a settings pane: a tinted tile, a name and a line about it.
struct SettingsHeader: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.gradient))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 17, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A rounded panel that groups related settings.
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when started with `swift run` instead of from an app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // With the window closed and the app living in the menu bar, the
        // Dock icon goes too, as it does for other menu bar apps.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { notification in
            guard MenuBarMode.isOn, let closing = notification.object as? NSWindow, closing.canBecomeMain else { return }
            DispatchQueue.main.async {
                let open = NSApp.windows.contains { $0 !== closing && $0.isVisible && $0.canBecomeMain }
                if !open { NSApp.setActivationPolicy(.accessory) }
            }
        }
    }

    /// Closing the window quits, unless the app is set to stay in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !MenuBarMode.isOn }

    /// Opened again from the Dock or the Finder: back to a normal app.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.setActivationPolicy(.regular)
        return true
    }
}

/// File > Save, for the file in front. Its own view so the menu item
/// follows the file's unsaved state.
private struct SaveCommand: View {
    @ObservedObject var files: FilesModel

    var body: some View {
        Button("Save") { files.save() }
            .keyboardShortcut("s")
            .disabled(files.activeDocument?.isDirty != true)
    }
}

/// The tabs of the middle pane as menu items: sessions first, then files.
private struct TabCommands: View {
    @ObservedObject var model: AppModel
    @ObservedObject var files: FilesModel

    private var names: [String] { model.visibleTabs.map(model.tabName) }

    var body: some View {
        // Command and a number shows the tab in that place.
        ForEach(Array(names.prefix(9).enumerated()), id: \.offset) { index, name in
            Button(name) { model.selectTab(number: index + 1) }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
        }
        if !names.isEmpty { Divider() }
        Button("Next Tab") { model.selectTab(offset: 1) }
            .keyboardShortcut("]", modifiers: [.command, .shift])
            .disabled(model.tabCount < 2)
        Button("Previous Tab") { model.selectTab(offset: -1) }
            .keyboardShortcut("[", modifiers: [.command, .shift])
            .disabled(model.tabCount < 2)
        Divider()
        let front = model.frontTabID
        Button(front.map(model.tabLayout.isPinned) == true ? "Unpin Tab" : "Pin Tab") {
            if let front { model.setTabPinned(front, !model.tabLayout.isPinned(front)) }
        }
        .disabled(front == nil)
        Button("Add Tab to New Group") { if let front { model.newTabGroup(with: front) } }
            .disabled(front == nil)
        Button("Move Tab Left") { if let front { model.moveTab(front, by: -1) } }
            .keyboardShortcut("[", modifiers: [.command, .control, .shift])
            .disabled(model.tabCount < 2)
        Button("Move Tab Right") { if let front { model.moveTab(front, by: 1) } }
            .keyboardShortcut("]", modifiers: [.command, .control, .shift])
            .disabled(model.tabCount < 2)
        Divider()
        Button(model.diffInFront ? "Close Diff" : (files.active != nil ? "Close File" : "End Session")) { model.closeFrontTab() }
            .keyboardShortcut("w")
            .disabled(!model.diffInFront && files.active == nil && model.selectedSession == nil)
        Button("Close Other Files") { model.closeFileTabs(except: files.active, keepDiff: model.diffInFront) }
            .keyboardShortcut("w", modifiers: [.command, .option])
            .disabled(files.documents.isEmpty && model.diffTabFile == nil)
        Button("Close All Files") { model.closeFileTabs() }
            .keyboardShortcut("w", modifiers: [.command, .shift])
            .disabled(files.documents.isEmpty && model.diffTabFile == nil)
        Button("Close Other Tabs…") {
            model.closeTabs(
                .init(
                    keepSession: model.diffInFront || files.active != nil ? nil : model.selectedSession,
                    keepFile: model.diffInFront ? nil : files.active, keepDiff: model.diffInFront
                ))
        }
        .disabled(model.tabCount < 2)
        Button(model.sessions.isEmpty ? "Close All Tabs" : "Close All Tabs…") { model.closeTabs() }
            .disabled(model.tabCount == 0)
    }
}
