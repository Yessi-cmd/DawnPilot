import Foundation

enum PrecipitationEvaluationError: LocalizedError, Equatable {
    case forecastTooOld
    case missingTargetHours

    var errorDescription: String? {
        switch self {
        case .forecastTooOld:
            "服务器中的天气数据已超过 6 小时。"
        case .missingTargetHours:
            "天气数据未覆盖明日通勤时段。"
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
        guard now.timeIntervalSince(forecast.fetchedAt) <= AppSettings.maximumForecastAge else {
            throw PrecipitationEvaluationError.forecastTooOld
        }

        let calendar = settings.calendar
        let targetComponents = calendar.dateComponents([.year, .month, .day], from: targetDate)
        let matchingHours = forecast.hourly.filter { hour in
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: hour.time)
            guard components.year == targetComponents.year,
                  components.month == targetComponents.month,
                  components.day == targetComponents.day else {
                return false
            }
            let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
            return minute >= settings.forecastWindowStart.minutesFromMidnight
                && minute < settings.forecastWindowEnd.minutesFromMidnight
        }

        guard !matchingHours.isEmpty else {
            throw PrecipitationEvaluationError.missingTargetHours
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

    // WMO weather codes for drizzle, rain, snow, showers and thunderstorms.
    private static let precipitationWeatherCodes: Set<Int> =
        Set(51...57).union(61...67).union(71...77).union(80...82).union(85...86).union(95...99)
}
