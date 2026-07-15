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
}
