@preconcurrency import AlarmKit
import Foundation
import SwiftUI

struct DawnPilotMetadata: AlarmMetadata {
    let dateKey: String
    let kind: ManagedAlarmKind
    let createdAt: Date
}

enum AlarmAuthorization: Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
}

enum SystemAlarmState: Equatable, Sendable {
    case scheduled
    case countdown
    case paused
    case alerting
    case unknown
}

struct SystemAlarmSnapshot: Sendable {
    let id: UUID
    let fireDate: Date?
    let state: SystemAlarmState
}

protocol AlarmScheduling: Sendable {
    func authorizationState() async -> AlarmAuthorization
    func requestAuthorization() async throws -> AlarmAuthorization
    func alarms() async throws -> [SystemAlarmSnapshot]
    func schedule(_ record: ManagedAlarmRecord) async throws
    func cancel(id: UUID) async throws
}

protocol ForecastFetching: Sendable {
    func fetchForecast(settings: AppSettings) async throws -> ServerForecast
}

extension WeatherService: ForecastFetching {}

// AlarmManager is not declared Sendable. Keeping it as actor-confined state avoids
// transferring it across tasks while still exposing a fully Sendable test seam.
actor AlarmKitAlarmDriver: AlarmScheduling {
    private typealias Configuration = AlarmManager.AlarmConfiguration<DawnPilotMetadata>

    private let alarmManager = AlarmManager.shared

    func authorizationState() -> AlarmAuthorization {
        map(alarmManager.authorizationState)
    }

    func requestAuthorization() async throws -> AlarmAuthorization {
        map(try await alarmManager.requestAuthorization())
    }

    func alarms() throws -> [SystemAlarmSnapshot] {
        try alarmManager.alarms.map { alarm in
            let fireDate: Date?
            switch alarm.schedule {
            case .fixed(let date):
                fireDate = date
            case .relative, .none:
                fireDate = nil
            @unknown default:
                fireDate = nil
            }
            return SystemAlarmSnapshot(
                id: alarm.id,
                fireDate: fireDate,
                state: map(alarm.state)
            )
        }
    }

    func schedule(_ record: ManagedAlarmRecord) async throws {
        let metadata = DawnPilotMetadata(
            dateKey: record.dateKey,
            kind: record.kind,
            createdAt: record.updatedAt
        )
        let attributes = AlarmAttributes(
            presentation: alarmPresentation(),
            metadata: metadata,
            tintColor: .indigo
        )
        let configuration = Configuration(
            schedule: .fixed(record.fireDate),
            attributes: attributes
        )
        _ = try await alarmManager.schedule(id: record.alarmID, configuration: configuration)
    }

    func cancel(id: UUID) throws {
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

    private func map(_ state: AlarmManager.AuthorizationState) -> AlarmAuthorization {
        switch state {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized: .authorized
        @unknown default: .notDetermined
        }
    }

    private func map(_ state: Alarm.State) -> SystemAlarmState {
        switch state {
        case .scheduled: .scheduled
        case .countdown: .countdown
        case .paused: .paused
        case .alerting: .alerting
        // A future AlarmKit state must not be treated as safely cancellable.
        @unknown default: .unknown
        }
    }
}
