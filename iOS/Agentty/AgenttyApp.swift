import AgenttyTerminal
import SwiftUI

@main
struct AgenttyApp: App {
    @StateObject private var model = PhoneModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if model.pairing == nil {
                    PairView()
                } else {
                    SessionsView()
                }
            }
            .environmentObject(model)
            .preferredColorScheme(.dark)
            .tint(Palette.tint)
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
}
