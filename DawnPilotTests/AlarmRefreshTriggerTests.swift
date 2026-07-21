import XCTest
@testable import DawnPilot

final class AlarmRefreshTriggerTests: XCTestCase {
    func testScheduledRefreshSkipsDisabledDayWithoutManualAlarm() {
        let origin = AlarmRefreshTrigger.scheduled.originForTomorrow(
            isEnabledAlarmDay: false,
            existingOrigin: nil
        )

        XCTAssertNil(origin)
    }

    func testUserInitiatedRefreshCreatesManualOverrideOnDisabledDay() {
        let origin = AlarmRefreshTrigger.userInitiated.originForTomorrow(
            isEnabledAlarmDay: false,
            existingOrigin: nil
        )

        XCTAssertEqual(origin, .manualOverride)
    }

    func testUserInitiatedRefreshConvertsDisabledAutomaticAlarmToManualOverride() {
        let origin = AlarmRefreshTrigger.userInitiated.originForTomorrow(
            isEnabledAlarmDay: false,
            existingOrigin: .automatic
        )

        XCTAssertEqual(origin, .manualOverride)
    }

    func testScheduledRefreshMaintainsExistingManualOverride() {
        let origin = AlarmRefreshTrigger.scheduled.originForTomorrow(
            isEnabledAlarmDay: false,
            existingOrigin: .manualOverride
        )

        XCTAssertEqual(origin, .manualOverride)
    }

    func testEnabledDayUsesAutomaticOrigin() {
        let origin = AlarmRefreshTrigger.userInitiated.originForTomorrow(
            isEnabledAlarmDay: true,
            existingOrigin: .manualOverride
        )

        XCTAssertEqual(origin, .automatic)
    }
}
