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
    /// Share of ensemble members reaching commute-changing rain. Absent when the
    /// server could not build it from ensemble members.
    let significantPrecipitationProbability: Double?
    let precipitationMM: Double?
    let rainMM: Double?
    let showersMM: Double?
    let snowfallCM: Double?
    let weatherCode: Int?

    enum CodingKeys: String, CodingKey {
        case time
        case precipitationProbability = "precipitation_probability"
        case significantPrecipitationProbability = "precipitation_probability_significant"
        case precipitationMM = "precipitation_mm"
        case rainMM = "rain_mm"
        case showersMM = "showers_mm"
        case snowfallCM = "snowfall_cm"
        case weatherCode = "weather_code"
    }

    /// The significant-rain probability is optional so payloads from a server
    /// without ensemble data keep compiling and decoding unchanged.
    init(
        time: Date,
        precipitationProbability: Double?,
        significantPrecipitationProbability: Double? = nil,
        precipitationMM: Double?,
        rainMM: Double?,
        showersMM: Double?,
        snowfallCM: Double?,
        weatherCode: Int?
    ) {
        self.time = time
        self.precipitationProbability = precipitationProbability
        self.significantPrecipitationProbability = significantPrecipitationProbability
        self.precipitationMM = precipitationMM
        self.rainMM = rainMM
        self.showersMM = showersMM
        self.snowfallCM = snowfallCM
        self.weatherCode = weatherCode
    }

    var hasWeatherSignal: Bool {
        precipitationProbability != nil
            || precipitationMM != nil
            || rainMM != nil
            || showersMM != nil
            || snowfallCM != nil
            || weatherCode != nil
    }

    var weatherSignalValidationError: String? {
        for (name, probability) in [
            ("降水概率", precipitationProbability),
            ("明显降水概率", significantPrecipitationProbability)
        ] {
            if let probability, !probability.isFinite || !(0...100).contains(probability) {
                return "\(name)必须在 0 到 100 之间。"
            }
        }

        let measurements = [
            ("总降水量", precipitationMM),
            ("降雨量", rainMM),
            ("阵雨量", showersMM),
            ("降雪量", snowfallCM)
        ]
        for (name, value) in measurements {
            if let value, !value.isFinite || value < 0 {
                return "\(name)不能为负数或非有限值。"
            }
        }

        if let weatherCode, !(0...99).contains(weatherCode) {
            return "WMO 天气代码超出有效范围。"
        }
        return nil
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
    /// Nil when the server could not provide member-derived significant-rain
    /// probabilities for every hour of the window.
    let maximumSignificantProbability: Double?
    let maximumPrecipitationMM: Double
    let matchingHourCount: Int

    init(
        kind: ManagedAlarmKind,
        maximumProbability: Double,
        maximumSignificantProbability: Double? = nil,
        maximumPrecipitationMM: Double,
        matchingHourCount: Int
    ) {
        self.kind = kind
        self.maximumProbability = maximumProbability
        self.maximumSignificantProbability = maximumSignificantProbability
        self.maximumPrecipitationMM = maximumPrecipitationMM
        self.matchingHourCount = matchingHourCount
    }

    var summary: String {
        let measurable = Int(maximumProbability.rounded())
        switch kind {
        case .rainy:
            if let maximumSignificantProbability {
                return "通勤时段预计有明显降水（≥0.5mm 概率 \(Int(maximumSignificantProbability.rounded()))%）"
            }
            return "通勤时段预计有降水（最高概率 \(measurable)%）"
        case .fallback:
            return "通勤时段可能有零星小雨（降水概率 \(measurable)%），取折中时间"
        case .clear:
            return "通勤时段未达到降水阈值（最高概率 \(measurable)%）"
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

enum PendingAlarmReplacementPhase: String, Codable, Sendable {
    case prepared
    case newAlarmScheduled
    case recordCommitted
}

struct PendingAlarmReplacement: Codable, Equatable, Sendable {
    let oldRecord: ManagedAlarmRecord?
    let newRecord: ManagedAlarmRecord
    var phase: PendingAlarmReplacementPhase
}

enum BulkAlarmRebuildPhase: String, Codable, Sendable {
    case staging
    case staged
    case settingsCommitted
    case finalizing
}

struct PendingBulkAlarmRebuild: Codable, Equatable, Sendable {
    let transactionID: UUID
    var phase: BulkAlarmRebuildPhase
    let targetSettingsRevision: UUID
    let targetCredentialOrigin: String
    var desiredDateKeys: [String]
    var desiredRecords: [ManagedAlarmRecord]
    var newlyScheduledRecords: [ManagedAlarmRecord]
    var protectedCurrentDayIDs: [UUID]
    let originalRecords: [ManagedAlarmRecord]
    let createdAt: Date

    init(
        transactionID: UUID,
        phase: BulkAlarmRebuildPhase,
        targetSettingsRevision: UUID,
        targetCredentialOrigin: String,
        desiredDateKeys: [String],
        desiredRecords: [ManagedAlarmRecord],
        newlyScheduledRecords: [ManagedAlarmRecord],
        protectedCurrentDayIDs: [UUID],
        originalRecords: [ManagedAlarmRecord],
        createdAt: Date
    ) {
        self.transactionID = transactionID
        self.phase = phase
        self.targetSettingsRevision = targetSettingsRevision
        self.targetCredentialOrigin = targetCredentialOrigin
        self.desiredDateKeys = desiredDateKeys
        self.desiredRecords = desiredRecords
        self.newlyScheduledRecords = newlyScheduledRecords
        self.protectedCurrentDayIDs = protectedCurrentDayIDs
        self.originalRecords = originalRecords
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case transactionID
        case phase
        case targetSettingsRevision
        case targetCredentialOrigin
        case desiredDateKeys
        case desiredRecords
        case newlyScheduledRecords
        case protectedCurrentDayIDs
        case originalRecords
        case createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        transactionID = try container.decode(UUID.self, forKey: .transactionID)
        phase = try container.decode(BulkAlarmRebuildPhase.self, forKey: .phase)
        targetSettingsRevision = try container.decode(
            UUID.self,
            forKey: .targetSettingsRevision
        )
        targetCredentialOrigin = try container.decode(
            String.self,
            forKey: .targetCredentialOrigin
        )
        desiredDateKeys = try container.decode([String].self, forKey: .desiredDateKeys)
        desiredRecords = try container.decode(
            [ManagedAlarmRecord].self,
            forKey: .desiredRecords
        )
        newlyScheduledRecords = try container.decode(
            [ManagedAlarmRecord].self,
            forKey: .newlyScheduledRecords
        )
        protectedCurrentDayIDs = try container.decode(
            [UUID].self,
            forKey: .protectedCurrentDayIDs
        )
        // Journals written by the first development build did not include this
        // rollback proof. An empty value forces conservative retention.
        originalRecords = try container.decodeIfPresent(
            [ManagedAlarmRecord].self,
            forKey: .originalRecords
        ) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
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
        message: "尚未更新起床闹钟",
        alarmDate: nil,
        updatedAt: .distantPast,
        forecastFetchedAt: nil,
        forecastWasStale: false
    )
}
