import SwiftUI

struct ContentView: View {
    enum Route: Hashable {
        case settings
    }

    @ObservedObject var model: AppModel

    var body: some View {
        NavigationStack {
            DashboardView(model: model)
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .settings:
                        SettingsView(model: model)
                    }
                }
        }
        .environment(\.calendar, model.settings.calendar)
        .environment(\.timeZone, model.settings.calendar.timeZone)
    }
}
