import AgentTermProtocol
import AppKit
import SwiftUI

/// The schedule picked or being made in Schedules, in the middle of the
/// window (#11). The host keeps the schedules and runs them; the iPhone
/// shows the same.
struct SchedulesView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let schedule = model.editingSchedule {
            ScrollView {
                ScheduleEditor(schedule: schedule, isNew: !model.schedules.contains { $0.id == schedule.id }) { model.editingSchedule = nil }
                    .frame(maxWidth: 680, alignment: .top)
                    .frame(maxWidth: .infinity)
            }
            .id(schedule.id)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "calendar.badge.clock").font(.system(size: 30)).foregroundStyle(.tertiary)
                Text("Choose a schedule").font(.system(size: 14, weight: .semibold))
                Text("Or make one with +: an agent started with a prompt at a set time, or when its limit starts over.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Schedules' list, at the window's left: the runs going on, every schedule
/// by when it runs next, and the runs that are over.
struct SchedulesSidebar: View {
    @EnvironmentObject private var model: AppModel

    private var overview: ScheduleOverview { ScheduleOverview(schedules: model.schedules, liveSessions: Set(model.sessions.map(\.id))) }
    private var canMake: Bool { !(model.agents.allSatisfy { $0.path == nil } || model.folders.isEmpty) }

    var body: some View {
        let overview = overview
        VStack(spacing: 0) {
            HStack {
                Text("SCHEDULES").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if !model.schedules.isEmpty {
                    // Holds every schedule back, or lets them run again (#47).
                    Button {
                        model.pauseSchedules(!model.schedulesPaused)
                    } label: {
                        Image(systemName: model.schedulesPaused ? "play.circle.fill" : "pause.circle").font(.system(size: 13))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(model.schedulesPaused ? Color.orange : Color.secondary)
                    .help(model.schedulesPaused ? "Let the schedules run again" : "Pause every schedule")
                    .accessibilityLabel(model.schedulesPaused ? "Resume All Schedules" : "Pause All Schedules")
                    .accessibilityIdentifier("schedules-pause")
                }
                Button {
                    model.editingSchedule = model.newSchedule()
                } label: {
                    Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(!canMake)
                .help(canMake ? "New Schedule" : "A schedule needs an agent installed and a folder in the list")
                .accessibilityLabel("New Schedule")
                .accessibilityIdentifier("new-schedule")
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)
            if model.schedules.isEmpty {
                Text("No schedules yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                Spacer(minLength: 0)
            } else {
                if model.schedulesPaused {
                    Label("Every schedule is paused: none runs until they are let go again.", systemImage: "pause.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 4)
                        .accessibilityIdentifier("schedules-paused")
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        section("Running", count: overview.running.count)
                        if overview.running.isEmpty { empty("No run is going on.") }
                        // A run that ends moves to the list below: a row of its own
                        // there, not this one carried over still saying "running".
                        ForEach(overview.running) { run in RunRow(run: run, live: true).id("running-" + run.id) }
                        section("Scheduled", count: overview.scheduled.count)
                        ForEach(overview.scheduled) { schedule in ScheduleRow(schedule: schedule) }
                        section("Past Runs", count: overview.past.count)
                        if overview.past.isEmpty { empty("None yet.") }
                        ForEach(overview.past) { run in RunRow(run: run, live: false).id("past-" + run.id) }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 10)
                }
            }
        }
        .background(Theme.panel)
    }

    private func section(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.tertiary)
            Text("\(count)").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 6)
        .padding(.top, 12)
        .padding(.bottom, 2)
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(.tertiary).padding(.horizontal, 6).padding(.vertical, 3)
    }
}

/// A schedule in the list: on or off, its name, when it runs next.
private struct ScheduleRow: View {
    @EnvironmentObject private var model: AppModel
    let schedule: Schedule
    @State private var hovering = false

    private var selected: Bool { model.editingSchedule?.id == schedule.id }

    var body: some View {
        HStack(spacing: 8) {
            Toggle(
                "",
                isOn: Binding(
                    get: { schedule.enabled },
                    set: { on in
                        var changed = schedule
                        changed.enabled = on
                        model.save(changed)
                    })
            )
            .labelsHidden().toggleStyle(.switch).controlSize(.mini)
            .accessibilityLabel("\(schedule.name) on")
            VStack(alignment: .leading, spacing: 1) {
                Text(schedule.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Text(ScheduleWords.next(schedule, paused: model.schedulesPaused) + " · " + model.agentName(schedule.agent))
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Color.white.opacity(0.11) : (hovering ? Color.white.opacity(0.05) : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.editingSchedule = schedule }
        .contextMenu {
            Button("Run Now") { model.runNow(schedule) }
            Button("Duplicate") { model.duplicate(schedule) }
            Divider()
            Button("Delete", role: .destructive) {
                if model.editingSchedule?.id == schedule.id { model.editingSchedule = nil }
                model.removeSchedule(schedule.id)
            }
        }
        .help("\(schedule.name): \(schedule.when.label()) in \((schedule.folder as NSString).abbreviatingWithTildeInPath)")
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("schedule-\(schedule.id)")
        .accessibilityAction { model.editingSchedule = schedule }
        .accessibilityAction(named: "Run Now") { model.runNow(schedule) }
        .accessibilityAction(named: "Duplicate") { model.duplicate(schedule) }
    }
}

/// A run in the list: one going on opens its session, one that is over its
/// schedule.
private struct RunRow: View {
    @EnvironmentObject private var model: AppModel
    let run: ScheduleOverview.Run
    let live: Bool
    @State private var hovering = false

    private var symbol: (String, Color) {
        if live { return ("circle.fill", .green) }
        return run.run.started ? ("checkmark.circle", .secondary) : ("minus.circle", .orange)
    }

    private var line: String { ScheduleWords.when(run.run.at) + " · " + (live ? "running" : run.run.summary) }
    private var label: String { "\(run.schedule.name), \(line)" }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol.0).font(.system(size: live ? 7 : 11)).foregroundStyle(symbol.1).frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(run.schedule.name).font(.system(size: 12.5)).lineLimit(1)
                Text(line).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Color.white.opacity(0.05) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .contextMenu {
            if live { Button("Stop This Run", role: .destructive) { model.stop(run) } }
            if run.run.hasOutput { Button("What It Printed…") { model.shownRun = run } }
        }
        .help(live ? "Show the run's session" : run.run.summary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityIdentifier("run-\(run.id)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
        .accessibilityAction(named: "Stop") { model.stop(run) }
    }

    private func open() {
        if live, let id = run.run.session, let session = model.sessions.first(where: { $0.id == id }) {
            model.show(.sessions, toggling: false)
            model.select(session: session)
        } else {
            model.editingSchedule = model.schedules.first { $0.id == run.schedule.id } ?? run.schedule
        }
    }
}

/// Words both views of a schedule use.
enum ScheduleWords {
    /// "today 9:00 AM", "tomorrow 9:00 AM", "Mon 9:00 AM", "Dec 3 9:00 AM".
    static func when(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "today \(time)" }
        if calendar.isDateInTomorrow(date) { return "tomorrow \(time)" }
        if let days = calendar.dateComponents([.day], from: now, to: date).day, days < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated)) + " \(time)"
        }
        return date.formatted(.dateTime.month(.abbreviated).day()) + " \(time)"
    }

    /// "Next today 9:00 AM", "Off", "Waits for the limit to start over".
    static func next(_ schedule: Schedule, paused: Bool = false) -> String {
        if !schedule.enabled { return "Off" }
        if paused { return "Paused" }
        if let next = schedule.nextRun { return "Next " + when(next) }
        if case .limitReset = schedule.when { return "When the limit starts over" }
        return "Not again"
    }

    static func status(_ schedule: Schedule) -> String {
        var parts: [String] = []
        if !schedule.enabled {
            parts.append("Off")
        } else if let next = schedule.nextRun {
            parts.append("Next " + when(next))
        }
        parts.append(schedule.permissions.label)
        return parts.joined(separator: " · ")
    }
}

private struct ScheduleEditor: View {
    @EnvironmentObject private var model: AppModel
    @State var schedule: Schedule
    let isNew: Bool
    let done: () -> Void
    @State private var kind = 1
    @State private var time = Date()
    @State private var weekdays: Set<Int> = [2, 3, 4, 5, 6]
    @State private var warning = false
    @State private var browsing = false
    /// Every so many minutes or hours, all day or between two times (#47).
    @State private var interval = 30
    @State private var inHours = false
    @State private var between = false
    @State private var from = ScheduleEditor.time(9, 0)
    @State private var until = ScheduleEditor.time(18, 0)
    /// The moments of a schedule that runs on certain dates.
    @State private var dates: [Date] = []
    @State private var limited = false
    @State private var longest = 30
    @State private var editingPrompt = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "New Schedule" : "Edit Schedule").font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Name").gridColumnAlignment(.trailing)
                    TextField("Name", text: $schedule.name).labelsHidden()
                }
                GridRow {
                    Text("Agent")
                    Picker("Agent", selection: $schedule.agent) {
                        ForEach(model.agents.filter { $0.path != nil }) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                GridRow {
                    Text("Folder")
                    HStack {
                        Picker("Folder", selection: $schedule.folder) {
                            ForEach(model.folders, id: \.path) { Text($0.name).tag($0.path) }
                            // One chosen that is not in the list.
                            if !model.folders.contains(where: { $0.path == schedule.folder }) && !schedule.folder.isEmpty {
                                Text((schedule.folder as NSString).lastPathComponent).tag(schedule.folder)
                            }
                        }
                        .labelsHidden()
                        .help(schedule.folder)
                        // Another Mac's folders through its host.
                        Button("Choose…") { if model.isRemote { browsing = true } else { chooseFolder() } }
                    }
                }
                GridRow(alignment: .top) {
                    Text("Prompt")
                    VStack(alignment: .leading, spacing: 5) {
                        TextEditor(text: $schedule.prompt)
                            .font(.system(size: 12.5))
                            .frame(height: 64)
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
                        Button("Open in a Larger Editor…") { editingPrompt = true }
                            .buttonStyle(.link)
                            .font(.system(size: 11.5))
                            .accessibilityIdentifier("schedule-prompt-editor")
                    }
                }
                GridRow {
                    Text("When")
                    HStack {
                        Picker("When", selection: $kind) {
                            Text("Once").tag(0)
                            Text("Every day").tag(1)
                            Text("On some days").tag(2)
                            Text("Every…").tag(4)
                            Text("On certain dates").tag(5)
                            Text("When the limit starts over").tag(3)
                        }
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityIdentifier("schedule-when")
                        if kind == 0 {
                            DatePicker("At", selection: $time).labelsHidden()
                        } else if kind == 1 || kind == 2 {
                            DatePicker("At", selection: $time, displayedComponents: .hourAndMinute).labelsHidden()
                        } else if kind == 4 {
                            TextField("", value: $interval, format: .number).frame(width: 44).multilineTextAlignment(.trailing)
                                .accessibilityIdentifier("schedule-interval")
                            Picker("Unit", selection: $inHours) {
                                Text("minutes").tag(false)
                                Text("hours").tag(true)
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                }
                if kind == 4 {
                    GridRow {
                        Text("")
                        HStack {
                            Toggle("Only between", isOn: $between)
                            DatePicker("From", selection: $from, displayedComponents: .hourAndMinute).labelsHidden().disabled(!between)
                            Text("and")
                            DatePicker("Until", selection: $until, displayedComponents: .hourAndMinute).labelsHidden().disabled(!between)
                        }
                    }
                }
                if kind == 5 {
                    GridRow(alignment: .top) {
                        Text("")
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(dates.indices, id: \.self) { index in
                                HStack {
                                    DatePicker("On", selection: $dates[index]).labelsHidden()
                                    Button {
                                        dates.remove(at: index)
                                    } label: {
                                        Image(systemName: "minus.circle")
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("Remove This Date")
                                }
                            }
                            Button("Add a Date") { dates.append((dates.max() ?? Date()).addingTimeInterval(24 * 3600)) }
                                .controlSize(.small)
                        }
                    }
                }
                if kind == 2 {
                    GridRow {
                        Text("")
                        HStack(spacing: 4) {
                            ForEach(1...7, id: \.self) { day in
                                Toggle(
                                    Calendar.current.veryShortWeekdaySymbols[day - 1],
                                    isOn: Binding(get: { weekdays.contains(day) }, set: { on in if on { weekdays.insert(day) } else { weekdays.remove(day) } })
                                )
                                .toggleStyle(.button)
                            }
                        }
                    }
                }
                GridRow {
                    Text("Permissions")
                    Picker("Permissions", selection: $schedule.permissions) {
                        ForEach(SchedulePermissions.offered(by: schedule.agent), id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                GridRow {
                    Text("")
                    Toggle("Run once when the Mac wakes after a missed time", isOn: $schedule.catchUp)
                }
                GridRow(alignment: .top) {
                    Text("Starts")
                    VStack(alignment: .leading, spacing: 3) {
                        Picker("Starts", selection: $schedule.condition) {
                            ForEach(ScheduleCondition.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityIdentifier("schedule-condition")
                        Text(schedule.condition.advice).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                GridRow {
                    Text("")
                    Picker("While the run before it is still going", selection: $schedule.waitsForPrevious) {
                        Text("skip the run").tag(false)
                        Text("wait for it to end").tag(true)
                    }
                    .fixedSize()
                }
                GridRow {
                    Text("")
                    HStack {
                        Toggle("Stop a run that takes longer than", isOn: $limited)
                        TextField("", value: $longest, format: .number).frame(width: 44).multilineTextAlignment(.trailing).disabled(!limited)
                        Text("minutes")
                    }
                }
                GridRow(alignment: .top) {
                    Text("")
                    VStack(alignment: .leading, spacing: 3) {
                        Toggle("Each run in a new worktree of its own", isOn: $schedule.inWorktree)
                            .accessibilityIdentifier("schedule-worktree")
                        Text(
                            "On a branch of its own, so that what a run changes does not mix with the folder's. The worktree is kept afterwards, to be looked at, merged or thrown away from the folder's worktree bar."
                        )
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.system(size: 12.5))
            .onChange(of: schedule.agent) { _, agent in
                // The warning names the agent: another agent, asked again.
                schedule.warningAccepted = false
                if !SchedulePermissions.offered(by: agent).contains(schedule.permissions) { schedule.permissions = .skipAll }
            }
            runs
            edits
            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) {
                        model.removeSchedule(schedule.id)
                        done()
                    }
                    Button("Duplicate") { model.duplicate(schedule) }
                        .help("A copy of it as it was last saved, turned off, to be changed")
                    Button("Run Now") { model.runNow(schedule) }
                        .help("Start a run of it as it was last saved, whatever its time")
                        .accessibilityIdentifier("schedule-run-now")
                }
                Spacer()
                Button("Cancel") { done() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        schedule.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || schedule.name.isEmpty || (kind == 2 && weekdays.isEmpty)
                            || (kind == 5 && dates.isEmpty))
            }
        }
        .padding(20)
        .onAppear(perform: read)
        .sheet(isPresented: $browsing) {
            BrowseFoldersSheet(onPick: { schedule.folder = $0 }, start: schedule.folder.isEmpty ? nil : schedule.folder, pickTitle: "Run Here")
        }
        .sheet(isPresented: $editingPrompt) {
            PromptEditorSheet(prompt: $schedule.prompt, folder: schedule.folder, search: model.promptSearch)
        }
        .sheet(item: $model.shownRun) { run in RunOutputSheet(run: run) }
        // Said plainly before a schedule may run without asking (#11).
        .alert("Run without asking for permission?", isPresented: $warning) {
            Button("Run Without Asking", role: .destructive) {
                schedule.warningAccepted = true
                save()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(SchedulePermissions.warning(agent: schedule.agent, name: model.agentName(schedule.agent)))
        }
    }

    /// Every run the host kept, newest first, as it is now rather than when
    /// the schedule was picked: one going on opens its session and can be
    /// stopped; one that is over says how it ended, how long it took and
    /// what it changed, and shows what it printed (#47).
    @ViewBuilder
    private var runs: some View {
        let current = model.schedules.first { $0.id == schedule.id } ?? schedule
        let kept = current.runs.reversed()
        if !kept.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Runs").font(.system(size: 12, weight: .semibold))
                ForEach(Array(kept.enumerated()), id: \.offset) { _, run in
                    let session = run.session.flatMap { id in model.sessions.first { $0.id == id } }
                    let live = session != nil && run.ended == nil
                    let whole = ScheduleOverview.Run(schedule: current, run: run)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: live ? "circle.fill" : run.started ? "checkmark.circle" : "minus.circle")
                            .font(.system(size: live ? 7 : 11))
                            .foregroundStyle(live ? Color.green : run.started ? Color.secondary : Color.orange)
                            .frame(width: 14)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text(run.at.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 11.5)).monospacedDigit()
                                Text(live ? "Running" : run.summary).font(.system(size: 11.5)).foregroundStyle(.secondary)
                            }
                            if let changes = run.changes {
                                Label(changes, systemImage: "arrow.triangle.branch").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            if let worktree = run.worktree {
                                Label("In the worktree " + (worktree as NSString).lastPathComponent, systemImage: "folder").font(.system(size: 11)).foregroundStyle(.secondary)
                                    .help(worktree)
                            }
                        }
                        Spacer(minLength: 0)
                        if let session {
                            Button("Show Session") {
                                model.show(.sessions, toggling: false)
                                model.select(session: session)
                            }
                            .controlSize(.small)
                        }
                        if live {
                            Button("Stop", role: .destructive) { model.stop(whole) }
                                .controlSize(.small)
                                .accessibilityLabel("Stop the run")
                        }
                        if run.hasOutput {
                            Button("Output") { model.shownRun = whole }
                                .controlSize(.small)
                                .help("What the run printed, kept when it ended")
                                .accessibilityLabel("Show the run's output")
                        }
                    }
                    .accessibilityElement(children: .contain)
                }
            }
            .accessibilityIdentifier("schedule-runs")
        }
    }

    /// What was changed about the schedule, and when, newest first.
    @ViewBuilder
    private var edits: some View {
        let kept = (model.schedules.first { $0.id == schedule.id }?.edits ?? []).reversed()
        if !kept.isEmpty {
            DisclosureGroup("Changes to this schedule (\(kept.count))") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(kept.enumerated()), id: \.offset) { _, edit in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(edit.at.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                            ForEach(edit.what, id: \.self) { Text($0).font(.system(size: 11.5)) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }
            .font(.system(size: 12, weight: .semibold))
            .accessibilityIdentifier("schedule-edits")
        }
    }

    /// Any folder of this Mac, not only those in the list.
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "The folder the agent runs in"
        if !schedule.folder.isEmpty { panel.directoryURL = URL(fileURLWithPath: schedule.folder) }
        if panel.runModal() == .OK, let url = panel.url { schedule.folder = url.path }
    }

    private func read() {
        switch schedule.when {
        case .once(let moment): kind = 0; time = moment
        case .daily(let hour, let minute): kind = 1; time = Self.time(hour, minute)
        case .weekly(let days, let hour, let minute): kind = 2; time = Self.time(hour, minute); weekdays = Set(days)
        case .limitReset: kind = 3
        case .every(let minutes, let first, let last):
            kind = 4
            inHours = minutes % 60 == 0
            interval = inHours ? minutes / 60 : minutes
            between = first != nil || last != nil
            if let first { from = Self.time(first / 60, first % 60) }
            if let last { until = Self.time(last / 60, last % 60) }
        case .dates(let moments):
            kind = 5
            dates = moments.sorted()
        }
        limited = schedule.maxMinutes != nil
        longest = schedule.maxMinutes ?? 30
    }

    private static func minutes(of time: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    private static func time(_ hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
    }

    private func save() {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        switch kind {
        case 0: schedule.when = .once(time)
        case 1: schedule.when = .daily(hour: parts.hour ?? 9, minute: parts.minute ?? 0)
        case 2: schedule.when = .weekly(weekdays: weekdays.sorted(), hour: parts.hour ?? 9, minute: parts.minute ?? 0)
        case 4:
            schedule.when = .every(
                minutes: max(interval, 1) * (inHours ? 60 : 1), from: between ? Self.minutes(of: from) : nil, until: between ? Self.minutes(of: until) : nil)
        case 5: schedule.when = .dates(dates.sorted())
        default: schedule.when = .limitReset
        }
        schedule.maxMinutes = limited ? max(longest, 1) : nil
        if schedule.permissions == .skipAll && !schedule.warningAccepted {
            warning = true
            return
        }
        model.save(schedule)
        done()
    }
}

/// What a run printed, kept when it ended (#47), with how it ended and
/// what it changed.
private struct RunOutputSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let run: ScheduleOverview.Run

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.schedule.name).font(.headline)
                    Text(run.run.at.formatted(date: .abbreviated, time: .shortened) + " · " + run.run.summary)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    if let changes = run.run.changes { Text(changes).font(.system(size: 12)).foregroundStyle(.secondary) }
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            switch model.runOutputs[run.id] {
            case .none:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .some(.none):
                Text("Nothing was kept of what this run printed.").font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .some(.some(let text)):
                ScrollView([.vertical, .horizontal]) {
                    Text(text)
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.canvas))
                .accessibilityIdentifier("run-output")
            }
        }
        .padding(18)
        .frame(width: 760, height: 520)
        .onAppear { model.loadOutput(of: run) }
    }
}

/// The prompt in a larger editor (#47), with the files of the schedule's
/// folder at hand: one that is picked is named in the prompt.
private struct PromptEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var prompt: String
    let folder: String
    @ObservedObject var search: SearchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Prompt").font(.headline)
            HStack(alignment: .top, spacing: 12) {
                TextEditor(text: $prompt)
                    .font(.system(size: 13))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
                    .accessibilityIdentifier("prompt-editor")
                VStack(alignment: .leading, spacing: 6) {
                    Text("Files of \((folder as NSString).lastPathComponent)").font(.system(size: 12, weight: .semibold))
                    TextField("Find a file by name", text: $search.query)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("prompt-files")
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(search.files, id: \.self) { file in
                                Button {
                                    // Named as the agent will find it from its folder.
                                    prompt += (prompt.isEmpty || prompt.hasSuffix(" ") || prompt.hasSuffix("\n") ? "" : " ") + file
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: "plus.circle").font(.system(size: 10.5)).foregroundStyle(.secondary)
                                        Text(file).font(.system(size: 11.5)).lineLimit(1).truncationMode(.head)
                                        Spacer(minLength: 0)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Add \(file) to the prompt")
                                .accessibilityIdentifier("prompt-file-" + file)
                            }
                        }
                    }
                    Text(TextMatch.summary(ofFiles: search.files.count, among: search.among, query: search.query))
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                .frame(width: 250)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 820, height: 520)
        .onAppear {
            search.setRoot(folder)
            search.show(.names)
        }
        .onDisappear { search.hide() }
    }
}
