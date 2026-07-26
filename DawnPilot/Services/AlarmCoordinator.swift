import Foundation

struct CoordinatorSnapshot: Sendable {
    let authorization: AlarmAuthorization
    let records: [ManagedAlarmRecord]
    let status: RefreshStatus
    let alarmsVerified: Bool
}

enum AlarmCoordinatorError: LocalizedError {
    case authorizationDenied
    case authorizationRequired
    case invalidSettings(String)
    case unableToBuildDate
    case persistence(String)
    case settingsCommitFailed(String)
    case postCommitCleanupFailed(String)

    var errorDescription: String? {
        switch self {
        case .authorizationDenied:
            "闹钟权限已被拒绝，请在系统设置中允许晨航使用 AlarmKit。"
        case .authorizationRequired:
            "请先打开晨航并完成 AlarmKit 授权。"
        case .invalidSettings(let message):
            message
        case .unableToBuildDate:
            "无法生成闹钟日期，请检查时区、夏令时和时间设置。"
        case .persistence(let message):
            "无法安全恢复托管闹钟：\(message)"
        case .settingsCommitFailed(let message):
            "新保底闹钟已安全暂存，但设置未保存：\(message)"
        case .postCommitCleanupFailed(let message):
            "设置和新保底闹钟已保存，但旧闹钟清理未完成：\(message)"
        }
    }
}

actor AlarmCoordinator {
    static let shared = AlarmCoordinator()

    private let alarmDriver: any AlarmScheduling
    private let weatherService: any ForecastFetching
    private let credentialStore: any CredentialStoring
    private let defaults: UserDefaults
    private var records: [ManagedAlarmRecord]
    private var pendingReplacement: PendingAlarmReplacement?
    private var pendingBulkRebuild: PendingBulkAlarmRebuild?
    private var persistenceError: SettingsStoreError?
    private var operationTail: Task<Void, Never>?

    init(
        alarmDriver: any AlarmScheduling = AlarmKitAlarmDriver(),
        weatherService: any ForecastFetching = WeatherService(),
        credentialStore: any CredentialStoring = KeychainCredentialStore.shared,
        defaultsSuiteName: String? = nil
    ) {
        self.alarmDriver = alarmDriver
        self.weatherService = weatherService
        self.credentialStore = credentialStore
        defaults = defaultsSuiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard

        switch SettingsStore.loadRecordsResult(defaults: defaults) {
        case .success(let loadedRecords):
            records = loadedRecords
            persistenceError = nil
        case .failure(let error):
            records = []
            persistenceError = error
        }

        switch SettingsStore.loadPendingReplacementResult(defaults: defaults) {
        case .success(let pending):
            pendingReplacement = pending
        case .failure(let error):
            pendingReplacement = nil
            if persistenceError == nil {
                persistenceError = error
            }
        }

        switch SettingsStore.loadPendingBulkRebuildResult(defaults: defaults) {
        case .success(let pending):
            pendingBulkRebuild = pending
        case .failure(let error):
            pendingBulkRebuild = nil
            if persistenceError == nil {
                persistenceError = error
            }
        }
    }

    // The actor is reentrant: every internal await is a point where another
    // entry point (UI snapshot, App Intent, background refresh) could interleave
    // and misread an in-flight transaction journal as crash debris. Every public
    // operation therefore runs strictly one after another in arrival order.
    func snapshot(now: Date = .now) async -> CoordinatorSnapshot {
        await runSerializedNonThrowing {
            await self.performSnapshot(now: now)
        }
    }

    func authorizeAndPrepare(
        settings: AppSettings,
        now: Date = .now
    ) async throws -> RefreshStatus {
        try await runSerialized {
            try await self.performAuthorizeAndPrepare(settings: settings, now: now)
        }
    }

    func rebuildFallbacks(
        settings: AppSettings,
        requestAuthorizationIfNeeded: Bool = false,
        now: Date = .now
    ) async throws -> RefreshStatus {
        try await runSerialized {
            try await self.performRebuildFallbacks(
                settings: settings,
                requestAuthorizationIfNeeded: requestAuthorizationIfNeeded,
                now: now
            )
        }
    }

    func refreshTomorrow(
        settings: AppSettings,
        now: Date = .now
    ) async throws -> RefreshStatus {
        try await runSerialized {
            try await self.performRefreshTomorrow(settings: settings, now: now)
        }
    }

    private func runSerialized<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        // Reading the tail, creating the successor, and replacing the tail happen
        // with no await in between, so enqueueing is atomic under reentrancy.
        let previous = operationTail
        let current = Task {
            await previous?.value
            return try await operation()
        }
        operationTail = Task { _ = try? await current.value }
        return try await withTaskCancellationHandler {
            try await current.value
        } onCancel: {
            current.cancel()
        }
    }

    private func runSerializedNonThrowing<T: Sendable>(
        _ operation: @escaping @Sendable () async -> T
    ) async -> T {
        let previous = operationTail
        let current = Task {
            await previous?.value
            return await operation()
        }
        operationTail = Task { _ = await current.value }
        return await withTaskCancellationHandler {
            await current.value
        } onCancel: {
            current.cancel()
        }
    }

    private func performSnapshot(now: Date) async -> CoordinatorSnapshot {
        let authorization = await alarmDriver.authorizationState()
        var alarmsVerified = false
        if authorization == .authorized {
            do {
                try preparePersistedState()
                try pruneExpiredRecords(now: now)
                alarmsVerified = try await reconcileSystemState(now: now)
            } catch {
                saveFailureStatus(
                    message: "无法核对系统闹钟：\(error.localizedDescription)",
                    now: now
                )
            }
        }
        return CoordinatorSnapshot(
            authorization: authorization,
            records: records.sorted { $0.fireDate < $1.fireDate },
            status: SettingsStore.loadStatus(defaults: defaults),
            alarmsVerified: alarmsVerified
        )
    }

    private func performAuthorizeAndPrepare(
        settings: AppSettings,
        now: Date
    ) async throws -> RefreshStatus {
        try validate(settings)
        let state: AlarmAuthorization
        switch await alarmDriver.authorizationState() {
        case .notDetermined:
            state = try await alarmDriver.requestAuthorization()
        case let current:
            state = current
        }
        guard state == .authorized else {
            throw AlarmCoordinatorError.authorizationDenied
        }

        let count = try await ensureFallbackHorizon(settings: settings, now: now)
        let status = RefreshStatus(
            outcome: .prepared,
            message: "已准备 \(count) 条未来保底闹钟。",
            alarmDate: nextRecord(after: now)?.fireDate,
            updatedAt: now,
            forecastFetchedAt: nil,
            forecastWasStale: false
        )
        SettingsStore.saveStatus(status, defaults: defaults)
        return status
    }

    private func performRebuildFallbacks(
        settings: AppSettings,
        requestAuthorizationIfNeeded: Bool,
        now: Date
    ) async throws -> RefreshStatus {
        var targetSettings = settings
        targetSettings.settingsRevision = UUID()
        try validate(targetSettings)
        if requestAuthorizationIfNeeded {
            try await requestOrRequireAuthorization()
        } else {
            try await requireAuthorization()
        }

        let stagedRebuild: PendingBulkAlarmRebuild
        do {
            stagedRebuild = try await stageFallbackRebuild(
                settings: targetSettings,
                now: now
            )
            // Everything before the settings write is one precommit region.
            // Cancellation here must roll back alarms already staged in AlarmKit.
            try Task.checkCancellation()
        } catch {
            let originalError = error
            do {
                try await rollbackPendingBulkRebuild(now: now)
            } catch {
                throw AlarmCoordinatorError.persistence(
                    "批量重建暂存失败，且安全回滚尚未完成：\(error.localizedDescription)"
                )
            }
            throw originalError
        }

        do {
            _ = try SettingsStore.saveSettingsThrowing(
                targetSettings,
                defaults: defaults,
                credentialStore: credentialStore,
                preserveRevision: true
            )
        } catch {
            let commitError = error
            do {
                try await rollbackPendingBulkRebuild(now: now)
            } catch {
                throw AlarmCoordinatorError.persistence(
                    "设置提交失败，且暂存闹钟回滚尚未完成：\(error.localizedDescription)"
                )
            }
            throw AlarmCoordinatorError.settingsCommitFailed(
                commitError.localizedDescription
            )
        }

        var committedRebuild = stagedRebuild
        committedRebuild.phase = .settingsCommitted
        do {
            try persistPendingBulkRebuild(committedRebuild)
        } catch {
            // The durable staged journal predates the settings write. Recovery
            // uses the persisted settings revision, rather than this phase hint,
            // to recognize that commit already happened.
            throw AlarmCoordinatorError.postCommitCleanupFailed(
                error.localizedDescription
            )
        }

        let count: Int
        do {
            count = try await finalize(
                committedRebuild,
                settings: targetSettings,
                now: now
            )
            try persistPendingBulkRebuild(nil)
        } catch {
            throw AlarmCoordinatorError.postCommitCleanupFailed(
                error.localizedDescription
            )
        }
        let status = RefreshStatus(
            outcome: .prepared,
            message: "设置已保存，已重建 \(count) 条保底闹钟。",
            alarmDate: nextRecord(after: now)?.fireDate,
            updatedAt: now,
            forecastFetchedAt: nil,
            forecastWasStale: false
        )
        SettingsStore.saveStatus(status, defaults: defaults)
        return status
    }

    private func performRefreshTomorrow(
        settings: AppSettings,
        now: Date
    ) async throws -> RefreshStatus {
        try validate(settings)
        try await requireAuthorization()
        _ = try await ensureFallbackHorizon(settings: settings, now: now)
        try Task.checkCancellation()

        let calendar = settings.calendar
        guard let tomorrow = calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: now)
        ) else {
            throw AlarmCoordinatorError.unableToBuildDate
        }
        guard settings.isEnabledAlarmDay(tomorrow) else {
            let status = RefreshStatus(
                outcome: .skipped,
                message: "明天不是已启用的闹钟日，不安排闹钟。",
                alarmDate: nil,
                updatedAt: now,
                forecastFetchedAt: nil,
                forecastWasStale: false
            )
            SettingsStore.saveStatus(status, defaults: defaults)
            return status
        }

        let dateKey = makeDateKey(tomorrow, calendar: calendar)
        if let weatherConfigurationError = settings.weatherConfigurationError {
            return weatherFailureStatus(
                error: WeatherServiceError.invalidSettings(weatherConfigurationError),
                dateKey: dateKey,
                tomorrow: tomorrow,
                settings: settings,
                now: now
            )
        }
        let forecast: ServerForecast
        let evaluation: WeatherEvaluation
        do {
            forecast = try await weatherService.fetchForecast(settings: settings)
            try Task.checkCancellation()
            try WeatherService.validate(forecast, settings: settings, now: now)
            evaluation = try PrecipitationEvaluator.evaluate(
                forecast: forecast,
                targetDate: tomorrow,
                settings: settings,
                now: now
            )
        } catch {
            try Task.checkCancellation()
            return weatherFailureStatus(
                error: error,
                dateKey: dateKey,
                tomorrow: tomorrow,
                settings: settings,
                now: now
            )
        }

        guard let fireDate = settings.alarmTime(for: evaluation.kind).alarmDate(
            on: tomorrow,
            calendar: calendar
        ) else {
            throw AlarmCoordinatorError.unableToBuildDate
        }
        _ = try await replaceRecord(
            dateKey: dateKey,
            fireDate: fireDate,
            kind: evaluation.kind,
            now: now
        )

        let status = RefreshStatus(
            outcome: evaluation.kind == .rainy ? .rainy : .clear,
            message: "\(evaluation.summary)，闹钟设为 \(clockText(for: fireDate, calendar: calendar))。",
            alarmDate: fireDate,
            updatedAt: now,
            forecastFetchedAt: forecast.fetchedAt,
            forecastWasStale: forecast.stale
        )
        SettingsStore.saveStatus(status, defaults: defaults)
        return status
    }

    private func ensureFallbackHorizon(
        settings: AppSettings,
        now: Date
    ) async throws -> Int {
        try preparePersistedState()
        try pruneExpiredRecords(now: now)
        _ = try await reconcileSystemState(
            now: now,
            replacementRepairSettings: settings,
            allowExpiredReplacementResolution: true
        )
        try Task.checkCancellation()

        let calendar = settings.calendar
        let start = calendar.startOfDay(for: now)
        let protectedCurrentDayIDs = try protectCurrentCivilDayRecords(
            calendar: calendar,
            now: now
        )
        var activeIDs = Set(try await alarmDriver.alarms().map(\.id))
        var horizonDateKeys: Set<String> = []

        for offset in 1...AppSettings.fallbackHorizonDays {
            try Task.checkCancellation()
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else {
                throw AlarmCoordinatorError.unableToBuildDate
            }
            let dateKey = makeDateKey(day, calendar: calendar)
            horizonDateKeys.insert(dateKey)

            guard settings.isEnabledAlarmDay(day) else {
                if let existing = records.first(where: { $0.dateKey == dateKey }) {
                    try await cancelIfActive(existing.alarmID, activeIDs: activeIDs)
                    activeIDs.remove(existing.alarmID)
                    try removeRecord(dateKey: dateKey)
                }
                continue
            }

            if let existing = records.first(where: { $0.dateKey == dateKey }),
               let existingAlarm = try await systemAlarm(id: existing.alarmID),
               isSafeFutureAlarm(existingAlarm, matching: existing, now: now) {
                guard let expectedDate = settings.alarmTime(for: existing.kind).alarmDate(
                    on: day,
                    calendar: calendar
                ) else {
                    throw AlarmCoordinatorError.unableToBuildDate
                }
                if datesMatch(existing.fireDate, expectedDate) {
                    continue
                }
                let replacement = try await replaceRecord(
                    dateKey: dateKey,
                    fireDate: expectedDate,
                    kind: existing.kind,
                    now: now
                )
                activeIDs.remove(existing.alarmID)
                activeIDs.insert(replacement.alarmID)
                continue
            }

            guard let fallbackDate = settings.fallbackAlarmTime.alarmDate(
                on: day,
                calendar: calendar
            ) else {
                throw AlarmCoordinatorError.unableToBuildDate
            }
            let replacement = try await replaceRecord(
                dateKey: dateKey,
                fireDate: fallbackDate,
                kind: .fallback,
                now: now
            )
            activeIDs.insert(replacement.alarmID)
        }

        try await removeRecordsOutsideHorizon(
            horizonDateKeys,
            protectedAlarmIDs: protectedCurrentDayIDs,
            activeIDs: &activeIDs
        )
        try await cleanupRedundantUnknownAlarms(settings: settings, now: now)
        return records.count {
            $0.fireDate > now && horizonDateKeys.contains($0.dateKey)
        }
    }

    private func stageFallbackRebuild(
        settings: AppSettings,
        now: Date
    ) async throws -> PendingBulkAlarmRebuild {
        try preparePersistedState()
        try pruneExpiredRecords(now: now)
        let persistedRepairSettings: AppSettings?
        switch SettingsStore.loadPersistedSettingsResult(defaults: defaults) {
        case .success(let settings):
            persistedRepairSettings = settings
        case .failure(let error):
            throw AlarmCoordinatorError.persistence(error.localizedDescription)
        }
        _ = try await reconcileSystemState(
            now: now,
            replacementRepairSettings: persistedRepairSettings,
            allowExpiredReplacementResolution: true
        )
        try Task.checkCancellation()
        guard pendingBulkRebuild == nil else {
            throw AlarmCoordinatorError.persistence("存在尚未恢复的批量闹钟重建事务。")
        }

        let calendar = settings.calendar
        let start = calendar.startOfDay(for: now)
        let protectedCurrentDayIDs = try protectCurrentCivilDayRecords(
            calendar: calendar,
            now: now
        )
        let systemAlarms = try await alarmDriver.alarms()
        let alarmsByID = Dictionary(uniqueKeysWithValues: systemAlarms.map { ($0.id, $0) })
        var desiredDateKeys: Set<String> = []
        var desiredRecords: [ManagedAlarmRecord] = []
        var newlyScheduledRecords: [ManagedAlarmRecord] = []

        // Stage every desired alarm without replacing or canceling anything.
        // Settings are committed only after this complete safe set is verified.
        for offset in 1...AppSettings.fallbackHorizonDays {
            try Task.checkCancellation()
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else {
                throw AlarmCoordinatorError.unableToBuildDate
            }
            guard settings.isEnabledAlarmDay(day) else { continue }
            let dateKey = makeDateKey(day, calendar: calendar)
            desiredDateKeys.insert(dateKey)
            guard let fallbackDate = settings.fallbackAlarmTime.alarmDate(
                on: day,
                calendar: calendar
            ) else {
                throw AlarmCoordinatorError.unableToBuildDate
            }

            if let existing = records.first(where: { $0.dateKey == dateKey }),
               existing.kind == .fallback,
               let systemAlarm = alarmsByID[existing.alarmID],
               systemAlarm.state == .scheduled,
               let actualFireDate = systemAlarm.fireDate,
               datesMatch(actualFireDate, existing.fireDate),
               datesMatch(existing.fireDate, fallbackDate) {
                desiredRecords.append(existing)
                continue
            }

            let stagedRecord = ManagedAlarmRecord(
                dateKey: dateKey,
                alarmID: UUID(),
                fireDate: fallbackDate,
                kind: .fallback,
                updatedAt: now
            )
            desiredRecords.append(stagedRecord)
            newlyScheduledRecords.append(stagedRecord)
        }

        guard let targetCredentialOrigin = settings.credentialOrigin else {
            throw AlarmCoordinatorError.invalidSettings("天气服务器地址无效。")
        }
        var transaction = PendingBulkAlarmRebuild(
            transactionID: UUID(),
            phase: .staging,
            targetSettingsRevision: settings.settingsRevision,
            targetCredentialOrigin: targetCredentialOrigin,
            desiredDateKeys: desiredDateKeys.sorted(),
            desiredRecords: desiredRecords,
            newlyScheduledRecords: newlyScheduledRecords,
            protectedCurrentDayIDs: protectedCurrentDayIDs.sorted {
                $0.uuidString < $1.uuidString
            },
            originalRecords: records,
            createdAt: now
        )
        // The complete plan is durable before the first AlarmKit mutation.
        try persistPendingBulkRebuild(transaction)

        for record in transaction.newlyScheduledRecords {
            try Task.checkCancellation()
            try await alarmDriver.schedule(record)
        }
        try await verify(transaction, now: now)
        transaction.phase = .staged
        try persistPendingBulkRebuild(transaction)
        return transaction
    }

    private func verify(
        _ stagedRebuild: PendingBulkAlarmRebuild,
        now: Date
    ) async throws {
        try Task.checkCancellation()
        let systemAlarms = try await alarmDriver.alarms()
        let alarmsByID = Dictionary(uniqueKeysWithValues: systemAlarms.map { ($0.id, $0) })
        let recordDateKeys = Set(stagedRebuild.desiredRecords.map(\.dateKey))
        guard stagedRebuild.desiredRecords.count == stagedRebuild.desiredDateKeys.count,
              recordDateKeys == Set(stagedRebuild.desiredDateKeys) else {
            throw AlarmCoordinatorError.persistence("暂存保底闹钟未完整覆盖目标日期。")
        }

        for record in stagedRebuild.desiredRecords {
            guard let systemAlarm = alarmsByID[record.alarmID],
                  isSafeFutureAlarm(systemAlarm, matching: record, now: now) else {
                throw AlarmCoordinatorError.persistence(
                    "暂存保底闹钟未能通过 AlarmKit 核验。"
                )
            }
        }
    }

    private func finalize(
        _ stagedRebuild: PendingBulkAlarmRebuild,
        settings: AppSettings,
        now: Date
    ) async throws -> Int {
        var transaction = stagedRebuild
        transaction.phase = .finalizing
        try persistPendingBulkRebuild(transaction)

        if let pendingReplacement {
            try await recover(
                pendingReplacement,
                systemAlarms: try await alarmDriver.alarms(),
                now: now,
                repairSettings: settings,
                allowExpiredResolution: true
            )
        }
        transaction = try await rebaseBulkDesiredAlarms(
            transaction,
            settings: settings,
            now: now
        )

        for stagedRecord in transaction.desiredRecords {
            try Task.checkCancellation()
            if records.contains(where: {
                $0.dateKey == stagedRecord.dateKey
                    && $0.alarmID == stagedRecord.alarmID
            }) {
                try await verifySafeScheduledAlarm(stagedRecord, now: now)
            } else {
                try await commitStagedRecord(stagedRecord, now: now)
            }
        }

        // No old or disabled alarm is removed until the complete committed
        // horizon has been re-queried and proven scheduled.
        try await verify(transaction, now: now)
        var activeIDs = Set(try await alarmDriver.alarms().map(\.id))
        try await removeRecordsOutsideHorizon(
            Set(transaction.desiredDateKeys),
            protectedAlarmIDs: Set(transaction.protectedCurrentDayIDs),
            activeIDs: &activeIDs
        )
        try await cleanupRedundantUnknownAlarms(settings: settings, now: now)
        try await cleanupSupersededBulkAlarms(transaction)
        try await verify(transaction, now: now)
        return transaction.desiredDateKeys.count
    }

    private func commitStagedRecord(
        _ stagedRecord: ManagedAlarmRecord,
        now: Date
    ) async throws {
        // This re-query is deliberately adjacent to the record commit. A stale
        // snapshot must never authorize cancellation of the old scheduled alarm.
        try await verifySafeScheduledAlarm(stagedRecord, now: now)
        guard pendingReplacement == nil else {
            throw AlarmCoordinatorError.persistence("存在尚未恢复的闹钟替换事务。")
        }

        let oldRecord = records.first { $0.dateKey == stagedRecord.dateKey }
        var transaction = PendingAlarmReplacement(
            oldRecord: oldRecord,
            newRecord: stagedRecord,
            phase: .newAlarmScheduled
        )
        try persistPendingReplacement(transaction)

        var updatedRecords = records
        updatedRecords.removeAll { $0.dateKey == stagedRecord.dateKey }
        updatedRecords.append(stagedRecord)
        try persistRecords(updatedRecords)

        transaction.phase = .recordCommitted
        try persistPendingReplacement(transaction)

        // Re-query again after the UserDefaults write and before touching the old
        // alarm. If the staged alarm paused or disappeared, recovery restores the
        // old record and the old physical alarm remains untouched.
        do {
            try await verifySafeScheduledAlarm(stagedRecord, now: now)
        } catch {
            let systemAlarms = try await alarmDriver.alarms()
            try await recover(
                transaction,
                systemAlarms: systemAlarms,
                now: now
            )
            throw error
        }
        if let oldRecord,
           try await systemAlarm(id: oldRecord.alarmID) != nil {
            try await alarmDriver.cancel(id: oldRecord.alarmID)
        }
        try persistPendingReplacement(nil)
    }

    private func replaceRecord(
        dateKey: String,
        fireDate: Date,
        kind: ManagedAlarmKind,
        now: Date,
        honorCancellation: Bool = true
    ) async throws -> ManagedAlarmRecord {
        if honorCancellation {
            try Task.checkCancellation()
        }
        guard pendingReplacement == nil else {
            throw AlarmCoordinatorError.persistence("存在尚未恢复的闹钟替换事务。")
        }

        let oldRecord = records.first { $0.dateKey == dateKey }
        let newRecord = ManagedAlarmRecord(
            dateKey: dateKey,
            alarmID: UUID(),
            fireDate: fireDate,
            kind: kind,
            updatedAt: now
        )
        var transaction = PendingAlarmReplacement(
            oldRecord: oldRecord,
            newRecord: newRecord,
            phase: .prepared
        )
        try persistPendingReplacement(transaction)

        try await alarmDriver.schedule(newRecord)
        if honorCancellation {
            try Task.checkCancellation()
        }
        try await verifySafeScheduledAlarm(newRecord, now: now)
        transaction.phase = .newAlarmScheduled
        try persistPendingReplacement(transaction)

        var updatedRecords = records
        updatedRecords.removeAll { $0.dateKey == dateKey }
        updatedRecords.append(newRecord)
        try persistRecords(updatedRecords)

        transaction.phase = .recordCommitted
        try persistPendingReplacement(transaction)

        do {
            try await verifySafeScheduledAlarm(newRecord, now: now)
        } catch {
            try await recover(
                transaction,
                systemAlarms: try await alarmDriver.alarms(),
                now: now
            )
            throw error
        }
        if let oldRecord,
           try await systemAlarm(id: oldRecord.alarmID) != nil {
            try await alarmDriver.cancel(id: oldRecord.alarmID)
        }
        try persistPendingReplacement(nil)
        return newRecord
    }

    @discardableResult
    private func reconcileSystemState(
        now: Date,
        replacementRepairSettings: AppSettings? = nil,
        allowExpiredReplacementResolution: Bool = false
    ) async throws -> Bool {
        try preparePersistedState()
        var systemAlarms = try await alarmDriver.alarms()
        if let pendingReplacement {
            try await recover(
                pendingReplacement,
                systemAlarms: systemAlarms,
                now: now,
                repairSettings: replacementRepairSettings,
                allowExpiredResolution: allowExpiredReplacementResolution
            )
            systemAlarms = try await alarmDriver.alarms()
        }
        if pendingBulkRebuild != nil {
            try await recoverPendingBulkRebuild(now: now)
            systemAlarms = try await alarmDriver.alarms()
        }

        let alarmsByID = Dictionary(uniqueKeysWithValues: systemAlarms.map { ($0.id, $0) })
        var reconciledRecords: [ManagedAlarmRecord] = []
        reconciledRecords.reserveCapacity(records.count)
        var fullyVerified = pendingReplacement == nil && pendingBulkRebuild == nil

        for record in records {
            guard let systemAlarm = alarmsByID[record.alarmID] else {
                fullyVerified = false
                continue
            }
            guard let actualFireDate = systemAlarm.fireDate,
                  datesMatch(actualFireDate, record.fireDate) else {
                // Keep the system alarm as an untracked safety net. A later
                // horizon repair may remove it only after a verified managed
                // replacement exists for the same civil date.
                fullyVerified = false
                continue
            }
            guard record.fireDate <= now || systemAlarm.state == .scheduled else {
                // Paused/countdown/future states are not a wake-up guarantee.
                // Drop the persisted claim but retain the physical alarm as an
                // unknown safety net until a scheduled replacement is verified.
                fullyVerified = false
                continue
            }
            reconciledRecords.append(record)
        }

        if reconciledRecords != records {
            try persistRecords(reconciledRecords)
        }

        let reconciledIDs = Set(reconciledRecords.map(\.alarmID))
        if systemAlarms.contains(where: { !reconciledIDs.contains($0.id) }) {
            // Unknown alarms may be the only surviving copy after a crash between
            // AlarmKit and UserDefaults writes. Never delete them during snapshot,
            // and never describe this state as fully verified.
            fullyVerified = false
        }
        if fullyVerified {
            fullyVerified = try await hasVerifiedCommittedHorizon(now: now)
        }
        return fullyVerified
    }

    private func recover(
        _ transaction: PendingAlarmReplacement,
        systemAlarms: [SystemAlarmSnapshot],
        now: Date,
        repairSettings: AppSettings? = nil,
        allowExpiredResolution: Bool = false
    ) async throws {
        let alarmsByID = Dictionary(uniqueKeysWithValues: systemAlarms.map { ($0.id, $0) })
        let newSystemAlarm = alarmsByID[transaction.newRecord.alarmID]
        let newAlarmIsValid = newSystemAlarm.map {
            isSafeFutureAlarm($0, matching: transaction.newRecord, now: now)
        } ?? false

        if newAlarmIsValid {
            var recoveredRecords = records
            recoveredRecords.removeAll { $0.dateKey == transaction.newRecord.dateKey }
            recoveredRecords.append(transaction.newRecord)
            try persistRecords(recoveredRecords)

            var committed = transaction
            committed.phase = .recordCommitted
            try persistPendingReplacement(committed)

            if let oldRecord = transaction.oldRecord,
               let oldSystemAlarm = alarmsByID[oldRecord.alarmID],
               isSafeFutureAlarm(oldSystemAlarm, matching: oldRecord, now: now),
               oldRecord.alarmID != transaction.newRecord.alarmID {
                try await alarmDriver.cancel(id: oldRecord.alarmID)
            }
            try persistPendingReplacement(nil)
            return
        }

        var recoveredRecords = records
        recoveredRecords.removeAll { $0.dateKey == transaction.newRecord.dateKey }
        var recoveredOldRecord: ManagedAlarmRecord?
        if let oldRecord = transaction.oldRecord,
           let oldSystemAlarm = alarmsByID[oldRecord.alarmID],
           isSafeFutureAlarm(oldSystemAlarm, matching: oldRecord, now: now) {
            recoveredRecords.append(oldRecord)
            recoveredOldRecord = oldRecord
        }

        guard recoveredOldRecord != nil else {
            if let repairSettings {
                try await repairMissingReplacement(
                    transaction,
                    settings: repairSettings,
                    now: now,
                    allowExpiredResolution: allowExpiredResolution
                )
                return
            }
            // With neither a scheduled new alarm nor a scheduled old copy, the
            // journal is the only durable evidence that the horizon is unsafe.
            // Keep both journal and records untouched so snapshot cannot report a
            // false green state; an operation carrying committed settings can
            // repair the date and then rebuild the full horizon.
            throw AlarmCoordinatorError.persistence(
                "闹钟替换事务没有可核验的安全副本。"
            )
        }

        // A mismatched staged alarm may still be the only physical wake-up after
        // a crash. Remove it only when the verified old alarm is safely restored;
        // otherwise keep it as an unknown safety net for the next horizon repair.
        if recoveredOldRecord != nil,
           let newSystemAlarm,
           newSystemAlarm.state == .scheduled {
            try await alarmDriver.cancel(id: newSystemAlarm.id)
        }
        try persistRecords(recoveredRecords)
        try persistPendingReplacement(nil)
    }

    private func repairMissingReplacement(
        _ transaction: PendingAlarmReplacement,
        settings: AppSettings,
        now: Date,
        allowExpiredResolution: Bool
    ) async throws {
        let calendar = settings.calendar
        let day = calendar.startOfDay(for: transaction.newRecord.fireDate)
        guard settings.isEnabledAlarmDay(day) else {
            try persistRecords(records.filter {
                $0.dateKey != transaction.newRecord.dateKey
            })
            try persistPendingReplacement(nil)
            return
        }
        guard let fallbackDate = settings.fallbackAlarmTime.alarmDate(
            on: day,
            calendar: calendar
        ) else {
            throw AlarmCoordinatorError.unableToBuildDate
        }
        guard fallbackDate > now else {
            guard allowExpiredResolution else {
                throw AlarmCoordinatorError.persistence(
                    "闹钟替换日期已经过去，需要重建完整保底周期。"
                )
            }
            try persistRecords(records.filter {
                $0.dateKey != transaction.newRecord.dateKey
            })
            try persistPendingReplacement(nil)
            return
        }

        let repairRecord = ManagedAlarmRecord(
            dateKey: makeDateKey(day, calendar: calendar),
            alarmID: UUID(),
            fireDate: fallbackDate,
            kind: .fallback,
            updatedAt: now
        )
        var repairTransaction = PendingAlarmReplacement(
            oldRecord: nil,
            newRecord: repairRecord,
            phase: .prepared
        )
        // Swap the durable plan before the AlarmKit call. A crash at any later
        // point restarts recovery against this exact UUID.
        try persistPendingReplacement(repairTransaction)
        try await alarmDriver.schedule(repairRecord)
        try await verifySafeScheduledAlarm(repairRecord, now: now)
        repairTransaction.phase = .newAlarmScheduled
        try persistPendingReplacement(repairTransaction)

        var repairedRecords = records
        repairedRecords.removeAll {
            $0.dateKey == transaction.newRecord.dateKey
                || $0.dateKey == repairRecord.dateKey
                || $0.alarmID == transaction.newRecord.alarmID
        }
        repairedRecords.append(repairRecord)
        try persistRecords(repairedRecords)
        repairTransaction.phase = .recordCommitted
        try persistPendingReplacement(repairTransaction)
        // The AlarmKit snapshot used before the UserDefaults write is stale by
        // definition. Re-query immediately before clearing the only durable
        // recovery journal; failure leaves the recordCommitted transaction intact.
        try await verifySafeScheduledAlarm(repairRecord, now: now)
        try persistPendingReplacement(nil)
    }

    private func hasVerifiedCommittedHorizon(now: Date) async throws -> Bool {
        let committedSettings: AppSettings
        switch SettingsStore.loadPersistedSettingsResult(defaults: defaults) {
        case .success(.some(let settings)):
            committedSettings = settings
        case .success(nil), .failure:
            return false
        }
        guard committedSettings.validationError == nil else { return false }

        let calendar = committedSettings.calendar
        let start = calendar.startOfDay(for: now)
        var allHorizonDateKeys: Set<String> = []
        var enabledDaysByDateKey: [String: Date] = [:]
        for offset in 1...AppSettings.fallbackHorizonDays {
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else {
                return false
            }
            let dateKey = makeDateKey(day, calendar: calendar)
            allHorizonDateKeys.insert(dateKey)
            if committedSettings.isEnabledAlarmDay(day) {
                enabledDaysByDateKey[dateKey] = day
            }
        }

        let horizonRecords = records.filter {
            allHorizonDateKeys.contains($0.dateKey)
        }
        guard horizonRecords.count == enabledDaysByDateKey.count,
              Set(horizonRecords.map(\.dateKey)) == Set(enabledDaysByDateKey.keys) else {
            return false
        }

        let alarmsByID = Dictionary(uniqueKeysWithValues:
            try await alarmDriver.alarms().map { ($0.id, $0) }
        )
        for record in horizonRecords {
            guard let day = enabledDaysByDateKey[record.dateKey],
                  let expectedFireDate = committedSettings.alarmTime(
                      for: record.kind
                  ).alarmDate(on: day, calendar: calendar),
                  datesMatch(record.fireDate, expectedFireDate),
                  let alarm = alarmsByID[record.alarmID],
                  isSafeFutureAlarm(alarm, matching: record, now: now) else {
                return false
            }
        }
        return true
    }

    private func recoverPendingBulkRebuild(now: Date) async throws {
        guard let transaction = pendingBulkRebuild else { return }
        let persistedSettings: AppSettings?
        switch SettingsStore.loadPersistedSettingsResult(defaults: defaults) {
        case .success(let settings):
            persistedSettings = settings
        case .failure(let error):
            throw AlarmCoordinatorError.persistence(error.localizedDescription)
        }

        let settingsWereCommitted: Bool
        if let persistedSettings,
           persistedSettings.settingsRevision == transaction.targetSettingsRevision {
            guard persistedSettings.credentialOrigin == transaction.targetCredentialOrigin else {
                throw AlarmCoordinatorError.persistence(
                    "批量重建事务的设置版本与服务器范围不一致。"
                )
            }
            settingsWereCommitted = true
        } else {
            settingsWereCommitted = false
        }

        guard settingsWereCommitted, let persistedSettings else {
            try await rollbackPendingBulkRebuild(now: now)
            return
        }

        _ = try await finalize(
            transaction,
            settings: persistedSettings,
            now: now
        )
        try persistPendingBulkRebuild(nil)
    }

    private func rollbackPendingBulkRebuild(now: Date) async throws {
        guard let transaction = pendingBulkRebuild else { return }
        let oldSettings: AppSettings?
        switch SettingsStore.loadPersistedSettingsResult(defaults: defaults) {
        case .success(let settings):
            oldSettings = settings
        case .failure(let error):
            throw AlarmCoordinatorError.persistence(error.localizedDescription)
        }

        let plannedRecordsByID = Dictionary(
            uniqueKeysWithValues: transaction.newlyScheduledRecords.map {
                ($0.alarmID, $0)
            }
        )
        let plannedIDs = Set(plannedRecordsByID.keys)
        var retainedSafetyRecords: [ManagedAlarmRecord] = []
        var conservativelyPreservedIDs: Set<UUID> = []
        var expiredOpaqueIDs: Set<UUID> = []

        for id in plannedIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let plannedRecord = plannedRecordsByID[id],
                  let alarm = try await systemAlarm(id: id) else {
                continue
            }
            if plannedRecord.fireDate <= now {
                // This alarm can no longer protect a future wake-up. Scheduled
                // copies can be removed; opaque non-scheduled copies remain
                // unknown but must not hold the transaction open forever.
                if alarm.state == .scheduled {
                    try await alarmDriver.cancel(id: id)
                } else {
                    expiredOpaqueIDs.insert(id)
                }
                continue
            }

            let oldCandidates = (transaction.originalRecords + records).filter {
                $0.dateKey == plannedRecord.dateKey && $0.alarmID != id
            }
            var hasVerifiedOldCopy = false
            for candidate in oldCandidates {
                if let candidateAlarm = try await systemAlarm(id: candidate.alarmID),
                   isSafeFutureAlarm(candidateAlarm, matching: candidate, now: now) {
                    hasVerifiedOldCopy = true
                    break
                }
            }
            let wasExplicitlyDisabled = transaction.originalRecords.allSatisfy {
                $0.dateKey != plannedRecord.dateKey
            } && oldSettings.map {
                !$0.isEnabledAlarmDay(plannedRecord.fireDate)
            } == true

            if !hasVerifiedOldCopy,
               !wasExplicitlyDisabled,
               alarm.state != .scheduled,
               let oldSettings,
               let repair = try await scheduleRollbackSafety(
                   for: plannedRecord,
                   settings: oldSettings,
                   now: now
               ) {
                try await verifySafeScheduledAlarm(repair, now: now)
                hasVerifiedOldCopy = true
            }

            if hasVerifiedOldCopy || wasExplicitlyDisabled {
                let calendar = oldSettings?.calendar ?? AppSettings().calendar
                if alarm.state == .alerting
                    || (alarm.state != .scheduled
                        && calendar.isDate(plannedRecord.fireDate, inSameDayAs: now)) {
                    // Current-day opaque states can represent an in-flight alert.
                    // Keep the physical alarm unknown, but do not let it block
                    // future horizon maintenance.
                    conservativelyPreservedIDs.insert(id)
                } else {
                    // This UUID is transaction-owned, so once another scheduled
                    // copy is verified it is safe to cancel paused/countdown and
                    // other known states as well as `.scheduled`.
                    if try await systemAlarm(id: id) != nil {
                        try await alarmDriver.cancel(id: id)
                    }
                }
            } else if alarm.state == .scheduled {
                // CFPreferences can expose the old settings payload after a
                // partially finalized transaction. If the old alarm is already
                // gone, this staged alarm may be the only wake-up left.
                retainedSafetyRecords.append(plannedRecord)
            } else {
                throw AlarmCoordinatorError.persistence(
                    "暂存闹钟不是可用安全副本，且旧设置闹钟尚未修复。"
                )
            }
        }

        let remainingAlarms = Dictionary(uniqueKeysWithValues:
            try await alarmDriver.alarms().map { ($0.id, $0) }
        )
        let retainedIDs = Set(retainedSafetyRecords.map(\.alarmID))
        let unexpectedRemainingIDs = Set(remainingAlarms.keys)
            .intersection(plannedIDs)
            .subtracting(retainedIDs)
            .subtracting(conservativelyPreservedIDs)
            .subtracting(expiredOpaqueIDs)
            .filter { id in
                guard let plannedRecord = plannedRecordsByID[id] else { return true }
                return plannedRecord.fireDate > now
            }
        guard unexpectedRemainingIDs.isEmpty else {
            throw AlarmCoordinatorError.persistence("暂存闹钟回滚核验未通过。")
        }
        for record in retainedSafetyRecords {
            guard let alarm = remainingAlarms[record.alarmID],
                  isSafeFutureAlarm(alarm, matching: record, now: now) else {
                throw AlarmCoordinatorError.persistence(
                    "无法证明回滚后仍有安全闹钟。"
                )
            }
        }

        if !retainedSafetyRecords.isEmpty {
            var repairedRecords = records
            let retainedDateKeys = Set(retainedSafetyRecords.map(\.dateKey))
            repairedRecords.removeAll { retainedDateKeys.contains($0.dateKey) }
            repairedRecords.append(contentsOf: retainedSafetyRecords)
            try persistRecords(repairedRecords)
        }
        try persistPendingBulkRebuild(nil)

        // Once the staged safety net is represented as managed state, the old
        // settings can safely rebuild its intended time using normal
        // schedule-before-cancel replacement semantics.
        if !retainedSafetyRecords.isEmpty, let oldSettings {
            _ = try await ensureFallbackHorizon(settings: oldSettings, now: now)
        }
    }

    private func scheduleRollbackSafety(
        for stagedRecord: ManagedAlarmRecord,
        settings: AppSettings,
        now: Date
    ) async throws -> ManagedAlarmRecord? {
        let calendar = settings.calendar
        let day = calendar.startOfDay(for: stagedRecord.fireDate)
        guard settings.isEnabledAlarmDay(day),
              let fireDate = settings.fallbackAlarmTime.alarmDate(
                  on: day,
                  calendar: calendar
              ),
              fireDate > now else {
            return nil
        }
        return try await replaceRecord(
            dateKey: makeDateKey(day, calendar: calendar),
            fireDate: fireDate,
            kind: .fallback,
            now: now,
            honorCancellation: false
        )
    }

    private func rebaseBulkDesiredAlarms(
        _ originalTransaction: PendingBulkAlarmRebuild,
        settings: AppSettings,
        now: Date
    ) async throws -> PendingBulkAlarmRebuild {
        var transaction = originalTransaction
        let calendar = settings.calendar
        let start = calendar.startOfDay(for: now)
        let initialSystemAlarms = try await alarmDriver.alarms()
        let initialAlarmsByID = Dictionary(
            uniqueKeysWithValues: initialSystemAlarms.map { ($0.id, $0) }
        )

        // A journal created yesterday may contain today's only future alarm even
        // though finalization never reached the managed-record write. Adopt every
        // verified candidate before rolling the desired window forward so cleanup
        // cannot mistake it for obsolete transaction debris.
        let currentDaySafetyRecords = transaction.newlyScheduledRecords.filter {
            guard calendar.isDate($0.fireDate, inSameDayAs: now),
                  let alarm = initialAlarmsByID[$0.alarmID] else {
                return false
            }
            return isSafeFutureAlarm(alarm, matching: $0, now: now)
        }
        let existingCurrentDaySafety = records.filter {
            guard calendar.isDate($0.fireDate, inSameDayAs: now),
                  let alarm = initialAlarmsByID[$0.alarmID] else {
                return false
            }
            return isSafeFutureAlarm(alarm, matching: $0, now: now)
        }
        let canonicalCurrentDayRecord = (
            existingCurrentDaySafety.isEmpty
                ? currentDaySafetyRecords
                : existingCurrentDaySafety
        ).sorted(by: recordOrdering).first
        if let canonicalCurrentDayRecord,
           !records.contains(where: {
               $0.alarmID == canonicalCurrentDayRecord.alarmID
           }) {
            var protectedRecords = records.filter {
                !calendar.isDate($0.fireDate, inSameDayAs: now)
            }
            protectedRecords.append(ManagedAlarmRecord(
                dateKey: makeDateKey(
                    canonicalCurrentDayRecord.fireDate,
                    calendar: calendar
                ),
                alarmID: canonicalCurrentDayRecord.alarmID,
                fireDate: canonicalCurrentDayRecord.fireDate,
                kind: canonicalCurrentDayRecord.kind,
                updatedAt: canonicalCurrentDayRecord.updatedAt
            ))
            try persistRecords(protectedRecords)
        }
        let protectedCurrentDayIDs = try protectCurrentCivilDayRecords(
            calendar: calendar,
            now: now
        )
        let systemAlarms = try await alarmDriver.alarms()
        let alarmsByID = Dictionary(uniqueKeysWithValues: systemAlarms.map { ($0.id, $0) })
        var desiredDateKeys: [String] = []
        var desiredRecords: [ManagedAlarmRecord] = []
        var recordsToSchedule: [ManagedAlarmRecord] = []

        for offset in 1...AppSettings.fallbackHorizonDays {
            try Task.checkCancellation()
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else {
                throw AlarmCoordinatorError.unableToBuildDate
            }
            guard settings.isEnabledAlarmDay(day) else { continue }
            let dateKey = makeDateKey(day, calendar: calendar)
            guard let fireDate = settings.fallbackAlarmTime.alarmDate(
                on: day,
                calendar: calendar
            ) else {
                throw AlarmCoordinatorError.unableToBuildDate
            }
            desiredDateKeys.append(dateKey)

            let priorPlanned = transaction.desiredRecords.first {
                $0.dateKey == dateKey
                    && $0.kind == .fallback
                    && datesMatch($0.fireDate, fireDate)
            }
            if let priorPlanned,
               let alarm = alarmsByID[priorPlanned.alarmID],
               isSafeFutureAlarm(alarm, matching: priorPlanned, now: now) {
                desiredRecords.append(priorPlanned)
                continue
            }
            if let priorPlanned,
               alarmsByID[priorPlanned.alarmID] == nil,
               !transaction.originalRecords.contains(where: {
                   $0.alarmID == priorPlanned.alarmID
               }) {
                desiredRecords.append(priorPlanned)
                recordsToSchedule.append(priorPlanned)
                if !transaction.newlyScheduledRecords.contains(where: {
                    $0.alarmID == priorPlanned.alarmID
                }) {
                    transaction.newlyScheduledRecords.append(priorPlanned)
                }
                continue
            }

            if let reusableRecord = records.first(where: {
                $0.dateKey == dateKey
                    && $0.kind == .fallback
                    && datesMatch($0.fireDate, fireDate)
            }),
               let reusableAlarm = alarmsByID[reusableRecord.alarmID],
               isSafeFutureAlarm(reusableAlarm, matching: reusableRecord, now: now) {
                desiredRecords.append(reusableRecord)
                continue
            }

            let replacement = ManagedAlarmRecord(
                dateKey: dateKey,
                alarmID: UUID(),
                fireDate: fireDate,
                kind: .fallback,
                updatedAt: now
            )
            desiredRecords.append(replacement)
            recordsToSchedule.append(replacement)
            transaction.newlyScheduledRecords.append(replacement)
        }

        transaction.desiredDateKeys = desiredDateKeys
        transaction.desiredRecords = desiredRecords
        transaction.protectedCurrentDayIDs = protectedCurrentDayIDs.sorted {
            $0.uuidString < $1.uuidString
        }
        // Persist the complete rolling plan before scheduling any newly needed
        // alarm. This also drops expired desired dates after a delayed restart.
        try persistPendingBulkRebuild(transaction)

        for record in recordsToSchedule {
            try Task.checkCancellation()
            try await alarmDriver.schedule(record)
            try await verifySafeScheduledAlarm(record, now: now)
        }
        try await verify(transaction, now: now)
        return transaction
    }

    private func cleanupSupersededBulkAlarms(
        _ transaction: PendingBulkAlarmRebuild
    ) async throws {
        let desiredIDs = Set(transaction.desiredRecords.map(\.alarmID))
        let protectedIDs = Set(transaction.protectedCurrentDayIDs)
        let managedIDs = Set(records.map(\.alarmID))
        let alarmsByID = Dictionary(uniqueKeysWithValues:
            try await alarmDriver.alarms().map { ($0.id, $0) }
        )

        for record in transaction.newlyScheduledRecords {
            guard !desiredIDs.contains(record.alarmID),
                  !protectedIDs.contains(record.alarmID),
                  !managedIDs.contains(record.alarmID),
                  let alarm = alarmsByID[record.alarmID],
                  alarm.state == .scheduled else {
                continue
            }
            // The current rolling desired set was already fully verified.
            // Historical transaction alarms are now redundant, including ones
            // whose planned day expired while the app was not running.
            try await alarmDriver.cancel(id: record.alarmID)
        }
    }

    private func verifySafeScheduledAlarm(
        _ record: ManagedAlarmRecord,
        now: Date
    ) async throws {
        guard let alarm = try await systemAlarm(id: record.alarmID),
              isSafeFutureAlarm(alarm, matching: record, now: now) else {
            throw AlarmCoordinatorError.persistence(
                "暂存闹钟在提交前未处于已排程状态。"
            )
        }
    }

    private func systemAlarm(id: UUID) async throws -> SystemAlarmSnapshot? {
        try await alarmDriver.alarms().first { $0.id == id }
    }

    private func isSafeFutureAlarm(
        _ alarm: SystemAlarmSnapshot,
        matching record: ManagedAlarmRecord,
        now: Date
    ) -> Bool {
        guard record.fireDate > now,
              alarm.state == .scheduled,
              let actualFireDate = alarm.fireDate else {
            return false
        }
        return datesMatch(actualFireDate, record.fireDate)
    }

    private func weatherFailureStatus(
        error: Error,
        dateKey: String,
        tomorrow: Date,
        settings: AppSettings,
        now: Date
    ) -> RefreshStatus {
        let existing = records.first { $0.dateKey == dateKey }
        let retainedTime = existing?.fireDate
            ?? settings.fallbackAlarmTime.alarmDate(
                on: tomorrow,
                calendar: settings.calendar
            )
        let retainedDescription: String
        if let existing, existing.kind != .fallback {
            retainedDescription = "保留最近一次有效判断"
        } else {
            retainedDescription = "保留默认保底闹钟"
        }
        let status = RefreshStatus(
            outcome: .fallback,
            message: "\(weatherFailureMessage(for: error))；\(retainedDescription)。",
            alarmDate: retainedTime,
            updatedAt: now,
            forecastFetchedAt: nil,
            forecastWasStale: false
        )
        SettingsStore.saveStatus(status, defaults: defaults)
        return status
    }

    private func weatherFailureMessage(for error: Error) -> String {
        switch error {
        case let weatherError as WeatherServiceError:
            return weatherError.localizedDescription
        case let evaluationError as PrecipitationEvaluationError:
            return evaluationError.localizedDescription
        case let urlError as URLError:
            switch urlError.code {
            case .notConnectedToInternet:
                return "天气更新失败：当前没有网络连接"
            case .timedOut:
                return "天气更新失败：连接天气服务器超时"
            case .cancelled:
                return "天气更新已取消"
            default:
                return "天气更新失败：无法连接天气服务器"
            }
        default:
            // Never surface arbitrary upstream response bodies or implementation details.
            return "天气更新失败：天气服务暂时不可用"
        }
    }

    private func removeRecordsOutsideHorizon(
        _ retainedDateKeys: Set<String>,
        protectedAlarmIDs: Set<UUID>,
        activeIDs: inout Set<UUID>
    ) async throws {
        let obsoleteRecords = records.filter {
            !protectedAlarmIDs.contains($0.alarmID)
                && !retainedDateKeys.contains($0.dateKey)
        }
        guard !obsoleteRecords.isEmpty else { return }

        for record in obsoleteRecords {
            try await cancelIfActive(record.alarmID, activeIDs: activeIDs)
            activeIDs.remove(record.alarmID)
        }
        let obsoleteKeys = Set(obsoleteRecords.map(\.dateKey))
        try persistRecords(records.filter { !obsoleteKeys.contains($0.dateKey) })
    }

    private func cleanupRedundantUnknownAlarms(
        settings: AppSettings,
        now: Date
    ) async throws {
        let systemAlarms = try await alarmDriver.alarms()
        let alarmsByID = Dictionary(uniqueKeysWithValues: systemAlarms.map { ($0.id, $0) })
        let knownIDs = Set(records.map(\.alarmID))
        let calendar = settings.calendar
        let knownSafeDateKeys = Set(records.compactMap { record -> String? in
            guard record.fireDate > now,
                  let systemAlarm = alarmsByID[record.alarmID],
                  systemAlarm.state == .scheduled,
                  let actualFireDate = systemAlarm.fireDate,
                  datesMatch(actualFireDate, record.fireDate) else {
                return nil
            }
            return makeDateKey(actualFireDate, calendar: calendar)
        })
        let tomorrowStart = calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: now)
        )
        let horizonEnd = tomorrowStart.flatMap {
            calendar.date(
                byAdding: .day,
                value: AppSettings.fallbackHorizonDays,
                to: $0
            )
        }

        for alarm in systemAlarms {
            guard !knownIDs.contains(alarm.id),
                  alarm.state == .scheduled,
                  let fireDate = alarm.fireDate else {
                continue
            }
            let isExpired = fireDate <= now
            let hasKnownReplacement = knownSafeDateKeys.contains(
                makeDateKey(fireDate, calendar: calendar)
            )
            let isDisabledWithinVerifiedHorizon: Bool
            if let tomorrowStart, let horizonEnd,
               fireDate >= tomorrowStart, fireDate < horizonEnd {
                isDisabledWithinVerifiedHorizon = !settings.isEnabledAlarmDay(fireDate)
            } else {
                isDisabledWithinVerifiedHorizon = false
            }
            if isExpired || hasKnownReplacement || isDisabledWithinVerifiedHorizon {
                try await alarmDriver.cancel(id: alarm.id)
            }
        }
    }

    private func protectCurrentCivilDayRecords(
        calendar: Calendar,
        now: Date
    ) throws -> Set<UUID> {
        let dayStart = calendar.startOfDay(for: now)

        // Normalize every managed record to its true date in the scheduling
        // calendar. If migration/recovery produced duplicates for one civil
        // date, manage exactly one canonical alarm; the others remain unknown
        // until cleanup verifies and removes the redundancy.
        var canonicalByDateKey: [String: ManagedAlarmRecord] = [:]
        for record in records.sorted(by: recordOrdering) {
            let trueDateKey = makeDateKey(record.fireDate, calendar: calendar)
            guard canonicalByDateKey[trueDateKey] == nil else { continue }
            canonicalByDateKey[trueDateKey] = ManagedAlarmRecord(
                dateKey: trueDateKey,
                alarmID: record.alarmID,
                fireDate: record.fireDate,
                kind: record.kind,
                updatedAt: record.updatedAt
            )
        }
        let normalizedRecords = canonicalByDateKey.values.sorted(by: recordOrdering)

        if normalizedRecords != records.sorted(by: recordOrdering) {
            try persistRecords(normalizedRecords)
        }
        let currentDateKey = makeDateKey(dayStart, calendar: calendar)
        return Set(
            normalizedRecords
                .filter { $0.dateKey == currentDateKey && $0.fireDate > now }
                .map(\.alarmID)
        )
    }

    private func cancelIfActive(_ id: UUID, activeIDs: Set<UUID>) async throws {
        guard activeIDs.contains(id) else { return }
        try await alarmDriver.cancel(id: id)
    }

    private func removeRecord(dateKey: String) throws {
        try persistRecords(records.filter { $0.dateKey != dateKey })
    }

    private func pruneExpiredRecords(now: Date) throws {
        let retained = records.filter { $0.fireDate > now }
        if retained != records {
            try persistRecords(retained)
        }
    }

    private func persistRecords(_ newRecords: [ManagedAlarmRecord]) throws {
        let sorted = newRecords.sorted { $0.fireDate < $1.fireDate }
        do {
            try SettingsStore.saveRecordsThrowing(sorted, defaults: defaults)
            records = sorted
        } catch {
            throw AlarmCoordinatorError.persistence(error.localizedDescription)
        }
    }

    private func persistPendingReplacement(
        _ transaction: PendingAlarmReplacement?
    ) throws {
        do {
            try SettingsStore.savePendingReplacementThrowing(
                transaction,
                defaults: defaults
            )
            pendingReplacement = transaction
        } catch {
            throw AlarmCoordinatorError.persistence(error.localizedDescription)
        }
    }

    private func persistPendingBulkRebuild(
        _ transaction: PendingBulkAlarmRebuild?
    ) throws {
        do {
            try SettingsStore.savePendingBulkRebuildThrowing(
                transaction,
                defaults: defaults
            )
            pendingBulkRebuild = transaction
        } catch {
            throw AlarmCoordinatorError.persistence(error.localizedDescription)
        }
    }

    private func preparePersistedState() throws {
        if let persistenceError {
            throw AlarmCoordinatorError.persistence(persistenceError.localizedDescription)
        }
    }

    private func validate(_ settings: AppSettings) throws {
        if let validationError = settings.validationError {
            throw AlarmCoordinatorError.invalidSettings(validationError)
        }
        try preparePersistedState()
    }

    private func requireAuthorization() async throws {
        switch await alarmDriver.authorizationState() {
        case .authorized:
            return
        case .denied:
            throw AlarmCoordinatorError.authorizationDenied
        case .notDetermined:
            throw AlarmCoordinatorError.authorizationRequired
        }
    }

    private func requestOrRequireAuthorization() async throws {
        switch await alarmDriver.authorizationState() {
        case .authorized:
            return
        case .denied:
            throw AlarmCoordinatorError.authorizationDenied
        case .notDetermined:
            guard try await alarmDriver.requestAuthorization() == .authorized else {
                throw AlarmCoordinatorError.authorizationDenied
            }
        }
    }

    private func nextRecord(after date: Date) -> ManagedAlarmRecord? {
        records.filter { $0.fireDate > date }.min { $0.fireDate < $1.fireDate }
    }

    private func makeDateKey(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private func datesMatch(_ lhs: Date, _ rhs: Date) -> Bool {
        abs(lhs.timeIntervalSince(rhs)) < 1
    }

    private func clockText(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return String(
            format: "%02d:%02d",
            components.hour ?? 0,
            components.minute ?? 0
        )
    }

    private func recordOrdering(
        _ lhs: ManagedAlarmRecord,
        _ rhs: ManagedAlarmRecord
    ) -> Bool {
        if lhs.fireDate != rhs.fireDate {
            return lhs.fireDate < rhs.fireDate
        }
        return lhs.alarmID.uuidString < rhs.alarmID.uuidString
    }

    private func saveFailureStatus(message: String, now: Date) {
        let status = RefreshStatus(
            outcome: .failed,
            message: message,
            alarmDate: nextRecord(after: now)?.fireDate,
            updatedAt: now,
            forecastFetchedAt: nil,
            forecastWasStale: false
        )
        SettingsStore.saveStatus(status, defaults: defaults)
    }
}
