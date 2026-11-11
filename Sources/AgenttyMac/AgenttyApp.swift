import SwiftUI

@main
struct AgenttyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Agentty", id: "main") {
            RootView()
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
                Divider()
                Button("Add Folder…") { model.addFolder() }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                SaveCommand(files: model.files)
            }
            CommandMenu("Session") {
                // Command and a number shows the tab in that place.
                ForEach(Array(model.sessions.prefix(9).enumerated()), id: \.element.id) { index, session in
                    Button(session.displayName) { model.selectSession(number: index + 1) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
                if !model.sessions.isEmpty { Divider() }
                Button("Next Session") { model.selectSession(offset: 1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                    .disabled(model.sessions.count < 2)
                Button("Previous Session") { model.selectSession(offset: -1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                    .disabled(model.sessions.count < 2)
                Divider()
                Button("End Session") { if let id = model.selectedSession { model.close(id) } }
                    .keyboardShortcut("w")
                    .disabled(model.selectedSession == nil)
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
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when started with `swift run` instead of from an app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// File > Save, for the file open in the Files tab. Its own view so the menu
/// item follows the file's unsaved state.
private struct SaveCommand: View {
    @ObservedObject var files: FilesModel

    var body: some View {
        Button("Save") { files.save() }
            .keyboardShortcut("s")
            .disabled(files.document?.isDirty != true)
    }
}
