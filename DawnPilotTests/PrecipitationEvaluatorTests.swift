import XCTest
@testable import DawnPilot

final class PrecipitationEvaluatorTests: XCTestCase {
    private var settings: AppSettings!
    private var calendar: Calendar!
    private var now: Date!
    private var tomorrow: Date!

    override func setUpWithError() throws {
        settings = AppSettings()
        settings.timeZoneIdentifier = "Asia/Shanghai"
        settings.forecastWindowStart = ClockTime(hour: 7, minute: 0)
        settings.forecastWindowEnd = ClockTime(hour: 9, minute: 0)
        settings.precipitationProbabilityThreshold = 40
        calendar = settings.calendar
        now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 15,
            hour: 22
        )))
        tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: now))
    }

    func testProbabilityAtThresholdChoosesRainyTime() throws {
        let forecast = makeForecast(hours: [
            makeHour(day: tomorrow, hour: 7, probability: 20, precipitation: 0, code: 3),
            makeHour(day: tomorrow, hour: 8, probability: 40, precipitation: 0, code: 3)
        ])

        let result = try PrecipitationEvaluator.evaluate(
            forecast: forecast,
            targetDate: tomorrow,
            settings: settings,
            now: now
        )

        XCTAssertEqual(result.kind, .rainy)
        XCTAssertEqual(result.maximumProbability, 40)
    }

    func testLowProbabilityAndNoPrecipitationChoosesClearTime() throws {
        let forecast = makeForecast(hours: [
            makeHour(day: tomorrow, hour: 7, probability: 10, precipitation: 0, code: 1),
            makeHour(day: tomorrow, hour: 8, probability: 25, precipitation: 0, code: 2)
        ])

        let result = try PrecipitationEvaluator.evaluate(
            forecast: forecast,
            targetDate: tomorrow,
            settings: settings,
            now: now
        )

        XCTAssertEqual(result.kind, .clear)
        XCTAssertEqual(result.matchingHourCount, 2)
    }

    func testMeasurableRainChoosesRainyEvenWithLowProbability() throws {
        let forecast = makeForecast(hours: [
            makeHour(day: tomorrow, hour: 7, probability: 10, precipitation: 0.2, code: 3),
            makeHour(day: tomorrow, hour: 8, probability: 5, precipitation: 0, code: 1)
        ])

        let result = try PrecipitationEvaluator.evaluate(
            forecast: forecast,
            targetDate: tomorrow,
            settings: settings,
            now: now
        )

        XCTAssertEqual(result.kind, .rainy)
    }

    func testHoursOutsideWindowDoNotAffectDecision() throws {
        let forecast = makeForecast(hours: [
            makeHour(day: tomorrow, hour: 6, probability: 95, precipitation: 5, code: 65),
            makeHour(day: tomorrow, hour: 7, probability: 5, precipitation: 0, code: 1),
            makeHour(day: tomorrow, hour: 8, probability: 5, precipitation: 0, code: 1),
            makeHour(day: tomorrow, hour: 9, probability: 95, precipitation: 5, code: 65)
        ])

        let result = try PrecipitationEvaluator.evaluate(
            forecast: forecast,
            targetDate: tomorrow,
            settings: settings,
            now: now
        )

        XCTAssertEqual(result.kind, .clear)
        XCTAssertEqual(result.matchingHourCount, 2)
    }

    func testMissingOneTargetHourIsRejected() {
        let forecast = makeForecast(hours: [
            makeHour(day: tomorrow, hour: 7, probability: 10, precipitation: 0, code: 1)
        ])

        XCTAssertThrowsError(try PrecipitationEvaluator.evaluate(
            forecast: forecast,
            targetDate: tomorrow,
            settings: settings,
            now: now
        )) { error in
            XCTAssertEqual(error as? PrecipitationEvaluationError, .missingTargetHours)
        }
    }

    func testDuplicateTargetHourIsRejected() {
        let duplicate = makeHour(day: tomorrow, hour: 7, probability: 10, precipitation: 0, code: 1)
        let forecast = makeForecast(hours: [
            duplicate,
            duplicate,
            makeHour(day: tomorrow, hour: 8, probability: 10, precipitation: 0, code: 1)
        ])

        XCTAssertThrowsError(try PrecipitationEvaluator.evaluate(
            forecast: forecast,
            targetDate: tomorrow,
            settings: settings,
            now: now
        )) { error in
            XCTAssertEqual(error as? PrecipitationEvaluationError, .duplicateTargetHours)
        }
    }

    func testNonWholeHourWindowRequiresEveryIntersectingHourBucket() throws {
        settings.forecastWindowStart = ClockTime(hour: 7, minute: 30)
        settings.forecastWindowEnd = ClockTime(hour: 8, minute: 30)
        let completeForecast = makeForecast(hours: [
            makeHour(day: tomorrow, hour: 7, probability: 5, precipitation: 0, code: 1),
            makeHour(day: tomorrow, hour: 8, probability: 5, precipitation: 0, code: 1)
        ])

        let result = try PrecipitationEvaluator.evaluate(
            forecast: completeForecast,
            targetDate: tomorrow,
            settings: settings,
            now: now
        )
        XCTAssertEqual(result.matchingHourCount, 2)

        let incompleteForecast = makeForecast(hours: [
            makeHour(day: tomorrow, hour: 8, probability: 5, precipitation: 0, code: 1)
        ])
        XCTAssertThrowsError(try PrecipitationEvaluator.evaluate(
            forecast: incompleteForecast,
            targetDate: tomorrow,
            settings: settings,
            now: now
        )) { error in
            XCTAssertEqual(error as? PrecipitationEvaluationError, .missingTargetHours)
        }
    }

    func testDaylightSavingFallBackRequiresBothRepeatedOneAMHours() throws {
        settings.timeZoneIdentifier = "America/New_York"
        settings.forecastWindowStart = ClockTime(hour: 1, minute: 0)
        settings.forecastWindowEnd = ClockTime(hour: 2, minute: 0)
        calendar = settings.calendar

        let targetDate = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 11,
            day: 1
        )))
        let dayStart = calendar.startOfDay(for: targetDate)
        let firstOneAM = try XCTUnwrap(calendar.date(byAdding: .hour, value: 1, to: dayStart))
        let secondOneAM = try XCTUnwrap(calendar.date(byAdding: .hour, value: 2, to: dayStart))

        XCTAssertEqual(calendar.component(.hour, from: firstOneAM), 1)
        XCTAssertEqual(calendar.component(.hour, from: secondOneAM), 1)
        XCTAssertNotEqual(
            calendar.timeZone.secondsFromGMT(for: firstOneAM),
            calendar.timeZone.secondsFromGMT(for: secondOneAM)
        )

        let forecast = makeForecast(hours: [
            ForecastHour(
                time: firstOneAM,
                precipitationProbability: 5,
                precipitationMM: 0,
                rainMM: 0,
                showersMM: 0,
                snowfallCM: 0,
                weatherCode: 1
            ),
            ForecastHour(
                time: secondOneAM,
                precipitationProbability: 10,
                precipitationMM: 0,
                rainMM: 0,
                showersMM: 0,
                snowfallCM: 0,
                weatherCode: 1
            )
        ])

        let result = try PrecipitationEvaluator.evaluate(
            forecast: forecast,
            targetDate: targetDate,
            settings: settings,
            now: now
        )

        XCTAssertEqual(result.kind, .clear)
        XCTAssertEqual(result.matchingHourCount, 2)
        XCTAssertEqual(result.maximumProbability, 10)
    }

    func testTargetHourWithoutAnyWeatherSignalIsRejected() {
        let forecast = makeForecast(hours: [
            makeHour(day: tomorrow, hour: 7, probability: nil, precipitation: nil, code: nil),
            makeHour(day: tomorrow, hour: 8, probability: 5, precipitation: 0, code: 1)
        ])

        XCTAssertThrowsError(try PrecipitationEvaluator.evaluate(
            forecast: forecast,
            targetDate: tomorrow,
            settings: settings,
            now: now
        )) { error in
            XCTAssertEqual(error as? PrecipitationEvaluationError, .missingTargetSignals)
        }
    }

    func testForecastWithinClockSkewToleranceIsAccepted() {
        let forecast = makeForecast(
            fetchedAt: now.addingTimeInterval(60),
            servedAt: now.addingTimeInterval(60),
            hours: [
                makeHour(day: tomorrow, hour: 7, probability: 5, precipitation: 0, code: 1),
                makeHour(day: tomorrow, hour: 8, probability: 5, precipitation: 0, code: 1)
            ]
        )

        XCTAssertNoThrow(try PrecipitationEvaluator.evaluate(
            forecast: forecast,
            targetDate: tomorrow,
            settings: settings,
            now: now
        ))
    }

    func testForecastBeyondClockSkewToleranceIsRejected() {
        let forecast = makeForecast(
            fetchedAt: now.addingTimeInterval(AppSettings.maximumForecastClockSkew + 1),
            servedAt: now.addingTimeInterval(AppSettings.maximumForecastClockSkew + 1),
            hours: [
                makeHour(day: tomorrow, hour: 7, probability: 5, precipitation: 0, code: 1),
                makeHour(day: tomorrow, hour: 8, probability: 5, precipitation: 0, code: 1)
            ]
        )

        XCTAssertThrowsError(try PrecipitationEvaluator.evaluate(
            forecast: forecast,
            targetDate: tomorrow,
            settings: settings,
            now: now
        )) { error in
            XCTAssertEqual(error as? PrecipitationEvaluationError, .forecastFromFuture)
        }
    }

    func testInvalidFetchedAndServedTimelineIsRejected() {
        let forecast = makeForecast(
            fetchedAt: now.addingTimeInterval(-60),
            servedAt: now.addingTimeInterval(-120),
            hours: [
                makeHour(day: tomorrow, hour: 7, probability: 5, precipitation: 0, code: 1),
                makeHour(day: tomorrow, hour: 8, probability: 5, precipitation: 0, code: 1)
            ]
        )

        XCTAssertThrowsError(try PrecipitationEvaluator.evaluate(
            forecast: forecast,
            targetDate: tomorrow,
            settings: settings,
            now: now
        )) { error in
            XCTAssertEqual(error as? PrecipitationEvaluationError, .invalidForecastTimeline)
        }
    }

    func testOldForecastIsRejected() throws {
        let oldFetchedAt = now.addingTimeInterval(-AppSettings.maximumForecastAge - 1)
        let forecast = makeForecast(
            fetchedAt: oldFetchedAt,
            hours: [makeHour(day: tomorrow, hour: 7, probability: 10, precipitation: 0, code: 1)]
        )

        XCTAssertThrowsError(try PrecipitationEvaluator.evaluate(
            forecast: forecast,
            targetDate: tomorrow,
            settings: settings,
            now: now
        )) { error in
            XCTAssertEqual(error as? PrecipitationEvaluationError, .forecastTooOld)
        }
    }

    private func makeForecast(
        fetchedAt: Date? = nil,
        servedAt: Date? = nil,
        hours: [ForecastHour]
    ) -> ServerForecast {
        ServerForecast(
            schemaVersion: 1,
            source: "test",
            fetchedAt: fetchedAt ?? now,
            servedAt: servedAt ?? now,
            stale: false,
            latitude: settings.latitude,
            longitude: settings.longitude,
            timezone: settings.timeZoneIdentifier,
            hourly: hours
        )
    }

    private func makeHour(
        day: Date,
        hour: Int,
        probability: Double?,
        precipitation: Double?,
        code: Int?
    ) -> ForecastHour {
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = hour
        let date = calendar.date(from: components)!
        return ForecastHour(
            time: date,
            precipitationProbability: probability,
            precipitationMM: precipitation,
            rainMM: precipitation,
            showersMM: precipitation == nil ? nil : 0,
            snowfallCM: precipitation == nil ? nil : 0,
            weatherCode: code
        )
    }
}
