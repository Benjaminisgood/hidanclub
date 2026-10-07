import SwiftUI

@main
struct HidanClubIOSApp: App {
    @StateObject private var history = SessionHistoryStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(history)
                .tint(ClubThemeIOS.accent)
        }
    }
}
