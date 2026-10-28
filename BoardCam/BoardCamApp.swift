import SwiftUI

@main
struct BoardCamApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        }
    }
}
