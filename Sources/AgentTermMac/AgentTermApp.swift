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
            SettingsTabs()
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
        SettingsLink { Text("Settings and Permissions…") }
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

/// The panes of the Settings window. The one last looked at comes back.
private struct SettingsTabs: View {
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            SettingsView().tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            PermissionsView().tabItem { Label("Permissions", systemImage: "lock.shield") }.tag("permissions")
        }
    }
}

private struct SettingsView: View {
    @AppStorage(MenuBarMode.key) private var staysInMenuBar = MenuBarMode.defaultValue

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsHeader(symbol: "gearshape.fill", tint: .gray, title: "General", subtitle: "How \(AppChannel.current.appName) behaves on this Mac.")
            SettingsCard {
                Toggle(isOn: $staysInMenuBar) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Stay in the menu bar when the window is closed")
                            .font(.system(size: 13, weight: .medium))
                        Text(
                            staysInMenuBar
                                ? "Closing the window leaves the app running, with an icon in the menu bar to open it again. Quit from that menu or with ⌘Q."
                                : "Closing the window quits the app. Sessions keep running either way: the host that holds them is a separate program."
                        )
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
            }
            SettingsCard {
                HStack {
                    Text("Version").font(.system(size: 13, weight: .medium))
                    Spacer()
                    // The iPhone app has to be of a version that speaks the same protocol.
                    Text("\(AppVersion.current) · protocol \(agenttermProtocolVersion)")
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(24)
        .frame(width: 600, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Title of a settings pane: a tinted tile, a name and a line about it.
struct SettingsHeader: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.gradient))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 17, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A rounded panel that groups related settings.
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
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

    private var names: [String] { model.visibleTabs.map(model.tabName) }

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
        let front = model.frontTabID
        Button(front.map(model.tabLayout.isPinned) == true ? "Unpin Tab" : "Pin Tab") {
            if let front { model.setTabPinned(front, !model.tabLayout.isPinned(front)) }
        }
        .disabled(front == nil)
        Button("Add Tab to New Group") { if let front { model.newTabGroup(with: front) } }
            .disabled(front == nil)
        Button("Move Tab Left") { if let front { model.moveTab(front, by: -1) } }
            .keyboardShortcut("[", modifiers: [.command, .control, .shift])
            .disabled(model.tabCount < 2)
        Button("Move Tab Right") { if let front { model.moveTab(front, by: 1) } }
            .keyboardShortcut("]", modifiers: [.command, .control, .shift])
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
        Button("Close Other Tabs…") {
            model.closeTabs(
                .init(
                    keepSession: model.diffInFront || files.active != nil ? nil : model.selectedSession,
                    keepFile: model.diffInFront ? nil : files.active, keepDiff: model.diffInFront
                ))
        }
        .disabled(model.tabCount < 2)
        Button(model.sessions.isEmpty ? "Close All Tabs" : "Close All Tabs…") { model.closeTabs() }
            .disabled(model.tabCount == 0)
    }
}
