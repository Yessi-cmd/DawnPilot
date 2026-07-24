import Foundation

enum AppOperationIssueFactory {
    static func make(for error: Error) -> AppPresentationState.OperationIssue {
        if let coordinatorError = error as? AlarmCoordinatorError {
            return make(for: coordinatorError)
        }
        if let weatherError = error as? WeatherServiceError {
            return make(for: weatherError)
        }
        if let settingsError = error as? SettingsStoreError {
            return make(for: settingsError)
        }
        if error is URLError {
            return AppPresentationState.OperationIssue(
                title: "网络连接失败",
                message: "无法连接天气服务器。明日安全闹钟会继续保留，请检查网络后重试。",
                recoveryAction: nil
            )
        }
        return AppPresentationState.OperationIssue(
            title: "操作未完成",
            message: "系统闹钟没有按预期更新。请稍后重试；如果仍然失败，请检查权限和设置。",
            recoveryAction: nil
        )
    }

    private static func make(
        for error: AlarmCoordinatorError
    ) -> AppPresentationState.OperationIssue {
        switch error {
        case .authorizationDenied:
            AppPresentationState.OperationIssue(
                title: "系统闹钟权限未开启",
                message: "请前往系统设置，允许晨航使用系统闹钟，然后返回重试。",
                recoveryAction: .openSystemSettings
            )
        case .authorizationRequired:
            AppPresentationState.OperationIssue(
                title: "需要系统闹钟权限",
                message: "请先授权晨航使用系统闹钟，再创建或更新闹钟。",
                recoveryAction: nil
            )
        case .invalidSettings(let message):
            AppPresentationState.OperationIssue(
                title: "请检查设置",
                message: message,
                recoveryAction: .editSettings
            )
        case .unableToBuildDate:
            AppPresentationState.OperationIssue(
                title: "无法生成闹钟日期",
                message: "请检查固定时区和各项时间设置后重试。",
                recoveryAction: .editSettings
            )
        case .persistence:
            AppPresentationState.OperationIssue(
                title: "闹钟记录未能安全保存",
                message: "晨航没有继续修改系统闹钟，以免丢失现有保护。请稍后重试。",
                recoveryAction: nil
            )
        case .settingsCommitFailed:
            AppPresentationState.OperationIssue(
                title: "设置未能保存",
                message: "暂存变更已安全回滚，本机仍保留旧设置和原有闹钟。请检查设置后重试。",
                recoveryAction: .editSettings
            )
        case .postCommitCleanupFailed:
            AppPresentationState.OperationIssue(
                title: "旧闹钟清理未完成",
                message: "新设置和新保底闹钟已经保存；部分旧闹钟可能暂时重复，请稍后重试清理。",
                recoveryAction: nil
            )
        }
    }

    private static func make(
        for error: WeatherServiceError
    ) -> AppPresentationState.OperationIssue {
        switch error {
        case .server(let statusCode, _) where statusCode == 401:
            AppPresentationState.OperationIssue(
                title: "访问令牌无效",
                message: "天气服务器拒绝了访问。请重新填写访问令牌后重试。",
                recoveryAction: .editSettings
            )
        case .invalidSettings(let message):
            AppPresentationState.OperationIssue(
                title: "请检查天气设置",
                message: message,
                recoveryAction: .editSettings
            )
        case .invalidServerResponse:
            AppPresentationState.OperationIssue(
                title: "天气服务器暂时不可用",
                message: "服务器返回了无法识别的数据；明日安全闹钟会继续保留。请稍后重试。",
                recoveryAction: .editSettings
            )
        case .unsupportedSchemaVersion:
            AppPresentationState.OperationIssue(
                title: "天气服务器版本不兼容",
                message: "服务器返回了当前版本无法识别的数据。安全闹钟会继续保留，请检查服务器配置。",
                recoveryAction: .editSettings
            )
        case .responseTimezoneMismatch:
            AppPresentationState.OperationIssue(
                title: "天气服务器时区不一致",
                message: "返回的预报不属于当前固定时区，因此没有用于调整闹钟。请检查服务器和时区设置。",
                recoveryAction: .editSettings
            )
        case .invalidForecast:
            AppPresentationState.OperationIssue(
                title: "天气预报数据不完整",
                message: "返回的预报未通过完整性检查，因此没有用于调整闹钟。安全闹钟会继续保留。",
                recoveryAction: .editSettings
            )
        case .server:
            AppPresentationState.OperationIssue(
                title: "天气服务器暂时不可用",
                message: "服务器暂时无法完成请求；明日安全闹钟会继续保留。请稍后重试。",
                recoveryAction: .editSettings
            )
        }
    }

    private static func make(
        for error: SettingsStoreError
    ) -> AppPresentationState.OperationIssue {
        switch error {
        case .credential:
            AppPresentationState.OperationIssue(
                title: "访问令牌未能安全保存",
                message: "设置没有写入。请解锁设备后重试；晨航不会继续使用未保存的令牌更新天气。",
                recoveryAction: .editSettings
            )
        case .unsupportedVersion, .corrupted, .recoveryRequired:
            AppPresentationState.OperationIssue(
                title: "设置需要恢复",
                message: "晨航没有覆盖现有设置。请检查恢复提示，确认设置后再重建闹钟。",
                recoveryAction: .editSettings
            )
        case .invalidRecords:
            AppPresentationState.OperationIssue(
                title: "闹钟记录需要修复",
                message: "已有闹钟记录未通过完整性检查，因此没有继续修改系统闹钟。",
                recoveryAction: nil
            )
        }
    }
}
