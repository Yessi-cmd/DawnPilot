import XCTest
@testable import DawnPilot

final class AppSettingsMigrationTests: XCTestCase {
    func testSettingsWithoutLocationNameStillDecode() throws {
        var settings = AppSettings()
        settings.locationName = "上海市"

        let encoded = try JSONEncoder().encode(settings)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertNotNil(object.removeValue(forKey: "locationName"))

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacyData)

        XCTAssertNil(decoded.locationName)
        XCTAssertEqual(decoded.latitude, settings.latitude)
        XCTAssertEqual(decoded.longitude, settings.longitude)
        XCTAssertEqual(decoded.timeZoneIdentifier, settings.timeZoneIdentifier)
    }

    func testManagedAlarmWithoutOriginDecodesAsAutomatic() throws {
        let record = ManagedAlarmRecord(
            dateKey: "2026-07-20",
            alarmID: UUID(uuidString: "69D98B24-6F04-4381-B44C-E9565FB78312")!,
            fireDate: Date(timeIntervalSinceReferenceDate: 806_284_800),
            kind: .fallback,
            updatedAt: Date(timeIntervalSinceReferenceDate: 806_198_400)
        )
        let encoded = try JSONEncoder().encode(record)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertNotNil(object.removeValue(forKey: "origin"))

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(ManagedAlarmRecord.self, from: legacyData)

        XCTAssertEqual(decoded.origin, .automatic)
        XCTAssertEqual(decoded.dateKey, record.dateKey)
        XCTAssertEqual(decoded.alarmID, record.alarmID)
    }
}
