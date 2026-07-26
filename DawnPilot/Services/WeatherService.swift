import Foundation

enum WeatherServiceError: LocalizedError {
    case invalidSettings(String)
    case invalidServerResponse
    case unsupportedSchemaVersion(Int)
    case responseTimezoneMismatch(expected: String, actual: String)
    case invalidForecast(String)
    case server(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidSettings(let message): message
        case .invalidServerResponse: "天气服务器返回了无法识别的数据。"
        case .unsupportedSchemaVersion(let version):
            "天气服务器返回了不支持的协议版本 \(version)。"
        case .responseTimezoneMismatch(let expected, let actual):
            "天气服务器返回的时区 \(actual) 与请求时区 \(expected) 不一致。"
        case .invalidForecast(let message):
            "天气服务器返回的数据无效：\(message)"
        case .server(let statusCode, _):
            switch statusCode {
            case 401, 403:
                "天气服务器拒绝访问，请检查访问令牌。"
            case 404:
                "未找到天气接口，请检查服务器地址。"
            case 429:
                "天气服务器请求过于频繁，请稍后重试。"
            case 500...599:
                "天气服务器暂时不可用，请稍后重试。"
            default:
                "天气服务器返回错误 \(statusCode)。"
            }
        }
    }
}

struct WeatherService: Sendable {
    static let maximumCoordinateDriftDegrees = 0.1

    var session: URLSession = .shared

    func fetchForecast(settings: AppSettings) async throws -> ServerForecast {
        if let validationError = settings.validationError {
            throw WeatherServiceError.invalidSettings(validationError)
        }
        if let weatherConfigurationError = settings.weatherConfigurationError {
            throw WeatherServiceError.invalidSettings(weatherConfigurationError)
        }

        guard let baseURL = URL(string: settings.serverBaseURL),
              var components = URLComponents(
                url: baseURL.appendingPathComponent("v1/forecast"),
                resolvingAgainstBaseURL: false
              ) else {
            throw WeatherServiceError.invalidSettings("服务器地址无效。")
        }
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(settings.latitude)),
            URLQueryItem(name: "longitude", value: String(settings.longitude)),
            URLQueryItem(name: "timezone", value: settings.timeZoneIdentifier)
        ]
        guard let url = components.url else {
            throw WeatherServiceError.invalidSettings("无法生成天气请求地址。")
        }

        var request = URLRequest(url: url)
        // Nightly background refresh tolerates latency; leave headroom above the
        // server's single-flight wait so a slow upstream can still answer.
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !settings.bearerToken.isEmpty {
            request.setValue("Bearer \(settings.bearerToken)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WeatherServiceError.invalidServerResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let message = (try? JSONDecoder().decode(ServerErrorBody.self, from: data).error)
                ?? String(data: data, encoding: .utf8)
                ?? "未知错误"
            throw WeatherServiceError.server(statusCode: httpResponse.statusCode, message: message)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            // Returns the decoded payload as-is; the caller validates it with an
            // injectable clock via `WeatherService.validate`.
            return try decoder.decode(ServerForecast.self, from: data)
        } catch {
            throw WeatherServiceError.invalidServerResponse
        }
    }

    static func validate(
        _ forecast: ServerForecast,
        settings: AppSettings,
        now: Date
    ) throws {
        guard forecast.schemaVersion == 1 else {
            throw WeatherServiceError.unsupportedSchemaVersion(forecast.schemaVersion)
        }
        guard forecast.timezone == settings.timeZoneIdentifier else {
            throw WeatherServiceError.responseTimezoneMismatch(
                expected: settings.timeZoneIdentifier,
                actual: forecast.timezone
            )
        }
        guard !forecast.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WeatherServiceError.invalidForecast("天气来源不能为空。")
        }
        guard forecast.latitude.isFinite,
              forecast.longitude.isFinite,
              (-90...90).contains(forecast.latitude),
              (-180...180).contains(forecast.longitude) else {
            throw WeatherServiceError.invalidForecast("经纬度无效。")
        }
        let rawLongitudeDifference = abs(forecast.longitude - settings.longitude)
        let longitudeDifference = min(
            rawLongitudeDifference,
            360 - rawLongitudeDifference
        )
        guard abs(forecast.latitude - settings.latitude) <= maximumCoordinateDriftDegrees,
              longitudeDifference <= maximumCoordinateDriftDegrees else {
            throw WeatherServiceError.invalidForecast("返回地点与请求地点不一致。")
        }
        let latestAcceptedTime = now.addingTimeInterval(AppSettings.maximumForecastClockSkew)
        guard forecast.fetchedAt <= latestAcceptedTime else {
            throw WeatherServiceError.invalidForecast("获取时间晚于当前时间。")
        }
        guard forecast.fetchedAt <= forecast.servedAt,
              forecast.servedAt <= latestAcceptedTime else {
            throw WeatherServiceError.invalidForecast("获取与返回时间顺序无效。")
        }
        guard !forecast.hourly.isEmpty else {
            throw WeatherServiceError.invalidForecast("小时预报不能为空。")
        }

        let calendar = settings.calendar
        var previousTime: Date?
        for hour in forecast.hourly {
            if let previousTime, hour.time <= previousTime {
                throw WeatherServiceError.invalidForecast("小时预报必须严格递增且不能重复。")
            }
            let components = calendar.dateComponents([.minute, .second, .nanosecond], from: hour.time)
            guard components.minute == 0,
                  components.second == 0,
                  components.nanosecond == 0 else {
                throw WeatherServiceError.invalidForecast("小时预报时间必须落在整点。")
            }
            if let validationError = hour.weatherSignalValidationError {
                throw WeatherServiceError.invalidForecast(validationError)
            }
            previousTime = hour.time
        }
    }
}

private struct ServerErrorBody: Decodable {
    let error: String
}
