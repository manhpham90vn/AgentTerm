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

    private var names: [String] {
        model.sessions.map(\.displayName) + files.documents.map(\.name)
            + (model.diffTabFile.map { ["Diff of " + ($0.path as NSString).lastPathComponent] } ?? [])
    }

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
        Button(model.diffInFront ? "Close Diff" : (files.active != nil ? "Close File" : "End Session")) { model.closeFrontTab() }
            .keyboardShortcut("w")
            .disabled(!model.diffInFront && files.active == nil && model.selectedSession == nil)
        Button("Close Other Files") { model.closeFileTabs(except: files.active, keepDiff: model.diffInFront) }
            .keyboardShortcut("w", modifiers: [.command, .option])
            .disabled(files.documents.isEmpty && model.diffTabFile == nil)
        Button("Close All Files") { model.closeFileTabs() }
            .keyboardShortcut("w", modifiers: [.command, .shift])
            .disabled(files.documents.isEmpty && model.diffTabFile == nil)
        Button(model.sessions.isEmpty ? "Close All" : "Close All and End Sessions…") { model.closeAllTabs() }
            .disabled(model.tabCount == 0)
    }
}
