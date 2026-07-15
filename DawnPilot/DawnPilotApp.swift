import SwiftUI

@main
struct DawnPilotApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = AppModel()

    init() {
        BackgroundRefreshController.register()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .tint(.indigo)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                BackgroundRefreshController.scheduleNext()
            } else if newPhase == .active {
                model.loadSnapshot()
            }
        }
    }
}
