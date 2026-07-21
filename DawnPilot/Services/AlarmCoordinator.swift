@preconcurrency import AlarmKit
import Foundation
import SwiftUI

struct DawnPilotMetadata: AlarmMetadata {
    let dateKey: String
    let kind: ManagedAlarmKind
    let createdAt: Date
}

struct CoordinatorSnapshot: Sendable {
    let authorizationText: String
    let records: [ManagedAlarmRecord]
    let status: RefreshStatus
}

enum AlarmCoordinatorError: LocalizedError {
    case authorizationDenied
    case authorizationRequired
    case invalidSettings(String)
    case unableToBuildDate

    var errorDescription: String? {
        switch self {
        case .authorizationDenied:
            "闹钟权限已被拒绝，请在系统设置中允许晨航使用 AlarmKit。"
        case .authorizationRequired:
            "请先打开晨航并完成 AlarmKit 授权。"
        case .invalidSettings(let message):
            message
        case .unableToBuildDate:
            "无法生成闹钟日期，请检查时区和时间设置。"
        }
    }
}

enum AlarmRefreshTrigger: Sendable {
    case scheduled
    case userInitiated

    func originForTomorrow(
        isEnabledAlarmDay: Bool,
        existingOrigin: ManagedAlarmOrigin?
    ) -> ManagedAlarmOrigin? {
        if isEnabledAlarmDay {
            return .automatic
        }
        if self == .userInitiated || existingOrigin == .manualOverride {
            return .manualOverride
        }
        return nil
    }
}

actor AlarmCoordinator {
    static let shared = AlarmCoordinator()

    private typealias Configuration = AlarmManager.AlarmConfiguration<DawnPilotMetadata>

    private let alarmManager = AlarmManager.shared
    private let weatherService = WeatherService()
    private var records: [ManagedAlarmRecord]

    private init() {
        records = SettingsStore.loadRecords()
    }

    func snapshot(now: Date = Date()) -> CoordinatorSnapshot {
        pruneExpiredRecords(now: now)
        return CoordinatorSnapshot(
            authorizationText: authorizationText(for: alarmManager.authorizationState),
            records: records.sorted { $0.fireDate < $1.fireDate },
            status: SettingsStore.loadStatus()
        )
    }

    func authorizeAndPrepare(settings: AppSettings, now: Date = Date()) async throws -> RefreshStatus {
        try validate(settings)
        let state: AlarmManager.AuthorizationState
        switch alarmManager.authorizationState {
        case .notDetermined:
            state = try await alarmManager.requestAuthorization()
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
        SettingsStore.saveStatus(status)
        return status
    }

    func rebuildFallbacks(settings: AppSettings, now: Date = Date()) async throws -> RefreshStatus {
        try validate(settings)
        try requireAuthorization()
        try await resetFutureRecordsToFallback(settings: settings, now: now)
        let count = try await ensureFallbackHorizon(settings: settings, now: now)
        let status = RefreshStatus(
            outcome: .prepared,
            message: "设置已保存，已重建 \(count) 条保底闹钟。",
            alarmDate: nextRecord(after: now)?.fireDate,
            updatedAt: now,
            forecastFetchedAt: nil,
            forecastWasStale: false
        )
        SettingsStore.saveStatus(status)
        return status
    }

    func cancelAlarm(dateKey: String) async throws {
        try requireAuthorization()
        let activeIDs = Set(try alarmManager.alarms.map(\.id))
        guard let existing = records.first(where: { $0.dateKey == dateKey }) else {
            return
        }
        // Persist removal before cancelling the system alarm so a crash
        // between the two does not leave a zombie record in UserDefaults.
        records.removeAll { $0.dateKey == dateKey }
        persistRecords()
        do {
            try cancelIfActive(existing.alarmID, activeIDs: activeIDs)
        } catch {
            // Rollback: restore the record so UI and system stay consistent.
            records.append(existing)
            persistRecords()
            throw error
        }
    }

    func refreshTomorrow(
        settings: AppSettings,
        now: Date = Date(),
        trigger: AlarmRefreshTrigger = .scheduled
    ) async throws -> RefreshStatus {
        try validate(settings)
        try requireAuthorization()

        let calendar = settings.calendar
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else {
            throw AlarmCoordinatorError.unableToBuildDate
        }
        let dateKey = makeDateKey(tomorrow, calendar: calendar)

        _ = try await ensureFallbackHorizon(
            settings: settings,
            now: now,
            preservingDateKey: trigger == .userInitiated ? dateKey : nil
        )
        let isEnabledAlarmDay = settings.isEnabledAlarmDay(tomorrow)
        let existingOrigin = records.first { $0.dateKey == dateKey }?.origin
        guard let origin = trigger.originForTomorrow(
            isEnabledAlarmDay: isEnabledAlarmDay,
            existingOrigin: existingOrigin
        ) else {
            let status = RefreshStatus(
                outcome: .skipped,
                message: "明天不是常规闹钟日；如需临时闹钟，请在晨航中点击“临时设明日闹钟”。",
                alarmDate: nil,
                updatedAt: now,
                forecastFetchedAt: nil,
                forecastWasStale: false
            )
            SettingsStore.saveStatus(status)
            return status
        }

        if let existing = records.first(where: { $0.dateKey == dateKey }) {
            if existing.origin != origin {
                try await replaceRecord(
                    dateKey: dateKey,
                    fireDate: existing.fireDate,
                    kind: existing.kind,
                    origin: origin,
                    now: now
                )
            }
        } else {
            guard let fallbackDate = settings.fallbackAlarmTime.date(on: tomorrow, calendar: calendar) else {
                throw AlarmCoordinatorError.unableToBuildDate
            }
            try await replaceRecord(
                dateKey: dateKey,
                fireDate: fallbackDate,
                kind: .fallback,
                origin: origin,
                now: now
            )
        }

        do {
            let forecast = try await weatherService.fetchForecast(settings: settings)
            let evaluation = try PrecipitationEvaluator.evaluate(
                forecast: forecast,
                targetDate: tomorrow,
                settings: settings,
                now: now
            )
            guard let fireDate = settings.alarmTime(for: evaluation.kind).date(on: tomorrow, calendar: calendar) else {
                throw AlarmCoordinatorError.unableToBuildDate
            }
            try await replaceRecord(
                dateKey: dateKey,
                fireDate: fireDate,
                kind: evaluation.kind,
                origin: origin,
                now: now
            )

            let message: String
            if origin == .manualOverride {
                message = "明天不是常规闹钟日，已临时设置：\(evaluation.summary)，闹钟为 \(settings.alarmTime(for: evaluation.kind).displayText)。"
            } else {
                message = "\(evaluation.summary)，闹钟设为 \(settings.alarmTime(for: evaluation.kind).displayText)。"
            }
            let status = RefreshStatus(
                outcome: evaluation.kind == .rainy ? .rainy : .clear,
                message: message,
                alarmDate: fireDate,
                updatedAt: now,
                forecastFetchedAt: forecast.fetchedAt,
                forecastWasStale: forecast.stale
            )
            SettingsStore.saveStatus(status)
            return status
        } catch {
            let existing = records.first { $0.dateKey == dateKey }
            let retainedTime = existing?.fireDate ?? settings.fallbackAlarmTime.date(on: tomorrow, calendar: calendar)
            let retainedDescription: String
            if let existing, existing.kind != .fallback {
                retainedDescription = "保留最近一次有效判断"
            } else {
                retainedDescription = "保留默认保底闹钟"
            }
            let temporaryDescription = origin == .manualOverride ? "临时闹钟已保留；" : ""
            let status = RefreshStatus(
                outcome: .fallback,
                message: "\(temporaryDescription)天气更新失败：\(error.localizedDescription)；\(retainedDescription)。",
                alarmDate: retainedTime,
                updatedAt: now,
                forecastFetchedAt: nil,
                forecastWasStale: false
            )
            SettingsStore.saveStatus(status)
            return status
        }
    }

    private func ensureFallbackHorizon(
        settings: AppSettings,
        now: Date,
        preservingDateKey: String? = nil
    ) async throws -> Int {
        let activeIDs = Set(try alarmManager.alarms.map(\.id))
        pruneExpiredRecords(now: now, activeIDs: activeIDs)

        let calendar = settings.calendar
        let start = calendar.startOfDay(for: now)
        for offset in 1...AppSettings.fallbackHorizonDays {
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else {
                throw AlarmCoordinatorError.unableToBuildDate
            }
            let dateKey = makeDateKey(day, calendar: calendar)

            guard settings.isEnabledAlarmDay(day) else {
                if let existing = records.first(where: { $0.dateKey == dateKey }) {
                    if (existing.origin == .manualOverride || dateKey == preservingDateKey),
                       activeIDs.contains(existing.alarmID) {
                        continue
                    }
                    try cancelIfActive(existing.alarmID, activeIDs: activeIDs)
                    records.removeAll { $0.dateKey == dateKey }
                    persistRecords()
                }
                continue
            }

            if let existing = records.first(where: { $0.dateKey == dateKey }),
               activeIDs.contains(existing.alarmID) {
                let expectedTime = settings.alarmTime(for: existing.kind)
                guard let expectedDate = expectedTime.date(on: day, calendar: calendar) else {
                    throw AlarmCoordinatorError.unableToBuildDate
                }
                if abs(existing.fireDate.timeIntervalSince(expectedDate)) < 1 {
                    continue
                }
                try await replaceRecord(
                    dateKey: dateKey,
                    fireDate: expectedDate,
                    kind: existing.kind,
                    origin: existing.origin,
                    now: now,
                    knownActiveIDs: activeIDs
                )
                continue
            }

            records.removeAll { $0.dateKey == dateKey }
            guard let fallbackDate = settings.fallbackAlarmTime.date(on: day, calendar: calendar) else {
                throw AlarmCoordinatorError.unableToBuildDate
            }
            try await replaceRecord(
                dateKey: dateKey,
                fireDate: fallbackDate,
                kind: .fallback,
                origin: .automatic,
                now: now,
                knownActiveIDs: activeIDs
            )
        }
        persistRecords()
        return records.filter { $0.fireDate > now }.count
    }

    private func resetFutureRecordsToFallback(settings: AppSettings, now: Date) async throws {
        let activeIDs = Set(try alarmManager.alarms.map(\.id))
        let calendar = settings.calendar
        for record in records where record.fireDate > now {
            guard let day = calendar.date(from: calendar.dateComponents([.year, .month, .day], from: record.fireDate)) else {
                try cancelIfActive(record.alarmID, activeIDs: activeIDs)
                records.removeAll { $0.dateKey == record.dateKey }
                persistRecords()
                continue
            }
            let shouldKeep = settings.isEnabledAlarmDay(day) || record.origin == .manualOverride
            guard shouldKeep,
                  let fallbackDate = settings.fallbackAlarmTime.date(on: day, calendar: calendar) else {
                try cancelIfActive(record.alarmID, activeIDs: activeIDs)
                records.removeAll { $0.dateKey == record.dateKey }
                persistRecords()
                continue
            }
            if record.kind == .fallback,
               abs(record.fireDate.timeIntervalSince(fallbackDate)) < 1,
               activeIDs.contains(record.alarmID) {
                continue
            }
            try await replaceRecord(
                dateKey: record.dateKey,
                fireDate: fallbackDate,
                kind: .fallback,
                origin: record.origin,
                now: now,
                knownActiveIDs: activeIDs
            )
        }
    }

    private func replaceRecord(
        dateKey: String,
        fireDate: Date,
        kind: ManagedAlarmKind,
        origin: ManagedAlarmOrigin,
        now: Date,
        knownActiveIDs: Set<UUID>? = nil
    ) async throws {
        let newID = UUID()
        let metadata = DawnPilotMetadata(dateKey: dateKey, kind: kind, createdAt: now)
        let attributes = AlarmAttributes(
            presentation: alarmPresentation(),
            metadata: metadata,
            tintColor: .indigo
        )
        let configuration = Configuration(
            schedule: .fixed(fireDate),
            attributes: attributes
        )

        _ = try await alarmManager.schedule(id: newID, configuration: configuration)
        // Re-read oldRecord after the suspension point to avoid stale
        // actor state — a re-entrant call may have already mutated records.
        let oldRecord = records.first { $0.dateKey == dateKey }
        if let oldRecord {
            do {
                let activeIDs = try knownActiveIDs ?? Set(alarmManager.alarms.map(\.id))
                try cancelIfActive(oldRecord.alarmID, activeIDs: activeIDs)
            } catch {
                try? alarmManager.cancel(id: newID)
                throw error
            }
        }

        records.removeAll { $0.dateKey == dateKey }
        records.append(ManagedAlarmRecord(
            dateKey: dateKey,
            alarmID: newID,
            fireDate: fireDate,
            kind: kind,
            origin: origin,
            updatedAt: now
        ))
        persistRecords()
    }

    private func cancelIfActive(_ id: UUID, activeIDs: Set<UUID>) throws {
        guard activeIDs.contains(id) else { return }
        try alarmManager.cancel(id: id)
    }

    private func alarmPresentation() -> AlarmPresentation {
        let alert: AlarmPresentation.Alert
        if #available(iOS 26.1, *) {
            alert = AlarmPresentation.Alert(title: "通勤起床")
        } else {
            let stopButton = AlarmButton(
                text: "停止",
                textColor: .white,
                systemImageName: "stop.circle.fill"
            )
            alert = AlarmPresentation.Alert(title: "通勤起床", stopButton: stopButton)
        }
        return AlarmPresentation(alert: alert)
    }

    private func validate(_ settings: AppSettings) throws {
        if let validationError = settings.validationError {
            throw AlarmCoordinatorError.invalidSettings(validationError)
        }
    }

    private func requireAuthorization() throws {
        switch alarmManager.authorizationState {
        case .authorized:
            return
        case .denied:
            throw AlarmCoordinatorError.authorizationDenied
        case .notDetermined:
            throw AlarmCoordinatorError.authorizationRequired
        @unknown default:
            throw AlarmCoordinatorError.authorizationRequired
        }
    }

    private func pruneExpiredRecords(now: Date, activeIDs: Set<UUID>? = nil) {
        records.removeAll { record in
            record.fireDate <= now || (activeIDs.map { !$0.contains(record.alarmID) } ?? false)
        }
        persistRecords()
    }

    private func persistRecords() {
        SettingsStore.saveRecords(records.sorted { $0.fireDate < $1.fireDate })
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

    private func authorizationText(for state: AlarmManager.AuthorizationState) -> String {
        switch state {
        case .notDetermined: "尚未授权"
        case .denied: "已拒绝"
        case .authorized: "已授权"
        @unknown default: "未知"
        }
    }
}
