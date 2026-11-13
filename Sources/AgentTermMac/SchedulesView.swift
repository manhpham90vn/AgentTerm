import AgentTermProtocol
import AppKit
import SwiftUI

/// The schedules of the Mac on screen (#11): a list, and a sheet to make or
/// change one. The host keeps them and runs them; the iPhone shows the same.
struct SchedulesView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let schedule = model.editingSchedule {
            // In the pane rather than a sheet: a sheet keeps the window from
            // closing, and was shown again when it reopened.
            ScheduleEditor(schedule: schedule, isNew: !model.schedules.contains { $0.id == schedule.id }) { model.editingSchedule = nil }
                .id(schedule.id)
                .frame(width: 600, height: 460, alignment: .top)
        } else {
            list
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                SettingsHeader(
                    symbol: "calendar.badge.clock", tint: .blue, title: "Schedules",
                    subtitle: "Start an agent with a prompt at a set time, or when its limit starts over.")
                Spacer(minLength: 12)
                Button("New Schedule…") { model.editingSchedule = model.newSchedule() }
                    .disabled(model.agents.allSatisfy { $0.path == nil } || model.folders.isEmpty)
                    .accessibilityIdentifier("new-schedule")
            }
            if model.schedules.isEmpty {
                Text("No schedules yet.").foregroundStyle(.secondary).font(.system(size: 12.5))
                Spacer(minLength: 0)
            } else {
                List(model.schedules) { schedule in
                    HStack(spacing: 10) {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { schedule.enabled },
                                set: { on in
                                    var changed = schedule; changed.enabled = on; model.save(changed)
                                })
                        )
                        .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                        .accessibilityLabel("\(schedule.name) on")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(schedule.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                            Text("\(model.agentName(schedule.agent)) in \((schedule.folder as NSString).lastPathComponent) · \(schedule.when.label())")
                                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            Text(ScheduleWords.status(schedule)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Button("Edit") { model.editingSchedule = schedule }.controlSize(.small)
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
            }
        }
        .padding(20)
        .frame(width: 600, height: 460, alignment: .top)
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
            if !schedule.runs.isEmpty {
                DisclosureGroup("Last runs") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(schedule.runs.suffix(5).reversed().enumerated()), id: \.offset) { _, run in
                            Text("\(run.at.formatted(date: .abbreviated, time: .shortened)): \(run.note)").font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 12))
            }
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
