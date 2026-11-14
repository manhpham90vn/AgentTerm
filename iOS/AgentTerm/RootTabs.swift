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
        // An agent of another session finished, or needs you: over every
        // tab, as the Mac shows it over every place.
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                // The agents on the Mac cannot open shells, although that
                // is on (#58): over every tab too, as on the Mac.
                ForEach(model.shownShellsFaults) { fault in
                    AgentShellsFaultBanner(fault: fault)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if let notice = model.agentNotice, notice.session != model.openSessionID {
                    AgentNoticeBanner(notice: notice)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 12)
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
    /// The Mac's own settings are changed only while it can be told: one
    /// changed while it cannot would be put back when it is reached again.
    private var online: Bool { model.status == .connected }

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
                    Group {
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
                        if let agentShells = model.agentShells {
                            Toggle("Agents can open shells you see", isOn: Binding(get: { agentShells }, set: { model.setAgentShells($0) }))
                                .accessibilityIdentifier("agent-shells")
                            if let useShells = model.agentsUseShells {
                                Toggle("Agents run their commands there", isOn: Binding(get: { useShells }, set: { model.setAgentsUseShells($0) }))
                                    .disabled(!agentShells)
                                    .accessibilityIdentifier("agents-use-shells")
                            }
                        }
                        Picker("Temperature", selection: Binding(get: { temperatureUnit }, set: { unit in model.setDisplay { $0.temperatureUnit = unit } })) {
                            Text("Celsius (°C)").tag(SystemStats.celsius)
                            Text("Fahrenheit (°F)").tag(SystemStats.fahrenheit)
                        }
                        .accessibilityIdentifier("temperature-unit")
                    }
                    .disabled(!online)
                } header: {
                    Text("General")
                } footer: {
                    Text(
                        (online ? "" : "Not connected to \(macName): these are as it last said, and can be changed once it is reached. ")
                            + (model.keepAwake == true ? model.keepAwakeOptions.until.map { "Awake until \($0.formatted(date: .omitted, time: .shortened)). " } ?? "" : "")
                            + "While a session is open \(macName) does not go to sleep by itself, so agents keep working and this iPhone can still reach them. Closing its lid still puts it to sleep."
                            + (model.startAtLogin == nil ? "" : " With Start at Login, \(macName) can be reached after it restarts without AgentTerm being opened there first.")
                    )
                }

                Section {
                    NavigationLink {
                        SchedulesScreen()
                    } label: {
                        LabeledContent("Schedules", value: model.schedules.isEmpty ? "None" : "\(model.schedules.count)")
                    }
                    .accessibilityIdentifier("schedules")
                    Toggle("Tell me when an agent is done or needs me", isOn: $model.notifyAgents)
                        .accessibilityIdentifier("notify-agents")
                    Toggle("Live Activity while no one is at the Mac", isOn: $model.showsLiveActivity)
                        .accessibilityIdentifier("live-activity")
                } header: {
                    Text("Agents")
                } footer: {
                    Text(
                        "While you work from this iPhone: a banner in the app, and a notification just after you leave it. Once iOS puts the app to sleep, after a short while, nothing arrives until you open it again. Nothing is told while someone is at \(macName). What an agent said shows on the lock screen only if iOS shows previews there."
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
                    Group {
                        Picker("Show diffs as", selection: Binding(get: { diffLayout }, set: { layout in model.setDisplay { $0.diffLayout = layout } })) {
                            Text("One panel").tag("unified")
                            Text("Two panels").tag("split")
                        }
                        Picker("Show changes as", selection: Binding(get: { changesView }, set: { view in model.setDisplay { $0.changesView = view } })) {
                            Text("Flat list").tag("list")
                            Text("By folder").tag("tree")
                        }
                        Toggle(
                            "Fetch automatically", isOn: Binding(get: { model.display.fetchAutomatically }, set: { on in model.setDisplay { $0.fetchAutomatically = on } })
                        )
                        .accessibilityIdentifier("fetch-automatically")
                    }
                    .disabled(!online)
                } header: {
                    Text("Git")
                } footer: {
                    Text(
                        "Which agent writes a commit message, on which model, and what it is told. These, and the settings of \(macName) above, are shared with it; the notifications, the Live Activity and Privacy are this iPhone's own."
                    )
                }

                Section {
                    Toggle(TelemetryPreferences.Wording.crashTitle, isOn: $privacy.crashReports)
                    Toggle(TelemetryPreferences.Wording.usageTitle, isOn: $privacy.usageStatistics)
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

/// Something keeps the agents on the Mac from opening shells the user
/// sees (#58): what, and what to do about it, until the Mac says it is
/// over or it is closed here.
private struct AgentShellsFaultBanner: View {
    @EnvironmentObject private var model: PhoneModel
    let fault: AgentShellsFault

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text(fault.headline(on: model.pairing?.name ?? "the Mac"))
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(fault.advice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("agent-shells-fault")
            Spacer(minLength: 0)
            Button {
                model.dismiss(fault)
            } label: {
                Image(systemName: "xmark").font(.footnote.weight(.semibold))
            }
            .accessibilityLabel("Dismiss")
            .accessibilityIdentifier("agent-shells-fault-dismiss")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.thinMaterial))
    }
}

/// An agent of a session that is not on screen finished or waits (#22):
/// which session, and why. Touching it opens the session.
private struct AgentNoticeBanner: View {
    @EnvironmentObject private var model: PhoneModel
    let notice: AgentNotice

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(notice.name) \(notice.why)")
                    .font(.subheadline.weight(.semibold))
                if let detail = notice.detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            Button {
                model.dismissAgentNotice()
            } label: {
                Image(systemName: "xmark").font(.footnote.weight(.semibold))
            }
            .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.thinMaterial))
        .contentShape(Rectangle())
        .onTapGesture { model.open(notice) }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("agent-notice")
        .accessibilityAddTraits(.isButton)
    }
}

/// The Mac's schedules (#11), as the Mac's Schedules shows them: the runs
/// going on, every schedule by when it runs next, and the runs that are
/// over.
private struct SchedulesScreen: View {
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        let overview = ScheduleOverview(schedules: model.schedules, liveSessions: Set(model.sessions.map(\.id)))
        List {
            if !model.schedules.isEmpty {
                // Holds every schedule back, or lets them run again (#47).
                Section {
                    Toggle("Pause All Schedules", isOn: Binding(get: { model.schedulesPaused }, set: { model.pauseSchedules($0) }))
                        .accessibilityIdentifier("schedules-pause")
                } footer: {
                    if model.schedulesPaused { Text("Every schedule is paused: none runs until they are let go again.") }
                }
            }
            Section("Running") {
                if overview.running.isEmpty { Text("No run is going on.").foregroundStyle(.secondary) }
                ForEach(overview.running) { run in
                    // Opens the run's session.
                    Button {
                        guard let id = run.run.session else { return }
                        model.tab = "sessions"
                        model.path = [.session(id)]
                    } label: {
                        RunLabel(run: run, live: true)
                    }
                    .accessibilityIdentifier("run-\(run.id)")
                    .swipeActions {
                        Button("Stop", role: .destructive) { model.stop(run) }
                    }
                }
            }
            Section("Scheduled") {
                ForEach(overview.scheduled) { schedule in
                    HStack(spacing: 12) {
                        // On or off from the list, as on the Mac.
                        Toggle(
                            "\(schedule.name) on",
                            isOn: Binding(
                                get: { schedule.enabled },
                                set: { on in
                                    var changed = schedule
                                    changed.enabled = on
                                    model.save(changed)
                                })
                        )
                        .labelsHidden()
                        .accessibilityIdentifier("schedule-on-\(schedule.id)")
                        NavigationLink {
                            ScheduleForm(schedule: schedule, isNew: false)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(schedule.name)
                                Text("\(Self.name(of: schedule.agent, in: model.agents)) · \(schedule.when.label())").font(.footnote).foregroundStyle(.secondary)
                                Text(Self.status(schedule)).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("schedule-\(schedule.id)")
                    }
                    .swipeActions(edge: .leading) {
                        Button("Run Now") { model.runNow(schedule) }.tint(.green)
                    }
                    .contextMenu {
                        Button {
                            model.runNow(schedule)
                        } label: {
                            Label("Run Now", systemImage: "play")
                        }
                        Button {
                            model.duplicate(schedule)
                        } label: {
                            Label("Duplicate", systemImage: "plus.square.on.square")
                        }
                    }
                }
                if let first = model.agents.first(where: { $0.path != nil }), let folder = model.folders.first {
                    NavigationLink("New Schedule") {
                        ScheduleForm(
                            schedule: Schedule(name: "Every morning", agent: first.id, folder: folder, prompt: "", when: .daily(hour: 9, minute: 0)), isNew: true)
                    }
                    .accessibilityIdentifier("new-schedule")
                }
            }
            Section("Past Runs") {
                if overview.past.isEmpty { Text("None yet.").foregroundStyle(.secondary) }
                ForEach(overview.past) { run in
                    NavigationLink {
                        ScheduleForm(schedule: model.schedules.first { $0.id == run.schedule.id } ?? run.schedule, isNew: false)
                    } label: {
                        RunLabel(run: run, live: false)
                    }
                    .accessibilityIdentifier("run-\(run.id)")
                }
            }
        }
        .navigationTitle("Schedules")
    }

    static func name(of agent: String, in agents: [AgentInfo]) -> String { agents.first { $0.id == agent }?.name ?? agent }

    static func status(_ schedule: Schedule) -> String {
        var parts: [String] = []
        if !schedule.enabled { parts.append("Off") } else if let next = schedule.nextRun { parts.append("Next \(next.formatted(date: .abbreviated, time: .shortened))") }
        parts.append(schedule.permissions.label)
        if let last = schedule.runs.last { parts.append("Last: \(last.summary.lowercased())") }
        return parts.joined(separator: " · ")
    }
}

/// A run in a schedule's form; one going on opens its session.
private struct FormRunRow: View {
    @EnvironmentObject private var model: PhoneModel
    let run: ScheduleOverview.Run

    private var liveSession: SessionID? {
        guard let id = run.run.session, model.sessions.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    var body: some View {
        if let id = liveSession, run.run.ended == nil {
            Button {
                model.tab = "sessions"
                model.path = [.session(id)]
            } label: {
                RunLabel(run: run, live: true)
            }
            .swipeActions {
                Button("Stop", role: .destructive) { model.stop(run) }
            }
        } else if run.run.hasOutput {
            // What it printed, kept when it ended (#47).
            NavigationLink {
                RunOutputScreen(run: run)
            } label: {
                RunLabel(run: run, live: false)
            }
        } else {
            RunLabel(run: run, live: false)
        }
    }
}

/// What a run printed, with how it ended and what it changed.
private struct RunOutputScreen: View {
    @EnvironmentObject private var model: PhoneModel
    let run: ScheduleOverview.Run

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(run.run.at.formatted(date: .abbreviated, time: .shortened) + " · " + run.run.summary).font(.footnote).foregroundStyle(.secondary)
                if let changes = run.run.changes { Label(changes, systemImage: "arrow.triangle.branch").font(.footnote).foregroundStyle(.secondary) }
                if let worktree = run.run.worktree {
                    Label("In the worktree " + (worktree as NSString).lastPathComponent, systemImage: "folder").font(.footnote).foregroundStyle(.secondary)
                }
                switch model.runOutputs[run.id] {
                case .none:
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                case .some(.none):
                    Text("Nothing was kept of what this run printed.").font(.callout).foregroundStyle(.secondary)
                case .some(.some(let text)):
                    ScrollView(.horizontal) {
                        Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    }
                    .accessibilityIdentifier("run-output")
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(run.schedule.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.loadOutput(of: run) }
    }
}

/// A run of a schedule: its name, when, and what came of it.
private struct RunLabel: View {
    let run: ScheduleOverview.Run
    let live: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: live ? "circle.fill" : run.run.started ? "checkmark.circle" : "minus.circle")
                .font(live ? .system(size: 9) : .body)
                .foregroundStyle(live ? Color.green : run.run.started ? Color.secondary : Color.orange)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(run.schedule.name).foregroundStyle(.primary)
                Text(run.run.at.formatted(date: .abbreviated, time: .shortened) + " · " + (live ? "running" : run.run.summary))
                    .font(.footnote).foregroundStyle(.secondary)
                if !live, let changes = run.run.changes { Text(changes).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

private struct ScheduleForm: View {
    @EnvironmentObject private var model: PhoneModel
    @Environment(\.dismiss) private var dismiss
    @State var schedule: Schedule
    let isNew: Bool
    @State private var kind = 1
    @State private var time = Date()
    @State private var weekdays: Set<Int> = [2, 3, 4, 5, 6]
    @State private var warning = false
    /// Any folder of the Mac, not only those in the list, as on the Mac.
    @State private var choosingFolder = false
    /// Every so many minutes or hours, all day or between two times (#47).
    @State private var interval = 30
    @State private var inHours = false
    @State private var between = false
    @State private var from = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var until = Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var dates: [Date] = []
    @State private var limited = false
    @State private var longest = 30
    @State private var editingPrompt = false

    private var edits: [ScheduleEdit] { (model.schedules.first { $0.id == schedule.id }?.edits ?? []).reversed() }

    /// Every run the host kept, newest first, as they are now.
    private var runs: [ScheduleRun] { (model.schedules.first { $0.id == schedule.id }?.runs ?? schedule.runs).reversed() }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $schedule.name)
                Picker("Agent", selection: $schedule.agent) {
                    ForEach(model.agents.filter { $0.path != nil }) { Text($0.name).tag($0.id) }
                }
                Picker("Folder", selection: $schedule.folder) {
                    ForEach(model.folders, id: \.self) { Text(($0 as NSString).lastPathComponent).tag($0) }
                    // One chosen that is not in the list.
                    if !schedule.folder.isEmpty && !model.folders.contains(schedule.folder) {
                        Text((schedule.folder as NSString).lastPathComponent).tag(schedule.folder)
                    }
                }
                Button("Choose Another Folder…") { choosingFolder = true }
                    .accessibilityIdentifier("schedule-choose-folder")
                TextField("Prompt", text: $schedule.prompt, axis: .vertical).lineLimit(3...8)
                Button("Open the Prompt in a Larger Editor…") { editingPrompt = true }
                    .accessibilityIdentifier("schedule-prompt-editor")
            }
            Section {
                Picker("When", selection: $kind) {
                    Text("Once").tag(0)
                    Text("Every day").tag(1)
                    Text("On some days").tag(2)
                    Text("Every…").tag(4)
                    Text("On certain dates").tag(5)
                    Text("When the limit starts over").tag(3)
                }
                if kind == 4 {
                    Stepper("Every \(interval) \(inHours ? (interval == 1 ? "hour" : "hours") : (interval == 1 ? "minute" : "minutes"))", value: $interval, in: 1...720)
                    Picker("In", selection: $inHours) {
                        Text("Minutes").tag(false)
                        Text("Hours").tag(true)
                    }
                    .pickerStyle(.segmented)
                    Toggle("Only between two times", isOn: $between)
                    if between {
                        DatePicker("From", selection: $from, displayedComponents: .hourAndMinute)
                        DatePicker("Until", selection: $until, displayedComponents: .hourAndMinute)
                    }
                }
                if kind == 5 {
                    ForEach(dates.indices, id: \.self) { index in
                        DatePicker("On", selection: $dates[index])
                    }
                    .onDelete { dates.remove(atOffsets: $0) }
                    Button("Add a Date") { dates.append((dates.max() ?? Date()).addingTimeInterval(24 * 3600)) }
                }
                if kind == 0 { DatePicker("At", selection: $time) }
                if kind == 1 || kind == 2 { DatePicker("At", selection: $time, displayedComponents: .hourAndMinute) }
                if kind == 2 {
                    ForEach(1...7, id: \.self) { day in
                        Toggle(
                            Calendar.current.weekdaySymbols[day - 1],
                            isOn: Binding(get: { weekdays.contains(day) }, set: { on in if on { weekdays.insert(day) } else { weekdays.remove(day) } }))
                    }
                }
                Picker("Permissions", selection: $schedule.permissions) {
                    ForEach(SchedulePermissions.offered(by: schedule.agent), id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("Run once after a missed time", isOn: $schedule.catchUp)
                Toggle("On", isOn: $schedule.enabled)
            }
            Section {
                Picker("Starts", selection: $schedule.condition) {
                    ForEach(ScheduleCondition.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .accessibilityIdentifier("schedule-condition")
                Picker("While the run before is going", selection: $schedule.waitsForPrevious) {
                    Text("Skip the run").tag(false)
                    Text("Wait for it").tag(true)
                }
                Toggle("Stop a run that takes too long", isOn: $limited)
                if limited { Stepper("After \(longest) minutes", value: $longest, in: 1...1440, step: 5) }
                Toggle("Each run in a new worktree", isOn: $schedule.inWorktree)
                    .accessibilityIdentifier("schedule-worktree")
            } footer: {
                Text(schedule.condition.advice + (schedule.inWorktree ? " A run's worktree is kept afterwards, to be looked at, merged or thrown away from the folder's worktrees." : ""))
            }
            if !runs.isEmpty {
                Section("Runs") {
                    ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                        FormRunRow(run: ScheduleOverview.Run(schedule: schedule, run: run))
                    }
                }
            }
            if !edits.isEmpty {
                Section("Changes to This Schedule") {
                    ForEach(Array(edits.enumerated()), id: \.offset) { _, edit in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(edit.at.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            ForEach(edit.what, id: \.self) { Text($0).font(.footnote) }
                        }
                    }
                }
            }
            if !isNew {
                Section {
                    Button("Run Now") { model.runNow(schedule) }
                        .accessibilityIdentifier("schedule-run-now")
                    Button("Duplicate") {
                        model.duplicate(schedule)
                        dismiss()
                    }
                    Button("Delete Schedule", role: .destructive) {
                        model.removeSchedule(schedule.id)
                        dismiss()
                    }
                } footer: {
                    Text("Run Now and Duplicate use the schedule as it was last saved.")
                }
            }
        }
        .navigationTitle(isNew ? "New Schedule" : schedule.name)
        .sheet(isPresented: $editingPrompt) {
            PromptEditorSheet(prompt: $schedule.prompt, folder: schedule.folder)
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
        .toolbar {
            Button("Save") { save() }
                .disabled(
                    schedule.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || schedule.name.isEmpty || (kind == 2 && weekdays.isEmpty)
                        || (kind == 5 && dates.isEmpty))
        }
        .sheet(isPresented: $choosingFolder) {
            BrowseSheet(start: schedule.folder.isEmpty ? nil : schedule.folder, pickTitle: "Run Here") { schedule.folder = $0 }
        }
        .onAppear(perform: read)
        .onChange(of: schedule.agent) { _, agent in
            schedule.warningAccepted = false
            if !SchedulePermissions.offered(by: agent).contains(schedule.permissions) { schedule.permissions = .skipAll }
        }
        .alert("Run without asking for permission?", isPresented: $warning) {
            Button("Run Without Asking", role: .destructive) {
                schedule.warningAccepted = true
                save()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(SchedulePermissions.warning(agent: schedule.agent, name: SchedulesScreen.name(of: schedule.agent, in: model.agents)))
        }
    }

    private func read() {
        switch schedule.when {
        case .once(let moment): kind = 0; time = moment
        case .daily(let hour, let minute): kind = 1; time = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
        case .weekly(let days, let hour, let minute):
            kind = 2; weekdays = Set(days); time = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
        case .limitReset: kind = 3
        case .every(let minutes, let first, let last):
            kind = 4
            inHours = minutes % 60 == 0
            interval = inHours ? minutes / 60 : minutes
            between = first != nil || last != nil
            if let first { from = Calendar.current.date(bySettingHour: first / 60, minute: first % 60, second: 0, of: Date()) ?? from }
            if let last { until = Calendar.current.date(bySettingHour: last / 60, minute: last % 60, second: 0, of: Date()) ?? until }
        case .dates(let moments):
            kind = 5
            dates = moments.sorted()
        }
        limited = schedule.maxMinutes != nil
        longest = schedule.maxMinutes ?? 30
    }

    private func minutes(of time: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    private func save() {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        switch kind {
        case 0: schedule.when = .once(time)
        case 1: schedule.when = .daily(hour: parts.hour ?? 9, minute: parts.minute ?? 0)
        case 2: schedule.when = .weekly(weekdays: weekdays.sorted(), hour: parts.hour ?? 9, minute: parts.minute ?? 0)
        case 4: schedule.when = .every(minutes: interval * (inHours ? 60 : 1), from: between ? minutes(of: from) : nil, until: between ? minutes(of: until) : nil)
        case 5: schedule.when = .dates(dates.sorted())
        default: schedule.when = .limitReset
        }
        schedule.maxMinutes = limited ? longest : nil
        if schedule.permissions == .skipAll && !schedule.warningAccepted {
            warning = true
            return
        }
        model.save(schedule)
        dismiss()
    }
}

/// The prompt in a larger editor (#47), with the files of the schedule's
/// folder at hand: one that is picked is named in the prompt.
private struct PromptEditorSheet: View {
    @EnvironmentObject private var model: PhoneModel
    @Environment(\.dismiss) private var dismiss
    @Binding var prompt: String
    let folder: String
    @State private var query = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $prompt)
                    .font(.body)
                    .padding(8)
                    .accessibilityIdentifier("prompt-editor")
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Find a file of \((folder as NSString).lastPathComponent) to name", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("prompt-files")
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(model.foundFiles.prefix(30), id: \.self) { file in
                                Button {
                                    // Named as the agent will find it from its folder.
                                    prompt += (prompt.isEmpty || prompt.hasSuffix(" ") || prompt.hasSuffix("\n") ? "" : " ") + file
                                } label: {
                                    Label(file, systemImage: "plus.circle").font(.footnote).lineLimit(1).truncationMode(.head)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 6)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("prompt-file-" + file)
                            }
                        }
                    }
                    .frame(height: 150)
                }
                .padding(12)
            }
            .navigationTitle("Prompt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .task(id: query) { model.findFiles(query, in: folder) }
        .onDisappear { model.clearSearch() }
    }
}
