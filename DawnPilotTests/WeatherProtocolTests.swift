import XCTest
@testable import DawnPilot

final class WeatherProtocolTests: XCTestCase {
    func testNormalizedServerPayloadDecodesWithTimezoneOffsets() throws {
        let payload = #"""
        {
          "schema_version": 1,
          "source": "open-meteo",
          "fetched_at": "2026-07-15T12:29:02+00:00",
          "served_at": "2026-07-15T12:29:03+00:00",
          "stale": false,
          "latitude": 31.247803,
          "longitude": 121.5,
          "timezone": "Asia/Shanghai",
          "hourly": [
            {
              "time": "2026-07-16T07:00:00+08:00",
              "precipitation_probability": 60,
              "precipitation_mm": 0.4,
              "rain_mm": 0.4,
              "showers_mm": 0.0,
              "snowfall_cm": 0.0,
              "weather_code": 61
            }
          ]
        }
        """#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let forecast = try decoder.decode(ServerForecast.self, from: Data(payload.utf8))

        XCTAssertEqual(forecast.schemaVersion, 1)
        XCTAssertEqual(forecast.timezone, "Asia/Shanghai")
        XCTAssertEqual(forecast.hourly.count, 1)
        XCTAssertEqual(forecast.hourly[0].precipitationProbability, 60)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let components = calendar.dateComponents([.year, .month, .day, .hour], from: forecast.hourly[0].time)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 7)
        XCTAssertEqual(components.day, 16)
        XCTAssertEqual(components.hour, 7)
    }
}
