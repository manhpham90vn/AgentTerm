import SwiftUI

@main
struct AgenttyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Agentty", id: "main") {
            RootView()
                .environmentObject(model)
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
