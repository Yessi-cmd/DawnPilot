import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var settings: AppSettings
    @Published private(set) var status: RefreshStatus
    @Published private(set) var records: [ManagedAlarmRecord] = []
    @Published private(set) var authorizationText = "读取中"
    @Published private(set) var isWorking = false
    @Published private(set) var isLocating = false
    @Published var alertMessage: String?

    private let currentLocationService = CurrentLocationService()

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

    func useCurrentLocation() {
        guard !isLocating else { return }
        isLocating = true
        alertMessage = nil

        Task {
            defer { isLocating = false }
            do {
                let location = try await currentLocationService.resolveCurrentLocation()
                settings.latitude = location.latitude
                settings.longitude = location.longitude
                settings.locationName = location.displayName
                settings.timeZoneIdentifier = location.timeZoneIdentifier
                SettingsStore.saveSettings(settings)
            } catch {
                alertMessage = error.localizedDescription
            }
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
