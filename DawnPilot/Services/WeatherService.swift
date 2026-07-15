import Foundation

enum WeatherServiceError: LocalizedError {
    case invalidSettings(String)
    case invalidServerResponse
    case server(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidSettings(let message): message
        case .invalidServerResponse: "天气服务器返回了无法识别的数据。"
        case .server(let statusCode, let message): "天气服务器错误 \(statusCode)：\(message)"
        }
    }
}

struct WeatherService: Sendable {
    var session: URLSession = .shared

    func fetchForecast(settings: AppSettings) async throws -> ServerForecast {
        if let validationError = settings.validationError {
            throw WeatherServiceError.invalidSettings(validationError)
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
        request.timeoutInterval = 20
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
            return try decoder.decode(ServerForecast.self, from: data)
        } catch {
            throw WeatherServiceError.invalidServerResponse
        }
    }
}

private struct ServerErrorBody: Decodable {
    let error: String
}
