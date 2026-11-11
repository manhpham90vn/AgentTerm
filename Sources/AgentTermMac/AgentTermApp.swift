import AgentTermProtocol
import SwiftUI

@main
struct AgentTermApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    /// Stay in the menu bar when the window is closed, instead of quitting.
    @AppStorage(MenuBarMode.key) private var staysInMenuBar = MenuBarMode.defaultValue

    var body: some Scene {
        Window(AppChannel.current.appName, id: "main") {
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

        // The icon in the menu bar, while the setting is on.
        MenuBarExtra(AppChannel.current.appName, systemImage: AppChannel.current == .release ? "terminal.fill" : "terminal", isInserted: $staysInMenuBar) {
            MenuBarMenu(model: model)
        }

        Settings {
            SettingsView()
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
        Divider()
        Button("Pair iPhone…") {
            showWindow()
            model.showPairing = true
        }
        SettingsLink { Text("Settings…") }
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

private struct SettingsView: View {
    @AppStorage(MenuBarMode.key) private var staysInMenuBar = MenuBarMode.defaultValue

    var body: some View {
        Form {
            Toggle("Keep AgentTerm in the menu bar when its window is closed", isOn: $staysInMenuBar)
            Text(staysInMenuBar
                ? "Closing the window leaves AgentTerm running, with an icon in the menu bar to open it again. Quit it from that menu or with ⌘Q."
                : "Closing the window quits AgentTerm. Sessions keep running either way: the host that holds them is a separate program.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .frame(width: 460)
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
        Button("Close Everything Else…") {
            model.closeTabs(.init(
                keepSession: model.diffInFront || files.active != nil ? nil : model.selectedSession,
                keepFile: model.diffInFront ? nil : files.active, keepDiff: model.diffInFront
            ))
        }
        .disabled(model.tabCount < 2)
        Button(model.sessions.isEmpty ? "Close All" : "Close All and End Sessions…") { model.closeTabs() }
            .disabled(model.tabCount == 0)
    }
}
