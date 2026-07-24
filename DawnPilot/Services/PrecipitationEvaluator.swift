import Foundation

enum PrecipitationEvaluationError: LocalizedError, Equatable {
    case forecastFromFuture
    case forecastTooOld
    case invalidForecastTimeline
    case invalidTargetWindow
    case missingTargetHours
    case duplicateTargetHours
    case missingTargetSignals
    case invalidTargetSignals(String)

    var errorDescription: String? {
        switch self {
        case .forecastFromFuture:
            "服务器中的天气数据时间晚于当前时间。"
        case .forecastTooOld:
            "服务器中的天气数据已超过 6 小时。"
        case .invalidForecastTimeline:
            "天气数据的获取与返回时间顺序无效。"
        case .invalidTargetWindow:
            "无法生成目标日期的天气判断窗口。"
        case .missingTargetHours:
            "天气数据未覆盖明日通勤时段。"
        case .duplicateTargetHours:
            "天气数据包含重复的通勤时段小时。"
        case .missingTargetSignals:
            "通勤时段天气数据缺少可用的降水信号。"
        case .invalidTargetSignals(let message):
            "通勤时段天气数据无效：\(message)"
        }
    }
}

enum PrecipitationEvaluator {
    static func evaluate(
        forecast: ServerForecast,
        targetDate: Date,
        settings: AppSettings,
        now: Date = Date()
    ) throws -> WeatherEvaluation {
        let forecastAge = now.timeIntervalSince(forecast.fetchedAt)
        guard forecastAge >= -AppSettings.maximumForecastClockSkew else {
            throw PrecipitationEvaluationError.forecastFromFuture
        }
        guard forecastAge <= AppSettings.maximumForecastAge else {
            throw PrecipitationEvaluationError.forecastTooOld
        }
        guard forecast.fetchedAt <= forecast.servedAt,
              forecast.servedAt <= now.addingTimeInterval(AppSettings.maximumForecastClockSkew) else {
            throw PrecipitationEvaluationError.invalidForecastTimeline
        }

        let calendar = settings.calendar
        let expectedHours = try expectedTargetHours(
            targetDate: targetDate,
            settings: settings,
            calendar: calendar
        )
        let rowsByTime = Dictionary(grouping: forecast.hourly, by: \.time)
        var matchingHours: [ForecastHour] = []
        matchingHours.reserveCapacity(expectedHours.count)

        for expectedHour in expectedHours {
            guard let rows = rowsByTime[expectedHour] else {
                throw PrecipitationEvaluationError.missingTargetHours
            }
            guard rows.count == 1, let hour = rows.first else {
                throw PrecipitationEvaluationError.duplicateTargetHours
            }
            if let validationError = hour.weatherSignalValidationError {
                throw PrecipitationEvaluationError.invalidTargetSignals(validationError)
            }
            guard hour.hasWeatherSignal else {
                throw PrecipitationEvaluationError.missingTargetSignals
            }
            matchingHours.append(hour)
        }

        let maximumProbability = matchingHours.compactMap(\.precipitationProbability).max() ?? 0
        let maximumPrecipitation = matchingHours.map { hour in
            max(
                hour.precipitationMM ?? 0,
                hour.rainMM ?? 0,
                hour.showersMM ?? 0,
                hour.snowfallCM ?? 0
            )
        }.max() ?? 0

        let hasPrecipitationCode = matchingHours.contains { hour in
            guard let code = hour.weatherCode else { return false }
            return precipitationWeatherCodes.contains(code)
        }
        let reachesProbabilityThreshold = maximumProbability >= Double(settings.precipitationProbabilityThreshold)
        let hasMeasurablePrecipitation = maximumPrecipitation >= 0.1
        let isRainy = reachesProbabilityThreshold || hasMeasurablePrecipitation || hasPrecipitationCode

        return WeatherEvaluation(
            kind: isRainy ? .rainy : .clear,
            maximumProbability: maximumProbability,
            maximumPrecipitationMM: maximumPrecipitation,
            matchingHourCount: matchingHours.count
        )
    }

    private static func expectedTargetHours(
        targetDate: Date,
        settings: AppSettings,
        calendar: Calendar
    ) throws -> [Date] {
        let dayStart = calendar.startOfDay(for: targetDate)
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart),
              let windowStart = settings.forecastWindowStart.date(on: dayStart, calendar: calendar),
              let windowEnd = settings.forecastWindowEnd.date(on: dayStart, calendar: calendar),
              windowStart < windowEnd else {
            throw PrecipitationEvaluationError.invalidTargetWindow
        }

        var result: [Date] = []
        var bucketStart = dayStart
        while bucketStart < nextDay {
            guard let bucketEnd = calendar.date(byAdding: .hour, value: 1, to: bucketStart),
                  bucketEnd > bucketStart else {
                throw PrecipitationEvaluationError.invalidTargetWindow
            }
            if bucketStart < windowEnd, bucketEnd > windowStart {
                result.append(bucketStart)
            }
            bucketStart = bucketEnd
        }

        guard !result.isEmpty else {
            throw PrecipitationEvaluationError.invalidTargetWindow
        }
        return result
    }

    // WMO weather codes for drizzle, rain, snow, showers and thunderstorms.
    private static let precipitationWeatherCodes: Set<Int> =
        Set(51...57).union(61...67).union(71...77).union(80...82).union(85...86).union(95...99)
}
