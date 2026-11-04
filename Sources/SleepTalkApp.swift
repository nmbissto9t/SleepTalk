import SwiftUI

@main
struct SleepTalkApp: App {
    @StateObject private var monitor = MonitorEngine()
    @StateObject private var store = SessionStore()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        SettingsKey.registerDefaults()
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(monitor)
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .tint(.indigo)
                .onAppear {
                    let sessionStore = store
                    monitor.onSessionEnded = {
                        sessionStore.reload()
                        sessionStore.cleanIfNeeded()
                    }
                    sessionStore.cleanIfNeeded()
                }
        }
        .onChange(of: scenePhase) { phase in
            monitor.setForeground(phase == .active)
        }
    }
}
