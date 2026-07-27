import Foundation

enum AppPresentationState {
    enum SnapshotState: Equatable, Sendable {
        case loading
        case loaded
    }

    enum AlarmVerificationState: Equatable, Sendable {
        case loading
        case verified(Date)
        case unconfirmed
    }

    enum OperationPhase: Equatable, Sendable {
        case idle
        case authorizing
        case rebuildingFallbacks
        case refreshingWeather

        var message: String {
            switch self {
            case .idle:
                ""
            case .authorizing:
                "正在授权并准备保底闹钟…"
            case .rebuildingFallbacks:
                "正在重建未来 14 天的保底闹钟…"
            case .refreshingWeather:
                "正在获取天气并更新起床闹钟…"
            }
        }
    }

    enum RecoveryAction: Equatable, Sendable {
        case editSettings
        case openSystemSettings
    }

    struct OperationIssue: Identifiable, Equatable, Sendable {
        let id = UUID()
        let title: String
        let message: String
        let recoveryAction: RecoveryAction?
    }
}
