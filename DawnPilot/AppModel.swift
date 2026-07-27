import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    typealias SnapshotState = AppPresentationState.SnapshotState
    typealias AlarmVerificationState = AppPresentationState.AlarmVerificationState
    typealias OperationPhase = AppPresentationState.OperationPhase
    typealias RecoveryAction = AppPresentationState.RecoveryAction
    typealias OperationIssue = AppPresentationState.OperationIssue

    @Published var settings: AppSettings
    @Published private(set) var status: RefreshStatus
    @Published private(set) var records: [ManagedAlarmRecord] = []
    @Published private(set) var authorization: AlarmAuthorization?
    @Published private(set) var isWorking = false
    @Published private(set) var snapshotState: SnapshotState = .loading
    @Published private(set) var alarmVerificationState: AlarmVerificationState = .loading
    @Published private(set) var operationPhase: OperationPhase = .idle
    @Published private(set) var operationIssue: OperationIssue?
    @Published private(set) var operationSuccessMessage: String?

    private var snapshotLoadTask: Task<Void, Never>?

    init() {
        settings = SettingsStore.loadSettings()
        status = SettingsStore.loadStatus()
    }

    var nextRecord: ManagedAlarmRecord? {
        records.first { $0.fireDate > Date.now }
    }

    var isAuthorized: Bool {
        authorization == .authorized
    }

    var authorizationText: String {
        switch authorization {
        case .none: "读取中"
        case .notDetermined: "尚未授权"
        case .denied: "已拒绝"
        case .authorized: "已授权"
        }
    }

    var needsWeatherConfiguration: Bool {
        configurationGuidance != nil
    }

    var configurationGuidance: String? {
        if settings.storageRecoveryMessage != nil {
            return "本机设置未能安全读取。请打开设置核对内容；晨航不会在确认前修改闹钟。"
        }
        if let validationError = settings.validationError {
            return validationError
        }
        return weatherConfigurationIssue(for: settings)
    }

    var statusSummary: String {
        statusSummary(for: status)
    }

    func loadSnapshot() {
        guard !isWorking else { return }

        snapshotLoadTask?.cancel()
        snapshotState = .loading
        alarmVerificationState = .loading
        snapshotLoadTask = Task {
            let snapshot = await AlarmCoordinator.shared.snapshot()
            guard !Task.isCancelled else { return }
            apply(snapshot)
            snapshotState = .loaded
        }
    }

    func authorizeAndPrepare() {
        let requestedSettings = settings
        guard validate(requestedSettings) else { return }
        guard beginOperation(.authorizing) else { return }

        Task {
            do {
                let result = try await AlarmCoordinator.shared.authorizeAndPrepare(
                    settings: requestedSettings
                )
                await finishOperation(with: result)
            } catch {
                await finishOperation(with: error, settingsWereSaved: false)
            }
        }
    }

    func refreshNow() {
        let requestedSettings = settings
        guard validate(requestedSettings) else { return }
        guard weatherConfigurationIssue(for: requestedSettings) == nil else {
            presentWeatherConfigurationIssue(for: requestedSettings)
            return
        }
        guard beginOperation(.refreshingWeather) else { return }

        Task {
            do {
                let result = try await AlarmCoordinator.shared.refreshUpcoming(
                    settings: requestedSettings
                )
                await finishOperation(with: result)
            } catch {
                await finishOperation(with: error, settingsWereSaved: false)
            }
        }
    }

    func saveAndRebuild() {
        saveAndRebuild(
            settings: settings,
            includeWeatherRefresh: true,
            confirmsExampleLocation: settings.exampleLocationConfirmed
        )
    }

    func saveAndRebuild(
        settings requestedSettings: AppSettings,
        includeWeatherRefresh: Bool,
        confirmsExampleLocation: Bool
    ) {
        var normalizedCandidate = requestedSettings
        normalizedCandidate.exampleLocationConfirmed =
            normalizedCandidate.isUsingExampleLocation && confirmsExampleLocation
        let normalizedSettings = normalizedCandidate

        guard validate(normalizedSettings) else { return }
        if includeWeatherRefresh,
           weatherConfigurationIssue(
               for: normalizedSettings
           ) != nil {
            presentWeatherConfigurationIssue(for: normalizedSettings)
            return
        }
        let shouldRequestAuthorization = !isAuthorized
        guard beginOperation(
            shouldRequestAuthorization ? .authorizing : .rebuildingFallbacks
        ) else {
            return
        }

        Task {
            var fallbacksWereRebuilt = false
            var settingsWereSaved = false
            do {
                var result = try await AlarmCoordinator.shared.rebuildFallbacks(
                    settings: normalizedSettings,
                    requestAuthorizationIfNeeded: shouldRequestAuthorization
                )
                fallbacksWereRebuilt = true
                settingsWereSaved = true
                let committedSettings = SettingsStore.loadSettings()
                guard committedSettings.storageRecoveryMessage == nil else {
                    throw AlarmCoordinatorError.persistence(
                        committedSettings.storageRecoveryMessage
                            ?? "无法读取刚刚保存的设置。"
                    )
                }
                settings = committedSettings

                if includeWeatherRefresh {
                    operationPhase = .refreshingWeather
                    result = try await AlarmCoordinator.shared.refreshUpcoming(
                        settings: committedSettings
                    )
                }
                await finishOperation(with: result)
            } catch {
                if let coordinatorError = error as? AlarmCoordinatorError {
                    switch coordinatorError {
                    case .settingsCommitFailed:
                        break
                    case .postCommitCleanupFailed:
                        fallbacksWereRebuilt = true
                        settingsWereSaved = true
                        let committedSettings = SettingsStore.loadSettings()
                        if committedSettings.storageRecoveryMessage == nil {
                            settings = committedSettings
                        }
                    default:
                        break
                    }
                }
                await finishOperation(
                    with: error,
                    settingsWereSaved: settingsWereSaved,
                    fallbacksWereRebuilt: fallbacksWereRebuilt
                )
            }
        }
    }

    func weatherConfigurationIssue(
        for candidate: AppSettings,
        confirmsExampleLocation: Bool? = nil
    ) -> String? {
        var normalizedCandidate = candidate
        if let confirmsExampleLocation {
            normalizedCandidate.exampleLocationConfirmed =
                normalizedCandidate.isUsingExampleLocation && confirmsExampleLocation
        }
        return normalizedCandidate.weatherConfigurationError
    }

    func isUsingExampleLocation(_ candidate: AppSettings) -> Bool {
        candidate.isUsingExampleLocation
    }

    func isExampleLocationConfirmed(_ candidate: AppSettings) -> Bool {
        guard isUsingExampleLocation(candidate) else { return true }
        return candidate.exampleLocationConfirmed
    }

    @discardableResult
    func replaceRecoveredSettings(
        with candidate: AppSettings,
        confirmsExampleLocation: Bool
    ) -> Bool {
        guard !isWorking, candidate.storageRecoveryMessage != nil else { return false }

        var recoveredSettings = candidate
        recoveredSettings.clearStorageRecoveryMarker()
        recoveredSettings.exampleLocationConfirmed =
            recoveredSettings.isUsingExampleLocation && confirmsExampleLocation
        guard validate(recoveredSettings) else { return false }

        do {
            settings = try SettingsStore.replaceCorruptedSettings(recoveredSettings)
            operationIssue = nil
            operationSuccessMessage = "设置已恢复。请继续创建保底闹钟或更新起床闹钟。"
            return true
        } catch {
            presentIssue(AppOperationIssueFactory.make(for: error))
            return false
        }
    }

    func dismissOperationIssue() {
        operationIssue = nil
    }

    func dismissOperationSuccess() {
        operationSuccessMessage = nil
    }

    private func beginOperation(_ phase: OperationPhase) -> Bool {
        guard !isWorking else { return false }
        snapshotLoadTask?.cancel()
        isWorking = true
        operationPhase = phase
        operationIssue = nil
        operationSuccessMessage = nil
        return true
    }

    private func validate(_ candidate: AppSettings) -> Bool {
        if candidate.storageRecoveryMessage != nil {
            presentIssue(
                OperationIssue(
                    title: "设置需要恢复",
                    message: "本机设置未能安全读取。请打开设置核对内容，并明确确认是否替换旧设置。",
                    recoveryAction: .editSettings
                )
            )
            return false
        }
        guard let validationError = candidate.validationError else { return true }
        presentIssue(
            OperationIssue(
                title: "请检查设置",
                message: validationError,
                recoveryAction: .editSettings
            )
        )
        return false
    }

    private func presentWeatherConfigurationIssue(for candidate: AppSettings) {
        let message = weatherConfigurationIssue(for: candidate)
            ?? "请先检查天气服务器、访问令牌和固定位置设置。"
        presentIssue(
            OperationIssue(
                title: "天气更新尚未配置完成",
                message: message,
                recoveryAction: .editSettings
            )
        )
    }

    private func presentIssue(_ issue: OperationIssue) {
        operationIssue = issue
        operationSuccessMessage = nil
    }

    private func finishOperation(with result: RefreshStatus) async {
        let snapshot = await AlarmCoordinator.shared.snapshot()
        apply(snapshot)
        snapshotState = .loaded

        if result.outcome == .fallback {
            presentIssue(
                OperationIssue(
                    title: "天气更新未成功",
                    message: "\(result.message) 请检查网络、访问令牌和服务器设置后重试。",
                    recoveryAction: .editSettings
                )
            )
        } else {
            operationIssue = nil
            operationSuccessMessage = statusSummary(for: result)
        }
        operationPhase = .idle
        isWorking = false
    }

    private func finishOperation(
        with error: Error,
        settingsWereSaved: Bool,
        fallbacksWereRebuilt: Bool = false
    ) async {
        let snapshot = await AlarmCoordinator.shared.snapshot()
        apply(snapshot)
        snapshotState = .loaded

        var issue = AppOperationIssueFactory.make(for: error)
        if settingsWereSaved,
           issue.recoveryAction != .openSystemSettings {
            issue = OperationIssue(
                title: "设置已保存，但完整更新未完成",
                message: issue.message,
                recoveryAction: issue.recoveryAction
            )
        } else if fallbacksWereRebuilt {
            issue = OperationIssue(
                title: "保底闹钟已重建，但设置未保存",
                message: "\(issue.message) 旧设置仍保留在本机；请重试保存以保持后续自动维护一致。",
                recoveryAction: .editSettings
            )
        }
        presentIssue(issue)
        operationPhase = .idle
        isWorking = false
    }

    private func statusSummary(for status: RefreshStatus) -> String {
        switch status.outcome {
        case .fallback:
            "天气更新未完成，已保留安全闹钟。"
        case .failed:
            "最近一次闹钟更新失败。"
        case .rainy, .clear, .skipped, .prepared:
            status.message
        }
    }

    private func apply(_ snapshot: CoordinatorSnapshot) {
        authorization = snapshot.authorization
        records = snapshot.records
        status = snapshot.status
        alarmVerificationState = snapshot.alarmsVerified
            ? .verified(Date.now)
            : .unconfirmed
    }

}
