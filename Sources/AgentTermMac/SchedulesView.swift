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
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        section("Running", count: overview.running.count)
                        if overview.running.isEmpty { empty("No run is going on.") }
                        ForEach(overview.running) { run in RunRow(run: run, live: true) }
                        section("Scheduled", count: overview.scheduled.count)
                        ForEach(overview.scheduled) { schedule in ScheduleRow(schedule: schedule) }
                        section("Past Runs", count: overview.past.count)
                        if overview.past.isEmpty { empty("None yet.") }
                        ForEach(overview.past) { run in RunRow(run: run, live: false) }
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
                Text(ScheduleWords.next(schedule) + " · " + model.agentName(schedule.agent))
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
        .help("\(schedule.name): \(schedule.when.label()) in \((schedule.folder as NSString).abbreviatingWithTildeInPath)")
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("schedule-\(schedule.id)")
        .accessibilityAction { model.editingSchedule = schedule }
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

    private var line: String { ScheduleWords.when(run.run.at) + " · " + (live ? "running" : run.run.note) }
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
        .help(live ? "Show the run's session" : run.run.note)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityIdentifier("run-\(run.id)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
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
    static func next(_ schedule: Schedule) -> String {
        if !schedule.enabled { return "Off" }
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
                        if !model.isRemote {
                            Button("Choose…") { chooseFolder() }
                        }
                    }
                }
                GridRow(alignment: .top) {
                    Text("Prompt")
                    TextEditor(text: $schedule.prompt)
                        .font(.system(size: 12.5))
                        .frame(height: 64)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
                }
                GridRow {
                    Text("When")
                    HStack {
                        Picker("When", selection: $kind) {
                            Text("Once").tag(0)
                            Text("Every day").tag(1)
                            Text("On some days").tag(2)
                            Text("When the limit starts over").tag(3)
                        }
                        .labelsHidden()
                        .fixedSize()
                        if kind == 0 {
                            DatePicker("At", selection: $time).labelsHidden()
                        } else if kind == 1 || kind == 2 {
                            DatePicker("At", selection: $time, displayedComponents: .hourAndMinute).labelsHidden()
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
            }
            .font(.system(size: 12.5))
            .onChange(of: schedule.agent) { _, agent in
                // The warning names the agent: another agent, asked again.
                schedule.warningAccepted = false
                if !SchedulePermissions.offered(by: agent).contains(schedule.permissions) { schedule.permissions = .skipAll }
            }
            runs
            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) {
                        model.removeSchedule(schedule.id)
                        done()
                    }
                }
                Spacer()
                Button("Cancel") { done() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(schedule.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || schedule.name.isEmpty || (kind == 2 && weekdays.isEmpty))
            }
        }
        .padding(20)
        .onAppear(perform: read)
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
    /// the schedule was picked; one going on opens its session.
    @ViewBuilder
    private var runs: some View {
        let kept = (model.schedules.first { $0.id == schedule.id }?.runs ?? []).reversed()
        if !kept.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Runs").font(.system(size: 12, weight: .semibold))
                ForEach(Array(kept.enumerated()), id: \.offset) { _, run in
                    let session = run.session.flatMap { id in model.sessions.first { $0.id == id } }
                    HStack(spacing: 8) {
                        Image(systemName: session != nil ? "circle.fill" : run.started ? "checkmark.circle" : "minus.circle")
                            .font(.system(size: session != nil ? 7 : 11))
                            .foregroundStyle(session != nil ? Color.green : run.started ? Color.secondary : Color.orange)
                            .frame(width: 14)
                        Text(run.at.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 11.5)).monospacedDigit()
                        Text(session != nil ? "Running" : run.note).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        if let session {
                            Button("Show Session") {
                                model.show(.sessions, toggling: false)
                                model.select(session: session)
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
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
        }
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
        default: schedule.when = .limitReset
        }
        if schedule.permissions == .skipAll && !schedule.warningAccepted {
            warning = true
            return
        }
        model.save(schedule)
        done()
    }
}
