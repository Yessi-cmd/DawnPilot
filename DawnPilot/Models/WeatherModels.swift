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

    var iconName: String {
        switch self {
        case .rainy: "cloud.rain.fill"
        case .clear: "sun.horizon.fill"
        case .fallback: "cloud.fog.fill"
        }
    }
}

enum ManagedAlarmOrigin: String, Codable, Sendable {
    case automatic
    case manualOverride
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
    let origin: ManagedAlarmOrigin
    let updatedAt: Date

    init(
        dateKey: String,
        alarmID: UUID,
        fireDate: Date,
        kind: ManagedAlarmKind,
        origin: ManagedAlarmOrigin = .automatic,
        updatedAt: Date
    ) {
        self.dateKey = dateKey
        self.alarmID = alarmID
        self.fireDate = fireDate
        self.kind = kind
        self.origin = origin
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case dateKey
        case alarmID
        case fireDate
        case kind
        case origin
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dateKey = try container.decode(String.self, forKey: .dateKey)
        alarmID = try container.decode(UUID.self, forKey: .alarmID)
        fireDate = try container.decode(Date.self, forKey: .fireDate)
        kind = try container.decode(ManagedAlarmKind.self, forKey: .kind)
        origin = try container.decodeIfPresent(ManagedAlarmOrigin.self, forKey: .origin) ?? .automatic
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    func dateDescription(calendar: Calendar) -> String {
        let components = calendar.dateComponents([.month, .day, .weekday], from: fireDate)
        let names = ["星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"]
        let weekday = max(1, min(7, components.weekday ?? 1)) - 1
        return "\(components.month ?? 0)月\(components.day ?? 0)日 · \(names[weekday])"
    }

    var kindDescription: String {
        let prefix = origin == .manualOverride ? "临时 · " : ""
        return prefix + kind.displayName
    }
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
