import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var settings: AppSettings
    @Published private(set) var status: RefreshStatus
    @Published private(set) var records: [ManagedAlarmRecord] = []
    @Published private(set) var cancelledDates: [CancelledAlarmDate] = []
    @Published private(set) var authorizationText = "读取中"
    @Published private(set) var isWorking = false
    @Published private(set) var isLocating = false
    @Published private var alarmActionDateKeys: Set<String> = []
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
            let snapshot = await AlarmCoordinator.shared.snapshot(settings: settings)
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
            _ = try await AlarmCoordinator.shared.refreshTomorrow(
                settings: self.settings,
                trigger: .userInitiated
            )
        }
    }

    func cancelAlarm(_ record: ManagedAlarmRecord) {
        guard !isMutatingAlarm(record.dateKey) else { return }
        alarmActionDateKeys.insert(record.dateKey)
        alertMessage = nil
        Task {
            defer { alarmActionDateKeys.remove(record.dateKey) }
            do {
                try await AlarmCoordinator.shared.cancelAlarm(dateKey: record.dateKey)
            } catch {
                alertMessage = error.localizedDescription
            }
            let snapshot = await AlarmCoordinator.shared.snapshot(settings: settings)
            apply(snapshot)
        }
    }

    func restoreAlarm(_ cancelledDate: CancelledAlarmDate) {
        guard !isMutatingAlarm(cancelledDate.dateKey) else { return }
        alarmActionDateKeys.insert(cancelledDate.dateKey)
        alertMessage = nil
        Task {
            defer { alarmActionDateKeys.remove(cancelledDate.dateKey) }
            do {
                try await AlarmCoordinator.shared.restoreAlarm(
                    dateKey: cancelledDate.dateKey,
                    settings: settings
                )
            } catch {
                alertMessage = error.localizedDescription
            }
            let snapshot = await AlarmCoordinator.shared.snapshot(settings: settings)
            apply(snapshot)
        }
    }

    func isMutatingAlarm(_ dateKey: String) -> Bool {
        alarmActionDateKeys.contains(dateKey)
    }

    func useCurrentLocation() {
        guard !isLocating else { return }
        isLocating = true
        alertMessage = nil

        Task {
            defer { isLocating = false }
            do {
                let location = try await currentLocationService.resolveCurrentLocation()
                let timeZoneChanged = location.timeZoneIdentifier != settings.timeZoneIdentifier
                settings.latitude = location.latitude
                settings.longitude = location.longitude
                settings.locationName = location.displayName
                settings.timeZoneIdentifier = location.timeZoneIdentifier
                SettingsStore.saveSettings(settings)
                if timeZoneChanged {
                    // Best-effort: rebuild all fallback alarms so date keys
                    // match the new time zone. If AlarmKit hasn't been authorized
                    // yet there is nothing to rebuild, so treat failure as non-fatal.
                    _ = try? await AlarmCoordinator.shared.rebuildFallbacks(settings: self.settings)
                }
            } catch {
                alertMessage = error.localizedDescription
            }
            let snapshot = await AlarmCoordinator.shared.snapshot(settings: settings)
            apply(snapshot)
        }
    }

    func saveAndRebuild() {
        guard let error = settings.validationError else {
            SettingsStore.saveSettings(settings)
            run {
                _ = try await AlarmCoordinator.shared.rebuildFallbacks(settings: self.settings)
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
            let snapshot = await AlarmCoordinator.shared.snapshot(settings: settings)
            apply(snapshot)
            isWorking = false
        }
    }

    private func apply(_ snapshot: CoordinatorSnapshot) {
        authorizationText = snapshot.authorizationText
        records = snapshot.records
        cancelledDates = snapshot.cancelledDates
        status = snapshot.status
    }
}
