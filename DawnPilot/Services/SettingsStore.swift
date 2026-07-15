import Foundation

enum SettingsStore {
    private static let settingsKey = "dawnPilot.settings.v1"
    private static let recordsKey = "dawnPilot.records.v1"
    private static let statusKey = "dawnPilot.status.v1"

    static func loadSettings(defaults: UserDefaults = .standard) -> AppSettings {
        decode(AppSettings.self, key: settingsKey, defaults: defaults) ?? AppSettings()
    }

    static func saveSettings(_ settings: AppSettings, defaults: UserDefaults = .standard) {
        encode(settings, key: settingsKey, defaults: defaults)
    }

    static func loadRecords(defaults: UserDefaults = .standard) -> [ManagedAlarmRecord] {
        decode([ManagedAlarmRecord].self, key: recordsKey, defaults: defaults) ?? []
    }

    static func saveRecords(_ records: [ManagedAlarmRecord], defaults: UserDefaults = .standard) {
        encode(records, key: recordsKey, defaults: defaults)
    }

    static func loadStatus(defaults: UserDefaults = .standard) -> RefreshStatus {
        decode(RefreshStatus.self, key: statusKey, defaults: defaults) ?? .empty
    }

    static func saveStatus(_ status: RefreshStatus, defaults: UserDefaults = .standard) {
        encode(status, key: statusKey, defaults: defaults)
    }

    private static func encode<T: Encodable>(_ value: T, key: String, defaults: UserDefaults) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private static func decode<T: Decodable>(_ type: T.Type, key: String, defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }
}
