import AgentTermFirebase
import AgentTermTelemetry
import AgentTermTerminal
import SwiftUI

@main
struct AgentTermApp: App {
    @StateObject private var model = PhoneModel()
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var privacy: TelemetryPreferences

    init() {
        // Before anything is shown: the question about crash reports
        // depends on whether this build can report at all.
        FirebaseSink.start()
        Telemetry.shared.record(.appOpen)
        _privacy = StateObject(wrappedValue: TelemetryPreferences())
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if model.hosts.isEmpty {
                    PairView()
                } else {
                    SessionsView()
                }
            }
            .environmentObject(model)
            .preferredColorScheme(.dark)
            .tint(Palette.tint)
            .environmentObject(privacy)
            // Asked once, at the first launch of a build that can send them.
            .alert(TelemetryPreferences.Wording.question, isPresented: $privacy.needsAsking) {
                Button("Send Crash Reports") { privacy.answer(sendCrashReports: true) }
                Button("Don't Send", role: .cancel) { privacy.answer(sendCrashReports: false) }
            } message: {
                Text(TelemetryPreferences.Wording.questionDetail + "\n\nYou can change this, and usage statistics, under Privacy in the menu.")
            }
            .onOpenURL { model.pair(with: $0) }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { model.resume() }
            }
        }
    }
}

enum Palette {
    static let canvas = Color(uiColor: TerminalStyle.background)
    static let panel = Color(red: 0.098, green: 0.102, blue: 0.125)
    static let raised = Color.white.opacity(0.07)
    static let hairline = Color.white.opacity(0.09)
    static let tint = Color(red: 0.45, green: 0.62, blue: 0.98)
    static let danger = Color(red: 0.96, green: 0.45, blue: 0.47)
    static let added = Color(red: 0.36, green: 0.80, blue: 0.52)
}
