import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var settings: AppSettings
    @Published private(set) var status: RefreshStatus
    @Published private(set) var records: [ManagedAlarmRecord] = []
    @Published private(set) var authorizationText = "读取中"
    @Published private(set) var isWorking = false
    @Published var alertMessage: String?

    init() {
        settings = SettingsStore.loadSettings()
        status = SettingsStore.loadStatus()
    }

    var nextRecord: ManagedAlarmRecord? {
        records.first { $0.fireDate > Date() }
    }

    func loadSnapshot() {
        Task {
            let snapshot = await AlarmCoordinator.shared.snapshot()
            apply(snapshot)
        }
    }

    func authorizeAndPrepare() {
        run {
            SettingsStore.saveSettings(self.settings)
            _ = try await AlarmCoordinator.shared.authorizeAndPrepare(settings: self.settings)
        }
    }

    func refreshNow() {
        run {
            SettingsStore.saveSettings(self.settings)
            _ = try await AlarmCoordinator.shared.refreshTomorrow(settings: self.settings)
        }
    }

    func saveAndRebuild() {
        guard let error = settings.validationError else {
            SettingsStore.saveSettings(settings)
            run {
                _ = try await AlarmCoordinator.shared.rebuildFallbacks(settings: self.settings)
                _ = try await AlarmCoordinator.shared.refreshTomorrow(settings: self.settings)
            }
            return
        }
        alertMessage = error
    }

    private func run(_ operation: @escaping () async throws -> Void) {
        guard !isWorking else { return }
        isWorking = true
        alertMessage = nil
        Task {
            do {
                try await operation()
            } catch {
                alertMessage = error.localizedDescription
            }
            let snapshot = await AlarmCoordinator.shared.snapshot()
            apply(snapshot)
            isWorking = false
        }
    }

    private func apply(_ snapshot: CoordinatorSnapshot) {
        authorizationText = snapshot.authorizationText
        records = snapshot.records
        status = snapshot.status
    }
}
