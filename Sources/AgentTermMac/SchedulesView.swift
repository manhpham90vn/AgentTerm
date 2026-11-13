import AgentTermProtocol
import SwiftUI

/// The schedules of the Mac on screen (#11): a list, and a sheet to make or
/// change one. The host keeps them and runs them; the iPhone shows the same.
struct SchedulesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editing: Schedule?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsHeader(
                symbol: "calendar.badge.clock", tint: .blue, title: "Schedules",
                subtitle: "Start an agent with a prompt in a folder at a set time, every day or on some days, or when its account's limit starts over.")
            if model.schedules.isEmpty {
                Text("No schedules yet.").foregroundStyle(.secondary).font(.system(size: 12.5))
            }
            ForEach(model.schedules) { schedule in
                SettingsCard {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(schedule.name).font(.system(size: 13, weight: .medium))
                            Text("\(model.agentName(schedule.agent)) in \((schedule.folder as NSString).lastPathComponent) · \(schedule.when.label())")
                                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                            Text(ScheduleWords.status(schedule)).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(get: { schedule.enabled }, set: { on in var changed = schedule; changed.enabled = on; model.save(changed) }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                            .accessibilityLabel("\(schedule.name) on")
                        Button("Edit") { editing = schedule }
                    }
                }
            }
            Button("New Schedule…") { editing = model.newSchedule() }
                .disabled(model.agents.allSatisfy { $0.path == nil } || model.folders.isEmpty)
                .accessibilityIdentifier("new-schedule")
            Spacer()
        }
        .padding(20)
        .sheet(item: $editing) { schedule in
            ScheduleEditor(schedule: schedule, isNew: !model.schedules.contains { $0.id == schedule.id }) { editing = nil }
        }
    }
}

/// Words both views of a schedule use.
enum ScheduleWords {
    static func status(_ schedule: Schedule) -> String {
        var parts: [String] = []
        if !schedule.enabled { parts.append("Off") } else if let next = schedule.nextRun {
            parts.append("Next \(next.formatted(date: .abbreviated, time: .shortened))")
        }
        parts.append(schedule.permissions.label)
        if let last = schedule.runs.last { parts.append("Last: \(last.note.lowercased()), \(last.at.formatted(date: .abbreviated, time: .shortened))") }
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
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "New Schedule" : "Edit Schedule").font(.headline)
            Form {
                TextField("Name", text: $schedule.name)
                Picker("Agent", selection: $schedule.agent) {
                    ForEach(model.agents.filter { $0.path != nil }) { Text($0.name).tag($0.id) }
                }
                .onChange(of: schedule.agent) { _, agent in
                    // The warning names the agent: another agent, asked again.
                    schedule.warningAccepted = false
                    if !SchedulePermissions.offered(by: agent).contains(schedule.permissions) { schedule.permissions = .skipAll }
                }
                Picker("Folder", selection: $schedule.folder) {
                    ForEach(model.folders, id: \.path) { Text($0.name).tag($0.path) }
                }
                TextField("Prompt", text: $schedule.prompt, axis: .vertical).lineLimit(3...8)
                Picker("When", selection: $kind) {
                    Text("Once").tag(0)
                    Text("Every day").tag(1)
                    Text("On some days").tag(2)
                    Text("When the limit starts over").tag(3)
                }
                if kind == 0 {
                    DatePicker("At", selection: $time)
                } else if kind == 1 || kind == 2 {
                    DatePicker("At", selection: $time, displayedComponents: .hourAndMinute)
                }
                if kind == 2 {
                    HStack {
                        ForEach(1...7, id: \.self) { day in
                            Toggle(Calendar.current.veryShortWeekdaySymbols[day - 1], isOn: Binding(get: { weekdays.contains(day) }, set: { on in if on { weekdays.insert(day) } else { weekdays.remove(day) } }))
                                .toggleStyle(.button)
                        }
                    }
                }
                Picker("Permissions", selection: $schedule.permissions) {
                    ForEach(SchedulePermissions.offered(by: schedule.agent), id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("Run once when the Mac wakes after a missed time", isOn: $schedule.catchUp)
            }
            if !schedule.runs.isEmpty {
                Text("Last runs").font(.system(size: 12, weight: .semibold))
                ForEach(Array(schedule.runs.suffix(5).reversed().enumerated()), id: \.offset) { _, run in
                    Text("\(run.at.formatted(date: .abbreviated, time: .shortened)): \(run.note)").font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
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
        .frame(width: 520)
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
