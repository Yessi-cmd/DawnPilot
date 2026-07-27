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
        let significantProbabilities = matchingHours
            .compactMap(\.significantPrecipitationProbability)
        // Only trust the significant probability when every matching hour carries
        // one; a partial timeline would understate the window.
        let maximumSignificantProbability = significantProbabilities.count == matchingHours.count
            ? significantProbabilities.max()
            : nil
        let maximumPrecipitation = matchingHours.map { hour in
            max(
                hour.precipitationMM ?? 0,
                hour.rainMM ?? 0,
                hour.showersMM ?? 0,
                hour.snowfallCM ?? 0
            )
        }.max() ?? 0

        let hasSignificantCode = matchingHours.contains { hour in
            guard let code = hour.weatherCode else { return false }
            return significantPrecipitationWeatherCodes.contains(code)
        }
        let hasMeasurableCode = matchingHours.contains { hour in
            guard let code = hour.weatherCode else { return false }
            return measurablePrecipitationWeatherCodes.contains(code)
        }
        let threshold = Double(settings.precipitationProbabilityThreshold)

        // The same threshold is applied to two definitions of rain. Reaching it on
        // commute-changing rain earns the early alarm; reaching it only on
        // measurable drizzle earns the hedge between the two times. Waking up late
        // in real rain costs far more than losing the difference in sleep, so
        // anything short of a confidently dry window keeps some of the margin.
        let isSignificant: Bool
        if let maximumSignificantProbability {
            isSignificant = maximumSignificantProbability >= threshold
                || maximumPrecipitation >= significantPrecipitationMM
                || hasSignificantCode
        } else {
            // Without member-derived probabilities, fall back to the older, more
            // cautious rule so a degraded server never delays the alarm.
            isSignificant = maximumProbability >= threshold
                || maximumPrecipitation >= measurablePrecipitationMM
                || hasSignificantCode
                || hasMeasurableCode
        }
        let isMeasurable = maximumProbability >= threshold
            || maximumPrecipitation >= measurablePrecipitationMM
            || hasMeasurableCode
            || hasSignificantCode

        let kind: ManagedAlarmKind
        if isSignificant {
            kind = .rainy
        } else if isMeasurable {
            kind = .fallback
        } else {
            kind = .clear
        }

        return WeatherEvaluation(
            kind: kind,
            maximumProbability: maximumProbability,
            maximumSignificantProbability: maximumSignificantProbability,
            maximumPrecipitationMM: maximumPrecipitation,
            matchingHourCount: matchingHours.count
        )
    }

    static let measurablePrecipitationMM = 0.1
    /// Rain heavy enough to change a commute, matching the server's definition.
    static let significantPrecipitationMM = 0.5

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

    // WMO codes for drizzle, slight rain or snow, and slight showers. Enough to
    // wet the ground, not enough on their own to justify the early alarm.
    private static let measurablePrecipitationWeatherCodes: Set<Int> =
        Set([51, 53, 55, 56, 57, 61, 71, 77, 80])

    // WMO codes for moderate or heavy rain and snow, freezing rain, heavier
    // showers and thunderstorms.
    private static let significantPrecipitationWeatherCodes: Set<Int> =
        Set([63, 65, 66, 67, 73, 75, 81, 82, 85, 86]).union(95...99)
}
