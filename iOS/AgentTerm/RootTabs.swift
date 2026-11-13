import AgentTermProtocol
import AgentTermTelemetry
import AgentTermTerminal
import SwiftUI

/// The app's three places inside a Mac: its sessions, every conversation,
/// and the settings.
struct RootTabs: View {
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        TabView(selection: $model.tab) {
            SessionsView()
                .tabItem { Label("Sessions", systemImage: "terminal") }
                .tag("sessions")
            NavigationStack {
                HistoryList(folder: nil)
                    .background(Palette.canvas.ignoresSafeArea())
                    .navigationTitle("History")
            }
            .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            .tag("history")
            SettingsTab()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag("settings")
        }
        // On the tabs, not on one of them: what the Mac answers to
        // something asked in History or Settings has to be shown there too,
        // and an alert attached to a tab that is not in front does not
        // appear. For the same reason not on a list inside a tab, which
        // another screen, such as a terminal, may be on top of.
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

/// The app's settings, in the order of the Mac's Settings window: General,
/// Git, Privacy, then what only a phone has, the Mac it is paired with.
/// Those the Mac keeps (keeping awake, how things are shown, commit
/// messages) are the same there.
private struct SettingsTab: View {
    @EnvironmentObject private var model: PhoneModel
    @EnvironmentObject private var privacy: TelemetryPreferences
    @AppStorage(DisplaySettings.diffLayoutKey) private var diffLayout = "unified"
    @AppStorage(DisplaySettings.changesViewKey) private var changesView = "list"
    @AppStorage(SystemStats.temperatureUnitKey) private var temperatureUnit = SystemStats.celsius
    @State private var showingCommitWriter = false
    @State private var confirmingForget = false

    private var macName: String { model.pairing?.name ?? "the Mac" }

    /// One of the keep awake options, changed on the Mac as it is changed here.
    private func option<Value>(_ keyPath: WritableKeyPath<KeepAwakeOptions, Value>) -> Binding<Value> {
        Binding(
            get: { model.keepAwakeOptions[keyPath: keyPath] },
            set: {
                var options = model.keepAwakeOptions
                options[keyPath: keyPath] = $0
                model.setKeepAwakeOptions(options)
            })
    }

    var body: some View {
        NavigationStack {
            Form {
                // General, as on the Mac: keeping awake, then the temperature.
                Section {
                    if let keepAwake = model.keepAwake {
                        Toggle("Keep Mac Awake", isOn: Binding(get: { keepAwake }, set: { model.setKeepAwake($0) }))
                            .accessibilityIdentifier("keep-awake")
                        Picker("Turn off by itself", selection: option(\.minutes)) {
                            ForEach(KeepAwakeOptions.durations, id: \.self) { minutes in
                                Text(minutes == nil ? "Never" : "After \(KeepAwakeOptions.label(minutes: minutes))").tag(minutes)
                            }
                        }
                        Toggle("Keep the display on too", isOn: option(\.display))
                        Toggle("Only while plugged in", isOn: option(\.onlyOnPower))
                        Toggle("Only while an agent is working", isOn: option(\.onlyWhileWorking))
                    }
                    if let startAtLogin = model.startAtLogin {
                        Toggle("Start at Login", isOn: Binding(get: { startAtLogin }, set: { model.setStartAtLogin($0) }))
                            .accessibilityIdentifier("start-at-login")
                    }
                    Picker("Temperature", selection: Binding(get: { temperatureUnit }, set: { unit in model.setDisplay { $0.temperatureUnit = unit } })) {
                        Text("Celsius (°C)").tag(SystemStats.celsius)
                        Text("Fahrenheit (°F)").tag(SystemStats.fahrenheit)
                    }
                    .accessibilityIdentifier("temperature-unit")
                } header: {
                    Text("General")
                } footer: {
                    Text(
                        (model.keepAwake == true ? model.keepAwakeOptions.until.map { "Awake until \($0.formatted(date: .omitted, time: .shortened)). " } ?? "" : "")
                            + "While a session is open \(macName) does not go to sleep by itself, so agents keep working and this iPhone can still reach them. Closing its lid still puts it to sleep."
                            + (model.startAtLogin == nil ? "" : " With Start at Login, \(macName) can be reached after it restarts without AgentTerm being opened there first.")
                    )
                }

                // Git, as on the Mac: commit messages, then how diffs are shown.
                Section {
                    Button {
                        showingCommitWriter = true
                    } label: {
                        HStack {
                            Text("Commit Messages")
                            Spacer()
                            Text(model.commitWriterAgent?.name ?? "No agent").foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(.primary)
                    .disabled(model.status != .connected)
                    Picker("Show diffs as", selection: Binding(get: { diffLayout }, set: { layout in model.setDisplay { $0.diffLayout = layout } })) {
                        Text("One panel").tag("unified")
                        Text("Two panels").tag("split")
                    }
                    Picker("Show changes as", selection: Binding(get: { changesView }, set: { view in model.setDisplay { $0.changesView = view } })) {
                        Text("Flat list").tag("list")
                        Text("By folder").tag("tree")
                    }
                } header: {
                    Text("Git")
                } footer: {
                    Text("Which agent writes a commit message, on which model, and what it is told. These, like the settings above, are shared with the Mac.")
                }

                Section {
                    Toggle("Send crash reports", isOn: $privacy.crashReports)
                    Toggle("Share usage statistics", isOn: $privacy.usageStatistics)
                } header: {
                    Text("Privacy")
                } footer: {
                    Text(privacy.isAvailable ? TelemetryPreferences.Wording.usageDetail : TelemetryPreferences.Wording.unavailable)
                }

                // What only the phone has: the Mac it is looking at.
                Section {
                    Button {
                        model.showMacs()
                    } label: {
                        Label("Switch to Another Mac", systemImage: "arrow.left.arrow.right")
                    }
                    Button {
                        model.refreshAgents()
                    } label: {
                        Label("Check Agents Again", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.status != .connected)
                    Button(role: .destructive) {
                        confirmingForget = true
                    } label: {
                        Label("Forget This Mac", systemImage: "xmark.circle")
                    }
                } header: {
                    Text(macName)
                }

                // About, last as on the Mac: the version and the two links.
                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("\(AppVersion.label) · protocol \(agenttermProtocolVersion)").foregroundStyle(.secondary)
                    }
                    Link(destination: ProjectLinks.page) { Label("Project Page", systemImage: "globe") }
                    Link(destination: ProjectLinks.source) { Label("Source on GitHub", systemImage: "chevron.left.forwardslash.chevron.right") }
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showingCommitWriter) {
                CommitWriterSheet()
                    .environmentObject(model)
                    .preferredColorScheme(.dark)
            }
            .confirmationDialog("Forget this Mac?", isPresented: $confirmingForget, titleVisibility: .visible) {
                Button("Forget", role: .destructive) { model.forgetMac() }
            } message: {
                Text("Sessions keep running on \(macName). To connect again you pair with it once more.")
            }
        }
    }
}
