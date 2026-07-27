import XCTest
@testable import DawnPilot

final class RefreshTargetResolverTests: XCTestCase {
    private var settings: AppSettings!
    private var calendar: Calendar!

    override func setUpWithError() throws {
        settings = AppSettings()
        settings.timeZoneIdentifier = "Asia/Shanghai"
        settings.rainyAlarmTime = ClockTime(hour: 7, minute: 50)
        settings.fallbackAlarmTime = ClockTime(hour: 8, minute: 0)
        settings.clearAlarmTime = ClockTime(hour: 8, minute: 5)
        // Monday through Friday, the shipped default.
        settings.enabledWeekdays = [2, 3, 4, 5, 6]
        calendar = settings.calendar
    }

    override func tearDownWithError() throws {
        settings = nil
        calendar = nil
    }

    func testNightlyRunTargetsTomorrow() throws {
        // Monday 22:30, the nightly automation.
        let now = try date(year: 2026, month: 7, day: 27, hour: 22, minute: 30)
        let target = try XCTUnwrap(resolve(now: now))

        XCTAssertFalse(target.isSameDayCorrection)
        XCTAssertEqual(dayComponents(target.day), DateComponents(year: 2026, month: 7, day: 28))
    }

    func testEarlyMorningRunCorrectsToday() throws {
        // Monday 06:00, well before the 07:50 rainy alarm.
        let now = try date(year: 2026, month: 7, day: 27, hour: 6, minute: 0)
        let target = try XCTUnwrap(resolve(now: now))

        XCTAssertTrue(target.isSameDayCorrection)
        XCTAssertEqual(dayComponents(target.day), DateComponents(year: 2026, month: 7, day: 27))
    }

    func testCorrectionIsAllowedExactlyAtTheMinimumLead() throws {
        let now = try date(year: 2026, month: 7, day: 27, hour: 7, minute: 35)
        let target = try XCTUnwrap(resolve(now: now))

        XCTAssertTrue(target.isSameDayCorrection)
    }

    func testCorrectionStopsOneMinuteInsideTheMinimumLead() throws {
        let now = try date(year: 2026, month: 7, day: 27, hour: 7, minute: 36)
        let target = try XCTUnwrap(resolve(now: now))

        XCTAssertFalse(target.isSameDayCorrection)
        XCTAssertEqual(dayComponents(target.day), DateComponents(year: 2026, month: 7, day: 28))
    }

    func testCorrectionIsSkippedAfterTodayAlarmsHaveRung() throws {
        let now = try date(year: 2026, month: 7, day: 27, hour: 9, minute: 0)
        let target = try XCTUnwrap(resolve(now: now))

        XCTAssertFalse(target.isSameDayCorrection)
        XCTAssertEqual(dayComponents(target.day), DateComponents(year: 2026, month: 7, day: 28))
    }

    func testDisabledWeekdayTodayFallsBackToTomorrow() throws {
        // Sunday 06:00: today has no alarm to correct.
        let now = try date(year: 2026, month: 7, day: 26, hour: 6, minute: 0)
        let target = try XCTUnwrap(resolve(now: now))

        XCTAssertFalse(target.isSameDayCorrection)
        XCTAssertEqual(dayComponents(target.day), DateComponents(year: 2026, month: 7, day: 27))
    }

    func testAlarmScheduledEarlierThanEveryOutcomeBlocksTheCorrection() throws {
        // A manually earlier alarm today must not be rescheduled minutes before it rings.
        let scheduled = try date(year: 2026, month: 7, day: 27, hour: 6, minute: 30)
        let now = try date(year: 2026, month: 7, day: 27, hour: 6, minute: 20)
        let target = try XCTUnwrap(
            RefreshTargetResolver.resolve(
                settings: settings,
                scheduledTodayFireDate: scheduled,
                now: now
            )
        )

        XCTAssertFalse(target.isSameDayCorrection)
    }

    func testAlarmScheduledEarlierStillAllowsCorrectionWithEnoughLead() throws {
        let scheduled = try date(year: 2026, month: 7, day: 27, hour: 6, minute: 30)
        let now = try date(year: 2026, month: 7, day: 27, hour: 5, minute: 0)
        let target = try XCTUnwrap(
            RefreshTargetResolver.resolve(
                settings: settings,
                scheduledTodayFireDate: scheduled,
                now: now
            )
        )

        XCTAssertTrue(target.isSameDayCorrection)
    }

    func testTomorrowsAlarmDoesNotCountAsTodaysEarliestTime() throws {
        // A record whose fire date is not on the target day must be ignored.
        let tomorrowAlarm = try date(year: 2026, month: 7, day: 28, hour: 3, minute: 0)
        let today = try date(year: 2026, month: 7, day: 27, hour: 0, minute: 0)
        let earliest = try XCTUnwrap(
            RefreshTargetResolver.earliestTouchableAlarmDate(
                settings: settings,
                scheduledFireDate: tomorrowAlarm,
                on: today
            )
        )

        XCTAssertEqual(earliest, try date(year: 2026, month: 7, day: 27, hour: 7, minute: 50))
    }

    func testDaylightSavingGapUsesTheShiftedAlarmTime() throws {
        settings.timeZoneIdentifier = "America/Los_Angeles"
        settings.enabledWeekdays = Set(1...7)
        settings.rainyAlarmTime = ClockTime(hour: 2, minute: 30)
        settings.fallbackAlarmTime = ClockTime(hour: 8, minute: 0)
        settings.clearAlarmTime = ClockTime(hour: 8, minute: 5)
        calendar = settings.calendar

        // 2026-03-08 skips 02:00–03:00 in Los Angeles.
        let now = try date(year: 2026, month: 3, day: 8, hour: 1, minute: 0)
        let today = calendar.startOfDay(for: now)
        let earliest = try XCTUnwrap(
            RefreshTargetResolver.earliestTouchableAlarmDate(
                settings: settings,
                scheduledFireDate: nil,
                on: today
            )
        )
        let target = try XCTUnwrap(resolve(now: now))

        XCTAssertEqual(
            calendar.dateComponents([.hour, .minute], from: earliest),
            DateComponents(hour: 3, minute: 0)
        )
        XCTAssertTrue(target.isSameDayCorrection)
    }

    func testBackgroundRefreshAimsAtTheMorningCorrectionWindow() throws {
        // Monday 05:00: the 07:50 alarm minus the 75 minute lookahead is 06:35.
        let now = try date(year: 2026, month: 7, day: 27, hour: 5, minute: 0)
        let begin = BackgroundRefreshController.preferredBeginDate(
            settings: settings,
            now: now
        )

        XCTAssertEqual(begin, try date(year: 2026, month: 7, day: 27, hour: 6, minute: 35))
    }

    func testBackgroundRefreshFallsBackToThePeriodicIntervalAfterTheWindow() throws {
        let now = try date(year: 2026, month: 7, day: 27, hour: 9, minute: 0)
        let begin = BackgroundRefreshController.preferredBeginDate(
            settings: settings,
            now: now
        )

        XCTAssertEqual(
            begin,
            now.addingTimeInterval(BackgroundRefreshController.periodicInterval)
        )
    }

    func testBackgroundRefreshIgnoresDisabledWeekends() throws {
        // Saturday 05:00: neither today nor tomorrow is an enabled alarm day.
        let now = try date(year: 2026, month: 7, day: 25, hour: 5, minute: 0)
        let begin = BackgroundRefreshController.preferredBeginDate(
            settings: settings,
            now: now
        )

        XCTAssertEqual(
            begin,
            now.addingTimeInterval(BackgroundRefreshController.periodicInterval)
        )
    }

    private func resolve(now: Date) -> RefreshTarget? {
        RefreshTargetResolver.resolve(
            settings: settings,
            scheduledTodayFireDate: nil,
            now: now
        )
    }

    private func date(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int
    ) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        )))
    }

    private func dayComponents(_ date: Date) -> DateComponents {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return DateComponents(
            year: components.year,
            month: components.month,
            day: components.day
        )
    }
}
