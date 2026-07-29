import Foundation
import Security

struct CredentialBinding: Codable, Equatable, Sendable {
    let settingsRevision: UUID
    let serverOrigin: String
    let bearerToken: String?

    func matches(_ settings: AppSettings) -> Bool {
        settingsRevision == settings.settingsRevision
            && serverOrigin == settings.credentialOrigin
    }
}

struct CredentialEnvelope: Codable, Equatable, Sendable {
    static let currentFormat = "dawnpilot-credential-envelope-v1"

    let format: String
    let current: CredentialBinding?
    let pending: CredentialBinding?

    init(current: CredentialBinding?, pending: CredentialBinding?) {
        format = Self.currentFormat
        self.current = current
        self.pending = pending
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let format = try container.decode(String.self, forKey: .format)
        guard format == Self.currentFormat else {
            throw DecodingError.dataCorruptedError(
                forKey: .format,
                in: container,
                debugDescription: "Unsupported credential envelope format."
            )
        }
        self.format = format
        current = try container.decodeIfPresent(
            CredentialBinding.self,
            forKey: .current
        )
        pending = try container.decodeIfPresent(
            CredentialBinding.self,
            forKey: .pending
        )
    }
}

enum StoredCredential: Equatable, Sendable {
    case legacyToken(String)
    case envelope(CredentialEnvelope)

    private static let envelopeMagic = Data(
        "DawnPilotCredentialEnvelope\u{0}v1\u{0}".utf8
    )

    static func decode(data: Data) throws -> StoredCredential {
        if data.starts(with: envelopeMagic) {
            let payload = data.dropFirst(envelopeMagic.count)
            do {
                return .envelope(try JSONDecoder().decode(
                    CredentialEnvelope.self,
                    from: Data(payload)
                ))
            } catch {
                throw CredentialCodecError.corruptedEnvelope
            }
        }
        guard let token = String(data: data, encoding: .utf8) else {
            throw CredentialCodecError.invalidLegacyToken
        }
        return .legacyToken(token)
    }

    func encoded() throws -> Data {
        switch self {
        case .legacyToken(let token):
            return Data(token.utf8)
        case .envelope(let envelope):
            var data = Self.envelopeMagic
            data.append(try JSONEncoder().encode(envelope))
            return data
        }
    }
}

enum CredentialCodecError: LocalizedError, Equatable, Sendable {
    case corruptedEnvelope
    case invalidLegacyToken

    var errorDescription: String? {
        switch self {
        case .corruptedEnvelope:
            "天气服务器令牌事务数据已损坏。"
        case .invalidLegacyToken:
            "旧版天气服务器令牌不是有效的 UTF-8 文本。"
        }
    }
}

protocol CredentialStoring: Sendable {
    func loadCredential() throws -> StoredCredential?
    func saveCredential(_ credential: StoredCredential?) throws
}

struct KeychainCredentialStore: CredentialStoring {
    static let shared = KeychainCredentialStore()

    private let service = "com.yessicmd.dawnpilot.weather"
    private let account = "bearer-token"

    func loadCredential() throws -> StoredCredential? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess,
              let data = result as? Data else {
            throw CredentialStoreError(operation: "读取", status: status)
        }
        return try StoredCredential.decode(data: data)
    }

    func saveCredential(_ credential: StoredCredential?) throws {
        guard let credential else {
            let status = SecItemDelete(baseQuery as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw CredentialStoreError(operation: "删除", status: status)
            }
            return
        }

        let data = try credential.encoded()
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw CredentialStoreError(operation: "更新", status: updateStatus)
        }

        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CredentialStoreError(operation: "保存", status: addStatus)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

struct CredentialStoreError: LocalizedError, Equatable, Sendable {
    let operation: String
    let status: OSStatus

    var errorDescription: String? {
        let systemMessage = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return "无法\(operation)天气服务器令牌：\(systemMessage)"
    }
}

enum SettingsStoreError: LocalizedError, Equatable, Sendable {
    case unsupportedVersion(area: String, version: Int)
    case corrupted(area: String)
    case invalidRecords(String)
    case credential(String)
    case recoveryRequired(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let area, let version):
            "\(area)使用了不支持的存储版本 \(version)。"
        case .corrupted(let area):
            "\(area)存储已损坏，晨航不会在未确认前重建闹钟。"
        case .invalidRecords(let message):
            "闹钟记录无效：\(message)"
        case .credential(let message):
            message
        case .recoveryRequired(let message):
            message
        }
    }
}

struct SettingsStoreIssue: Codable, Equatable, Sendable {
    let area: String
    let message: String
    let occurredAt: Date
}

enum SettingsStore {
    static let currentStorageVersion = 2

    private static let settingsKey = "dawnPilot.settings.v2"
    private static let legacySettingsKey = "dawnPilot.settings.v1"
    private static let recordsKey = "dawnPilot.records.v2"
    private static let legacyRecordsKey = "dawnPilot.records.v1"
    private static let statusKey = "dawnPilot.status.v2"
    private static let legacyStatusKey = "dawnPilot.status.v1"
    private static let pendingReplacementKey = "dawnPilot.pendingReplacement.v1"
    private static let pendingBulkRebuildKey = "dawnPilot.bulkRebuild.v1"
    private static let suppressedAlarmDatesKey = "dawnPilot.suppressedAlarmDates.v1"
    private static let issueKey = "dawnPilot.persistenceIssue.v1"

    private static let settingsArea = "设置"
    private static let recordsArea = "闹钟记录"
    private static let statusArea = "刷新状态"
    private static let pendingReplacementArea = "闹钟替换事务"
    private static let pendingBulkRebuildArea = "批量闹钟重建事务"
    private static let suppressedAlarmDatesArea = "已删除闹钟日期"

    static func loadSettings(
        defaults: UserDefaults = .standard,
        credentialStore: any CredentialStoring = KeychainCredentialStore.shared
    ) -> AppSettings {
        do {
            let settings = try loadSettingsThrowing(
                defaults: defaults,
                credentialStore: credentialStore
            )
            clearIssue(area: settingsArea, defaults: defaults)
            return settings
        } catch {
            let storeError = normalized(error, area: settingsArea)
            recordIssue(storeError, area: settingsArea, defaults: defaults)
            return .recoveryPlaceholder(
                message: storeError.localizedDescription
            )
        }
    }

    static func loadSettingsResult(
        defaults: UserDefaults = .standard,
        credentialStore: any CredentialStoring = KeychainCredentialStore.shared
    ) -> Result<AppSettings, SettingsStoreError> {
        do {
            return .success(try loadSettingsThrowing(
                defaults: defaults,
                credentialStore: credentialStore
            ))
        } catch {
            return .failure(normalized(error, area: settingsArea))
        }
    }

    static func loadPersistedSettingsResult(
        defaults: UserDefaults = .standard
    ) -> Result<AppSettings?, SettingsStoreError> {
        do {
            return .success(try loadPersistedSettingsPayload(defaults: defaults))
        } catch {
            return .failure(normalized(error, area: settingsArea))
        }
    }

    static func saveSettings(
        _ settings: AppSettings,
        defaults: UserDefaults = .standard,
        credentialStore: any CredentialStoring = KeychainCredentialStore.shared
    ) {
        do {
            try saveSettingsThrowing(
                settings,
                defaults: defaults,
                credentialStore: credentialStore
            )
            clearIssue(area: settingsArea, defaults: defaults)
        } catch {
            recordIssue(
                normalized(error, area: settingsArea),
                area: settingsArea,
                defaults: defaults
            )
        }
    }

    @discardableResult
    static func saveSettingsThrowing(
        _ settings: AppSettings,
        defaults: UserDefaults = .standard,
        credentialStore: any CredentialStoring = KeychainCredentialStore.shared,
        preserveRevision: Bool = false
    ) throws -> AppSettings {
        var committedSettings = settings
        if !preserveRevision {
            committedSettings.settingsRevision = UUID()
        }

        if let storageRecoveryMessage = committedSettings.storageRecoveryMessage {
            throw SettingsStoreError.recoveryRequired(storageRecoveryMessage)
        }
        if let validationError = committedSettings.validationError {
            throw SettingsStoreError.recoveryRequired(validationError)
        }

        let payload = VersionedPayload(
            version: currentStorageVersion,
            value: committedSettings
        )
        let data = try encode(payload)
        let binding = try credentialBinding(for: committedSettings)
        let oldSettings = try loadPersistedSettingsPayload(defaults: defaults)
        do {
            let storedCredential = try credentialStore.loadCredential()
            let currentBinding = try resolvedCurrentBinding(
                storedCredential,
                settings: oldSettings
            )
            try credentialStore.saveCredential(.envelope(CredentialEnvelope(
                current: currentBinding,
                pending: binding
            )))
        } catch {
            throw SettingsStoreError.credential(error.localizedDescription)
        }

        defaults.set(data, forKey: settingsKey)
        defaults.removeObject(forKey: legacySettingsKey)

        // The staged envelope already binds the new settings revision to its
        // token. Promotion is cleanup: if it fails, the next load can safely
        // select and promote the matching pending binding.
        try? credentialStore.saveCredential(.envelope(CredentialEnvelope(
            current: binding,
            pending: nil
        )))
        return committedSettings
    }

    @discardableResult
    static func replaceCorruptedSettings(
        _ settings: AppSettings,
        defaults: UserDefaults = .standard,
        credentialStore: any CredentialStoring = KeychainCredentialStore.shared
    ) throws -> AppSettings {
        var recovered = settings
        recovered.clearStorageRecoveryMarker()
        let committed = try saveSettingsThrowing(
            recovered,
            defaults: defaults,
            credentialStore: credentialStore
        )
        clearIssue(area: settingsArea, defaults: defaults)
        return committed
    }

    static func loadRecords(defaults: UserDefaults = .standard) -> [ManagedAlarmRecord] {
        switch loadRecordsResult(defaults: defaults) {
        case .success(let records):
            clearIssue(area: recordsArea, defaults: defaults)
            return records
        case .failure(let error):
            recordIssue(error, area: recordsArea, defaults: defaults)
            return []
        }
    }

    static func loadRecordsResult(
        defaults: UserDefaults = .standard
    ) -> Result<[ManagedAlarmRecord], SettingsStoreError> {
        do {
            return .success(try loadRecordsThrowing(defaults: defaults))
        } catch {
            return .failure(normalized(error, area: recordsArea))
        }
    }

    static func saveRecords(
        _ records: [ManagedAlarmRecord],
        defaults: UserDefaults = .standard
    ) {
        do {
            try saveRecordsThrowing(records, defaults: defaults)
            clearIssue(area: recordsArea, defaults: defaults)
        } catch {
            recordIssue(
                normalized(error, area: recordsArea),
                area: recordsArea,
                defaults: defaults
            )
        }
    }

    static func saveRecordsThrowing(
        _ records: [ManagedAlarmRecord],
        defaults: UserDefaults = .standard
    ) throws {
        try validate(records)
        let payload = VersionedPayload(version: currentStorageVersion, value: records)
        defaults.set(try encode(payload), forKey: recordsKey)
        defaults.removeObject(forKey: legacyRecordsKey)
    }

    static func loadSuppressedAlarmDateKeysResult(
        defaults: UserDefaults = .standard
    ) -> Result<Set<String>, SettingsStoreError> {
        guard let data = defaults.data(forKey: suppressedAlarmDatesKey) else {
            return .success([])
        }
        do {
            let payload: VersionedPayload<[String]> = try decode(
                VersionedPayload<[String]>.self,
                data: data
            )
            guard payload.version == currentStorageVersion else {
                throw SettingsStoreError.unsupportedVersion(
                    area: suppressedAlarmDatesArea,
                    version: payload.version
                )
            }
            let dateKeys = Set(payload.value)
            guard dateKeys.count == payload.value.count else {
                throw SettingsStoreError.invalidRecords(
                    "已删除闹钟日期包含重复值。"
                )
            }
            try validateSuppressedAlarmDateKeys(dateKeys)
            return .success(dateKeys)
        } catch {
            return .failure(normalized(error, area: suppressedAlarmDatesArea))
        }
    }

    static func saveSuppressedAlarmDateKeysThrowing(
        _ dateKeys: Set<String>,
        defaults: UserDefaults = .standard
    ) throws {
        try validateSuppressedAlarmDateKeys(dateKeys)
        let payload = VersionedPayload(
            version: currentStorageVersion,
            value: dateKeys.sorted()
        )
        defaults.set(try encode(payload), forKey: suppressedAlarmDatesKey)
        clearIssue(area: suppressedAlarmDatesArea, defaults: defaults)
    }

    static func loadStatus(defaults: UserDefaults = .standard) -> RefreshStatus {
        do {
            let status = try loadStatusThrowing(defaults: defaults)
            clearIssue(area: statusArea, defaults: defaults)
            return status
        } catch {
            let storeError = normalized(error, area: statusArea)
            recordIssue(storeError, area: statusArea, defaults: defaults)
            return .empty
        }
    }

    static func saveStatus(_ status: RefreshStatus, defaults: UserDefaults = .standard) {
        do {
            let payload = VersionedPayload(version: currentStorageVersion, value: status)
            defaults.set(try encode(payload), forKey: statusKey)
            defaults.removeObject(forKey: legacyStatusKey)
            clearIssue(area: statusArea, defaults: defaults)
        } catch {
            recordIssue(
                normalized(error, area: statusArea),
                area: statusArea,
                defaults: defaults
            )
        }
    }

    static func loadPendingReplacementResult(
        defaults: UserDefaults = .standard
    ) -> Result<PendingAlarmReplacement?, SettingsStoreError> {
        guard let data = defaults.data(forKey: pendingReplacementKey) else {
            return .success(nil)
        }
        do {
            let payload: VersionedPayload<PendingAlarmReplacement> = try decode(
                VersionedPayload<PendingAlarmReplacement>.self,
                data: data
            )
            guard payload.version == currentStorageVersion else {
                throw SettingsStoreError.unsupportedVersion(
                    area: pendingReplacementArea,
                    version: payload.version
                )
            }
            return .success(payload.value)
        } catch {
            return .failure(normalized(error, area: pendingReplacementArea))
        }
    }

    static func savePendingReplacementThrowing(
        _ pendingReplacement: PendingAlarmReplacement?,
        defaults: UserDefaults = .standard
    ) throws {
        guard let pendingReplacement else {
            defaults.removeObject(forKey: pendingReplacementKey)
            clearIssue(area: pendingReplacementArea, defaults: defaults)
            return
        }
        let payload = VersionedPayload(
            version: currentStorageVersion,
            value: pendingReplacement
        )
        defaults.set(try encode(payload), forKey: pendingReplacementKey)
        clearIssue(area: pendingReplacementArea, defaults: defaults)
    }

    static func loadPendingBulkRebuildResult(
        defaults: UserDefaults = .standard
    ) -> Result<PendingBulkAlarmRebuild?, SettingsStoreError> {
        guard let data = defaults.data(forKey: pendingBulkRebuildKey) else {
            return .success(nil)
        }
        do {
            let payload: VersionedPayload<PendingBulkAlarmRebuild> = try decode(
                VersionedPayload<PendingBulkAlarmRebuild>.self,
                data: data
            )
            guard payload.version == currentStorageVersion else {
                throw SettingsStoreError.unsupportedVersion(
                    area: pendingBulkRebuildArea,
                    version: payload.version
                )
            }
            try validate(payload.value)
            return .success(payload.value)
        } catch {
            return .failure(normalized(error, area: pendingBulkRebuildArea))
        }
    }

    static func savePendingBulkRebuildThrowing(
        _ pendingBulkRebuild: PendingBulkAlarmRebuild?,
        defaults: UserDefaults = .standard
    ) throws {
        guard let pendingBulkRebuild else {
            defaults.removeObject(forKey: pendingBulkRebuildKey)
            clearIssue(area: pendingBulkRebuildArea, defaults: defaults)
            return
        }
        try validate(pendingBulkRebuild)
        let payload = VersionedPayload(
            version: currentStorageVersion,
            value: pendingBulkRebuild
        )
        defaults.set(try encode(payload), forKey: pendingBulkRebuildKey)
        clearIssue(area: pendingBulkRebuildArea, defaults: defaults)
    }

    static func loadIssue(defaults: UserDefaults = .standard) -> SettingsStoreIssue? {
        try? decode(SettingsStoreIssue.self, data: defaults.data(forKey: issueKey))
    }

    private static func loadSettingsThrowing(
        defaults: UserDefaults,
        credentialStore: any CredentialStoring
    ) throws -> AppSettings {
        if let data = defaults.data(forKey: settingsKey) {
            let payload: VersionedPayload<AppSettings> = try decode(
                VersionedPayload<AppSettings>.self,
                data: data
            )
            guard payload.version == currentStorageVersion else {
                throw SettingsStoreError.unsupportedVersion(
                    area: settingsArea,
                    version: payload.version
                )
            }
            let settings = try attachCredentialAndRemoveEmbeddedToken(
                payload.value,
                dataKey: settingsKey,
                defaults: defaults,
                credentialStore: credentialStore
            )
            retireLegacySettingsIfNeeded(defaults: defaults)
            return settings
        }

        if let legacyData = defaults.data(forKey: legacySettingsKey) {
            var legacy = try decode(AppSettings.self, data: legacyData)
            legacy.settingsRevision = UUID()
            let token: String
            do {
                if !legacy.bearerToken.isEmpty {
                    token = legacy.bearerToken
                } else {
                    token = try legacyToken(
                        from: credentialStore.loadCredential()
                    ) ?? ""
                }
                legacy.bearerToken = token
                let binding = try credentialBinding(for: legacy)
                try credentialStore.saveCredential(.envelope(CredentialEnvelope(
                    current: binding,
                    pending: nil
                )))
            } catch {
                throw SettingsStoreError.credential(error.localizedDescription)
            }
            let encoded = try encode(
                VersionedPayload(version: currentStorageVersion, value: legacy)
            )

            defaults.set(encoded, forKey: settingsKey)
            defaults.removeObject(forKey: legacySettingsKey)
            return legacy
        }

        var settings = AppSettings()
        do {
            settings.bearerToken = try legacyToken(
                from: credentialStore.loadCredential()
            ) ?? ""
            settings = try saveSettingsThrowing(
                settings,
                defaults: defaults,
                credentialStore: credentialStore
            )
        } catch {
            throw SettingsStoreError.credential(error.localizedDescription)
        }
        return settings
    }

    private static func retireLegacySettingsIfNeeded(defaults: UserDefaults) {
        // Once v2 exists, the successfully attached Keychain value (including an
        // intentional nil after the user clears the token) is authoritative.
        // Pure migration writes Keychain before v2, so reviving v1 here would
        // resurrect a deliberately deleted credential after an interrupted save.
        defaults.removeObject(forKey: legacySettingsKey)
    }

    private static func attachCredentialAndRemoveEmbeddedToken(
        _ decodedSettings: AppSettings,
        dataKey: String,
        defaults: UserDefaults,
        credentialStore: any CredentialStoring
    ) throws -> AppSettings {
        var settings = decodedSettings
        do {
            if !settings.bearerToken.isEmpty {
                let binding = try credentialBinding(for: settings)
                try credentialStore.saveCredential(.envelope(CredentialEnvelope(
                    current: binding,
                    pending: nil
                )))
            } else {
                let storedCredential = try credentialStore.loadCredential()
                let binding: CredentialBinding
                let shouldPersistBinding: Bool
                let persistenceIsCleanupOnly: Bool
                switch storedCredential {
                case .none:
                    binding = try credentialBinding(
                        for: settings,
                        bearerToken: nil
                    )
                    shouldPersistBinding = true
                    persistenceIsCleanupOnly = false
                case .legacyToken(let token):
                    binding = try credentialBinding(
                        for: settings,
                        bearerToken: token
                    )
                    shouldPersistBinding = true
                    persistenceIsCleanupOnly = false
                case .envelope(let envelope):
                    if let pending = envelope.pending,
                       pending.matches(settings) {
                        binding = pending
                        shouldPersistBinding = true
                        persistenceIsCleanupOnly = true
                    } else if let current = envelope.current,
                              current.matches(settings) {
                        binding = current
                        shouldPersistBinding = envelope.pending != nil
                        persistenceIsCleanupOnly = true
                    } else if envelope.current == nil {
                        binding = try credentialBinding(
                            for: settings,
                            bearerToken: nil
                        )
                        shouldPersistBinding = true
                        persistenceIsCleanupOnly = true
                    } else {
                        throw SettingsStoreError.credential(
                            "天气服务器令牌与设置版本不一致，请恢复设置后重试。"
                        )
                    }
                }
                settings.bearerToken = binding.bearerToken ?? ""
                if shouldPersistBinding {
                    let promotedCredential = StoredCredential.envelope(CredentialEnvelope(
                        current: binding,
                        pending: nil
                    ))
                    if persistenceIsCleanupOnly {
                        try? credentialStore.saveCredential(promotedCredential)
                    } else {
                        try credentialStore.saveCredential(promotedCredential)
                    }
                }
            }
            let cleanPayload = VersionedPayload(
                version: currentStorageVersion,
                value: settings
            )
            defaults.set(try encode(cleanPayload), forKey: dataKey)
        } catch let error as SettingsStoreError {
            throw error
        } catch {
            throw SettingsStoreError.credential(error.localizedDescription)
        }
        return settings
    }

    private static func credentialBinding(
        for settings: AppSettings,
        bearerToken: String? = nil
    ) throws -> CredentialBinding {
        guard let origin = settings.credentialOrigin else {
            throw SettingsStoreError.credential("无法绑定天气服务器令牌：服务器来源无效。")
        }
        let token = bearerToken ?? (
            settings.bearerToken.isEmpty ? nil : settings.bearerToken
        )
        return CredentialBinding(
            settingsRevision: settings.settingsRevision,
            serverOrigin: origin,
            bearerToken: token
        )
    }

    private static func loadPersistedSettingsPayload(
        defaults: UserDefaults
    ) throws -> AppSettings? {
        guard let data = defaults.data(forKey: settingsKey) else { return nil }
        let payload: VersionedPayload<AppSettings> = try decode(
            VersionedPayload<AppSettings>.self,
            data: data
        )
        guard payload.version == currentStorageVersion else {
            throw SettingsStoreError.unsupportedVersion(
                area: settingsArea,
                version: payload.version
            )
        }
        return payload.value
    }

    private static func resolvedCurrentBinding(
        _ storedCredential: StoredCredential?,
        settings: AppSettings?
    ) throws -> CredentialBinding? {
        guard let settings else { return nil }
        switch storedCredential {
        case .none:
            return try credentialBinding(for: settings, bearerToken: nil)
        case .legacyToken(let token):
            return try credentialBinding(for: settings, bearerToken: token)
        case .envelope(let envelope):
            if let pending = envelope.pending, pending.matches(settings) {
                return pending
            }
            if let current = envelope.current, current.matches(settings) {
                return current
            }
            if envelope.current == nil {
                return try credentialBinding(for: settings, bearerToken: nil)
            }
            throw SettingsStoreError.credential(
                "天气服务器令牌与已保存设置版本不一致。"
            )
        }
    }

    private static func legacyToken(from credential: StoredCredential?) throws -> String? {
        switch credential {
        case .none:
            return nil
        case .legacyToken(let token):
            return token
        case .envelope(let envelope):
            return envelope.current?.bearerToken
        }
    }

    private static func loadRecordsThrowing(
        defaults: UserDefaults
    ) throws -> [ManagedAlarmRecord] {
        if let data = defaults.data(forKey: recordsKey) {
            let payload: VersionedPayload<[ManagedAlarmRecord]> = try decode(
                VersionedPayload<[ManagedAlarmRecord]>.self,
                data: data
            )
            guard payload.version == currentStorageVersion else {
                throw SettingsStoreError.unsupportedVersion(
                    area: recordsArea,
                    version: payload.version
                )
            }
            try validate(payload.value)
            return payload.value
        }

        guard let legacyData = defaults.data(forKey: legacyRecordsKey) else {
            return []
        }
        let records = try decode([ManagedAlarmRecord].self, data: legacyData)
        try validate(records)
        try saveRecordsThrowing(records, defaults: defaults)
        return records
    }

    private static func loadStatusThrowing(defaults: UserDefaults) throws -> RefreshStatus {
        if let data = defaults.data(forKey: statusKey) {
            let payload: VersionedPayload<RefreshStatus> = try decode(
                VersionedPayload<RefreshStatus>.self,
                data: data
            )
            guard payload.version == currentStorageVersion else {
                throw SettingsStoreError.unsupportedVersion(
                    area: statusArea,
                    version: payload.version
                )
            }
            return payload.value
        }

        guard let legacyData = defaults.data(forKey: legacyStatusKey) else {
            return .empty
        }
        let status = try decode(RefreshStatus.self, data: legacyData)
        saveStatus(status, defaults: defaults)
        return status
    }

    private static func validate(_ records: [ManagedAlarmRecord]) throws {
        let dateKeys = Set(records.map(\.dateKey))
        guard dateKeys.count == records.count else {
            throw SettingsStoreError.invalidRecords("同一日期存在多条托管记录。")
        }
        let alarmIDs = Set(records.map(\.alarmID))
        guard alarmIDs.count == records.count else {
            throw SettingsStoreError.invalidRecords("同一 AlarmKit 标识被重复使用。")
        }
    }

    private static func validateSuppressedAlarmDateKeys(
        _ dateKeys: Set<String>
    ) throws {
        guard dateKeys.count <= 64 else {
            throw SettingsStoreError.invalidRecords("已删除闹钟日期数量超出安全上限。")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let allValid = dateKeys.allSatisfy { dateKey in
            let parts = dateKey.split(separator: "-", omittingEmptySubsequences: false)
            guard dateKey.count == 10,
                  parts.count == 3,
                  parts[0].count == 4,
                  parts[1].count == 2,
                  parts[2].count == 2,
                  let year = Int(parts[0]),
                  let month = Int(parts[1]),
                  let day = Int(parts[2]) else {
                return false
            }
            let components = DateComponents(year: year, month: month, day: day)
            guard (1...9_999).contains(year),
                  let date = calendar.date(from: components) else {
                return false
            }
            let resolved = calendar.dateComponents([.year, .month, .day], from: date)
            return resolved.year == year
                && resolved.month == month
                && resolved.day == day
        }
        guard allValid else {
            throw SettingsStoreError.invalidRecords("已删除闹钟日期格式无效。")
        }
    }

    private static func validate(_ transaction: PendingBulkAlarmRebuild) throws {
        let desiredDateKeys = Set(transaction.desiredDateKeys)
        let desiredRecordDateKeys = Set(transaction.desiredRecords.map(\.dateKey))
        guard transaction.desiredDateKeys.count <= AppSettings.fallbackHorizonDays,
              desiredDateKeys.count == transaction.desiredDateKeys.count,
              transaction.desiredRecords.count == transaction.desiredDateKeys.count,
              desiredRecordDateKeys == desiredDateKeys else {
            throw SettingsStoreError.invalidRecords(
                "批量重建目标日期与目标闹钟不是唯一的一一对应关系。"
            )
        }
        guard transaction.originalRecords.count <= 64,
              transaction.newlyScheduledRecords.count <= 128,
              transaction.protectedCurrentDayIDs.count <= 16 else {
            throw SettingsStoreError.invalidRecords("批量重建事务大小超出安全上限。")
        }

        let originalIDs = Set(transaction.originalRecords.map(\.alarmID))
        let newlyScheduledIDs = Set(transaction.newlyScheduledRecords.map(\.alarmID))
        let desiredIDs = Set(transaction.desiredRecords.map(\.alarmID))
        let protectedIDs = Set(transaction.protectedCurrentDayIDs)
        guard originalIDs.count == transaction.originalRecords.count,
              newlyScheduledIDs.count == transaction.newlyScheduledRecords.count,
              desiredIDs.count == transaction.desiredRecords.count,
              protectedIDs.count == transaction.protectedCurrentDayIDs.count,
              originalIDs.isDisjoint(with: newlyScheduledIDs),
              desiredIDs.isSubset(of: originalIDs.union(newlyScheduledIDs)),
              protectedIDs.isSubset(of: originalIDs.union(newlyScheduledIDs)) else {
            throw SettingsStoreError.invalidRecords(
                "批量重建事务包含重复或无法追溯的 AlarmKit 标识。"
            )
        }

        let originalDateKeys = Set(transaction.originalRecords.map(\.dateKey))
        guard originalDateKeys.count == transaction.originalRecords.count else {
            throw SettingsStoreError.invalidRecords(
                "批量重建事务的原始记录包含重复日期。"
            )
        }
        let allTransactionRecords = transaction.originalRecords
            + transaction.newlyScheduledRecords
            + transaction.desiredRecords
        guard allTransactionRecords.allSatisfy({
            !$0.dateKey.isEmpty
                && $0.fireDate.timeIntervalSinceReferenceDate.isFinite
                && $0.updatedAt.timeIntervalSinceReferenceDate.isFinite
        }),
        transaction.desiredRecords.allSatisfy({ $0.kind == .fallback }),
        transaction.newlyScheduledRecords.allSatisfy({ $0.kind == .fallback }),
        transaction.createdAt.timeIntervalSinceReferenceDate.isFinite else {
            throw SettingsStoreError.invalidRecords(
                "批量重建事务包含无效日期或非保底闹钟。"
            )
        }

        guard !transaction.targetCredentialOrigin.isEmpty,
              transaction.targetCredentialOrigin.count <= 2_048,
              let origin = URLComponents(
                  string: transaction.targetCredentialOrigin
              ),
              let scheme = origin.scheme,
              !scheme.isEmpty,
              origin.host != nil,
              origin.user == nil,
              origin.password == nil,
              origin.query == nil,
              origin.fragment == nil else {
            throw SettingsStoreError.invalidRecords(
                "批量重建事务的服务器范围无效。"
            )
        }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    private static func decode<T: Decodable>(_ type: T.Type, data: Data?) throws -> T {
        guard let data else {
            throw SettingsStoreError.corrupted(area: "数据")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    private static func normalized(_ error: Error, area: String) -> SettingsStoreError {
        if let storeError = error as? SettingsStoreError {
            return storeError
        }
        if let credentialError = error as? CredentialStoreError {
            return .credential(credentialError.localizedDescription)
        }
        return .corrupted(area: area)
    }

    private static func recordIssue(
        _ error: SettingsStoreError,
        area: String,
        defaults: UserDefaults
    ) {
        let issue = SettingsStoreIssue(
            area: area,
            message: error.localizedDescription,
            occurredAt: .now
        )
        if let data = try? encode(issue) {
            defaults.set(data, forKey: issueKey)
        }
    }

    private static func clearIssue(area: String, defaults: UserDefaults) {
        guard loadIssue(defaults: defaults)?.area == area else { return }
        defaults.removeObject(forKey: issueKey)
    }
}

private struct VersionedPayload<Value: Codable>: Codable {
    let version: Int
    let value: Value
}
