import Foundation

struct ServerForecast: Decodable, Sendable {
    let schemaVersion: Int
    let source: String
    let fetchedAt: Date
    let servedAt: Date
    let stale: Bool
    let latitude: Double
    let longitude: Double
    let timezone: String
    let hourly: [ForecastHour]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case source
        case fetchedAt = "fetched_at"
        case servedAt = "served_at"
        case stale
        case latitude
        case longitude
        case timezone
        case hourly
    }
}

struct ForecastHour: Decodable, Equatable, Sendable {
    let time: Date
    let precipitationProbability: Double?
    let precipitationMM: Double?
    let rainMM: Double?
    let showersMM: Double?
    let snowfallCM: Double?
    let weatherCode: Int?

    enum CodingKeys: String, CodingKey {
        case time
        case precipitationProbability = "precipitation_probability"
        case precipitationMM = "precipitation_mm"
        case rainMM = "rain_mm"
        case showersMM = "showers_mm"
        case snowfallCM = "snowfall_cm"
        case weatherCode = "weather_code"
    }
}

enum ManagedAlarmKind: String, Codable, Sendable {
    case rainy
    case clear
    case fallback

    var displayName: String {
        switch self {
        case .rainy: "有降水"
        case .clear: "无降水"
        case .fallback: "保底"
        }
    }
}

struct WeatherEvaluation: Equatable, Sendable {
    let kind: ManagedAlarmKind
    let maximumProbability: Double
    let maximumPrecipitationMM: Double
    let matchingHourCount: Int

    var summary: String {
        switch kind {
        case .rainy:
            "通勤时段预计有降水（最高概率 \(Int(maximumProbability.rounded()))%）"
        case .clear:
            "通勤时段未达到降水阈值（最高概率 \(Int(maximumProbability.rounded()))%）"
        case .fallback:
            "天气不可用，使用保底时间"
        }
    }
}

struct ManagedAlarmRecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID { alarmID }
    let dateKey: String
    let alarmID: UUID
    let fireDate: Date
    let kind: ManagedAlarmKind
    let updatedAt: Date
}

enum RefreshOutcome: String, Codable, Sendable {
    case rainy
    case clear
    case fallback
    case skipped
    case prepared
    case failed
}

struct RefreshStatus: Codable, Equatable, Sendable {
    let outcome: RefreshOutcome
    let message: String
    let alarmDate: Date?
    let updatedAt: Date
    let forecastFetchedAt: Date?
    let forecastWasStale: Bool

    static let empty = RefreshStatus(
        outcome: .prepared,
        message: "尚未更新明日闹钟",
        alarmDate: nil,
        updatedAt: .distantPast,
        forecastFetchedAt: nil,
        forecastWasStale: false
    )
}
