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

    func testValidatedForecastAcceptsSchemaOneAndRequestedTimezone() throws {
        let fixture = try makeFixture()
        XCTAssertNoThrow(try WeatherService.validate(
            fixture.forecast,
            settings: fixture.settings,
            now: fixture.now
        ))
    }

    func testUnknownSchemaVersionIsRejected() throws {
        let fixture = try makeFixture(schemaVersion: 2)

        XCTAssertThrowsError(try WeatherService.validate(
            fixture.forecast,
            settings: fixture.settings,
            now: fixture.now
        )) { error in
            guard case WeatherServiceError.unsupportedSchemaVersion(2) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testMismatchedTimezoneIsRejected() throws {
        let fixture = try makeFixture(timezone: "UTC")

        XCTAssertThrowsError(try WeatherService.validate(
            fixture.forecast,
            settings: fixture.settings,
            now: fixture.now
        )) { error in
            guard case WeatherServiceError.responseTimezoneMismatch(
                expected: "Asia/Shanghai",
                actual: "UTC"
            ) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testDuplicateOrUnorderedHoursAreRejected() throws {
        let fixture = try makeFixture()
        let duplicateForecast = ServerForecast(
            schemaVersion: fixture.forecast.schemaVersion,
            source: fixture.forecast.source,
            fetchedAt: fixture.forecast.fetchedAt,
            servedAt: fixture.forecast.servedAt,
            stale: fixture.forecast.stale,
            latitude: fixture.forecast.latitude,
            longitude: fixture.forecast.longitude,
            timezone: fixture.forecast.timezone,
            hourly: [fixture.forecast.hourly[0], fixture.forecast.hourly[0]]
        )

        XCTAssertThrowsError(try WeatherService.validate(
            duplicateForecast,
            settings: fixture.settings,
            now: fixture.now
        ))
    }

    func testSmallFutureClockSkewIsAccepted() throws {
        let fixture = try makeFixture(fetchedAtOffset: 60, servedAtOffset: 60)

        XCTAssertNoThrow(try WeatherService.validate(
            fixture.forecast,
            settings: fixture.settings,
            now: fixture.now
        ))
    }

    func testFutureFetchBeyondClockSkewIsRejected() throws {
        let offset = AppSettings.maximumForecastClockSkew + 1
        let fixture = try makeFixture(fetchedAtOffset: offset, servedAtOffset: offset)

        XCTAssertThrowsError(try WeatherService.validate(
            fixture.forecast,
            settings: fixture.settings,
            now: fixture.now
        ))
    }

    func testNonWholeHourTimestampIsRejected() throws {
        let fixture = try makeFixture(hourMinute: 30)

        XCTAssertThrowsError(try WeatherService.validate(
            fixture.forecast,
            settings: fixture.settings,
            now: fixture.now
        ))
    }

    func testSmallUpstreamGridCoordinateDriftIsAccepted() throws {
        let fixture = try makeFixture(
            latitude: AppSettings().latitude + 0.02,
            longitude: AppSettings().longitude - 0.02
        )

        XCTAssertNoThrow(try WeatherService.validate(
            fixture.forecast,
            settings: fixture.settings,
            now: fixture.now
        ))
    }

    func testMismatchedForecastLocationIsRejected() throws {
        let fixture = try makeFixture(
            latitude: AppSettings().latitude + 1,
            longitude: AppSettings().longitude + 1
        )

        XCTAssertThrowsError(try WeatherService.validate(
            fixture.forecast,
            settings: fixture.settings,
            now: fixture.now
        ))
    }

    func testLongitudeComparisonWrapsAcrossInternationalDateLine() throws {
        let fixture = try makeFixture(
            longitude: -179.99,
            settingsLongitude: 179.99
        )

        XCTAssertNoThrow(try WeatherService.validate(
            fixture.forecast,
            settings: fixture.settings,
            now: fixture.now
        ))
    }

    private func makeFixture(
        schemaVersion: Int = 1,
        timezone: String = "Asia/Shanghai",
        fetchedAtOffset: TimeInterval = -60,
        servedAtOffset: TimeInterval = 0,
        hourMinute: Int = 0,
        latitude: Double? = nil,
        longitude: Double? = nil,
        settingsLongitude: Double? = nil
    ) throws -> (forecast: ServerForecast, settings: AppSettings, now: Date) {
        var settings = AppSettings()
        settings.timeZoneIdentifier = "Asia/Shanghai"
        if let settingsLongitude {
            settings.longitude = settingsLongitude
        }
        let calendar = settings.calendar
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 15,
            hour: 20
        )))
        let hour = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 16,
            hour: 7,
            minute: hourMinute
        )))
        let forecast = ServerForecast(
            schemaVersion: schemaVersion,
            source: "test",
            fetchedAt: now.addingTimeInterval(fetchedAtOffset),
            servedAt: now.addingTimeInterval(servedAtOffset),
            stale: false,
            latitude: latitude ?? settings.latitude,
            longitude: longitude ?? settings.longitude,
            timezone: timezone,
            hourly: [
                ForecastHour(
                    time: hour,
                    precipitationProbability: 20,
                    precipitationMM: 0,
                    rainMM: 0,
                    showersMM: 0,
                    snowfallCM: 0,
                    weatherCode: 1
                )
            ]
        )
        return (forecast, settings, now)
    }
}

final class SettingsStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var credentialStore: MemoryCredentialStore!

    override func setUpWithError() throws {
        suiteName = "SettingsStoreTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        credentialStore = MemoryCredentialStore()
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        credentialStore = nil
    }

    func testNewSettingsPayloadDoesNotContainBearerToken() throws {
        var settings = AppSettings()
        settings.bearerToken = "test-secret-value"

        try SettingsStore.saveSettingsThrowing(
            settings,
            defaults: defaults,
            credentialStore: credentialStore
        )

        let data = try XCTUnwrap(defaults.data(forKey: "dawnPilot.settings.v2"))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("test-secret-value"))
        XCTAssertFalse(json.contains("bearerToken"))
        XCTAssertEqual(try credentialStore.resolvedBearerToken(), "test-secret-value")
    }

    func testLegacyTokenMigratesToCredentialStoreBeforePayloadIsRemoved() throws {
        let legacyJSON = #"""
        {
          "serverBaseURL": "https://example.com/dawnpilot",
          "bearerToken": "legacy-test-secret"
        }
        """#
        defaults.set(Data(legacyJSON.utf8), forKey: "dawnPilot.settings.v1")

        let settings = SettingsStore.loadSettings(
            defaults: defaults,
            credentialStore: credentialStore
        )

        XCTAssertEqual(settings.bearerToken, "legacy-test-secret")
        XCTAssertEqual(try credentialStore.resolvedBearerToken(), "legacy-test-secret")
        XCTAssertNil(defaults.data(forKey: "dawnPilot.settings.v1"))
        let migratedData = try XCTUnwrap(defaults.data(forKey: "dawnPilot.settings.v2"))
        let migratedJSON = try XCTUnwrap(String(data: migratedData, encoding: .utf8))
        XCTAssertFalse(migratedJSON.contains("legacy-test-secret"))
        XCTAssertFalse(migratedJSON.contains("bearerToken"))
    }

    func testCredentialMigrationFailurePreservesLegacyPayloadAndReturnsRecoveryMarker() throws {
        let legacyJSON = #"""
        {
          "serverBaseURL": "https://example.com/dawnpilot",
          "bearerToken": "legacy-test-secret"
        }
        """#
        let legacyData = Data(legacyJSON.utf8)
        defaults.set(legacyData, forKey: "dawnPilot.settings.v1")
        credentialStore.saveError = MemoryCredentialError.writeFailed

        let settings = SettingsStore.loadSettings(
            defaults: defaults,
            credentialStore: credentialStore
        )

        XCTAssertNotNil(settings.storageRecoveryMessage)
        XCTAssertEqual(defaults.data(forKey: "dawnPilot.settings.v1"), legacyData)
        XCTAssertNil(defaults.data(forKey: "dawnPilot.settings.v2"))
    }

    func testCoexistingV2WithEmptyKeychainDoesNotResurrectLegacyToken() throws {
        var canonicalSettings = AppSettings()
        canonicalSettings.serverBaseURL = "https://canonical.example/dawnpilot"
        try SettingsStore.saveSettingsThrowing(
            canonicalSettings,
            defaults: defaults,
            credentialStore: credentialStore
        )
        let legacyJSON = #"""
        {
          "serverBaseURL": "https://stale.example/dawnpilot",
          "bearerToken": "interrupted-migration-token"
        }
        """#
        defaults.set(Data(legacyJSON.utf8), forKey: "dawnPilot.settings.v1")

        let loaded = SettingsStore.loadSettings(
            defaults: defaults,
            credentialStore: credentialStore
        )

        XCTAssertEqual(loaded.serverBaseURL, canonicalSettings.serverBaseURL)
        XCTAssertTrue(loaded.bearerToken.isEmpty)
        XCTAssertNil(try credentialStore.resolvedBearerToken())
        XCTAssertNil(defaults.data(forKey: "dawnPilot.settings.v1"))
    }

    func testCoexistingLegacyPayloadIsPreservedWhenKeychainReadFails() throws {
        let canonicalSettings = AppSettings()
        try SettingsStore.saveSettingsThrowing(
            canonicalSettings,
            defaults: defaults,
            credentialStore: credentialStore
        )
        let legacyData = Data(#"""
        {
          "bearerToken": "legacy-token-that-must-not-be-lost"
        }
        """#.utf8)
        defaults.set(legacyData, forKey: "dawnPilot.settings.v1")
        credentialStore.loadError = MemoryCredentialError.readFailed

        let loaded = SettingsStore.loadSettings(
            defaults: defaults,
            credentialStore: credentialStore
        )

        XCTAssertNotNil(loaded.storageRecoveryMessage)
        XCTAssertEqual(defaults.data(forKey: "dawnPilot.settings.v1"), legacyData)
    }

    func testCoexistingLegacyTokenDoesNotOverrideCanonicalKeychainToken() throws {
        var canonicalSettings = AppSettings()
        canonicalSettings.serverBaseURL = "https://canonical.example/dawnpilot"
        canonicalSettings.bearerToken = "canonical-keychain-token"
        try SettingsStore.saveSettingsThrowing(
            canonicalSettings,
            defaults: defaults,
            credentialStore: credentialStore
        )
        let legacyJSON = #"""
        {
          "serverBaseURL": "https://stale.example/dawnpilot",
          "bearerToken": "stale-legacy-token"
        }
        """#
        defaults.set(Data(legacyJSON.utf8), forKey: "dawnPilot.settings.v1")

        let loaded = SettingsStore.loadSettings(
            defaults: defaults,
            credentialStore: credentialStore
        )

        XCTAssertEqual(loaded.serverBaseURL, canonicalSettings.serverBaseURL)
        XCTAssertEqual(loaded.bearerToken, "canonical-keychain-token")
        XCTAssertEqual(try credentialStore.resolvedBearerToken(), "canonical-keychain-token")
        XCTAssertNil(defaults.data(forKey: "dawnPilot.settings.v1"))
    }

    func testExampleLocationConsentPersistsInVersionedSettings() throws {
        var settings = AppSettings()
        settings.exampleLocationConfirmed = true

        try SettingsStore.saveSettingsThrowing(
            settings,
            defaults: defaults,
            credentialStore: credentialStore
        )
        let loaded = SettingsStore.loadSettings(
            defaults: defaults,
            credentialStore: credentialStore
        )

        XCTAssertTrue(loaded.exampleLocationConfirmed)
    }

    func testCorruptRecordsAreObservableInsteadOfSuccessfulEmptyRecords() {
        defaults.set(Data("not-json".utf8), forKey: "dawnPilot.records.v2")

        switch SettingsStore.loadRecordsResult(defaults: defaults) {
        case .success:
            XCTFail("Corrupt managed records must not be treated as an empty first launch.")
        case .failure(let error):
            XCTAssertEqual(error, .corrupted(area: "闹钟记录"))
        }
    }

    func testJSONShapedLegacyTokenCannotMasqueradeAsCredentialEnvelope() throws {
        let token = #"{"format":"dawnpilot-credential-envelope-v1","current":null,"pending":null}"#

        XCTAssertEqual(
            try StoredCredential.decode(data: Data(token.utf8)),
            .legacyToken(token)
        )

        let envelope = CredentialEnvelope(
            current: CredentialBinding(
                settingsRevision: UUID(),
                serverOrigin: "https://example.com/dawnpilot",
                bearerToken: "bound-token"
            ),
            pending: nil
        )
        XCTAssertEqual(
            try StoredCredential.decode(
                data: StoredCredential.envelope(envelope).encoded()
            ),
            .envelope(envelope)
        )
    }

    func testInterruptedCandidateBeforeDefaultsCommitKeepsOldTokenAndScope() throws {
        var oldDraft = AppSettings()
        oldDraft.serverBaseURL = "https://example.com/old-scope"
        oldDraft.bearerToken = "old-token"
        let oldSettings = try SettingsStore.saveSettingsThrowing(
            oldDraft,
            defaults: defaults,
            credentialStore: credentialStore
        )
        var candidate = oldSettings
        candidate.settingsRevision = UUID()
        candidate.serverBaseURL = "https://example.com/new-scope"
        candidate.bearerToken = "new-token"
        credentialStore.credential = .envelope(CredentialEnvelope(
            current: CredentialBinding(
                settingsRevision: oldSettings.settingsRevision,
                serverOrigin: try XCTUnwrap(oldSettings.credentialOrigin),
                bearerToken: oldSettings.bearerToken
            ),
            pending: CredentialBinding(
                settingsRevision: candidate.settingsRevision,
                serverOrigin: try XCTUnwrap(candidate.credentialOrigin),
                bearerToken: candidate.bearerToken
            )
        ))

        let loaded = SettingsStore.loadSettings(
            defaults: defaults,
            credentialStore: credentialStore
        )

        XCTAssertEqual(loaded.settingsRevision, oldSettings.settingsRevision)
        XCTAssertEqual(loaded.serverBaseURL, oldSettings.serverBaseURL)
        XCTAssertEqual(loaded.bearerToken, "old-token")
    }

    func testPendingCredentialWinsAfterDefaultsCommitWhenPromotionFailed() throws {
        var oldDraft = AppSettings()
        oldDraft.bearerToken = "old-token"
        _ = try SettingsStore.saveSettingsThrowing(
            oldDraft,
            defaults: defaults,
            credentialStore: credentialStore
        )
        var candidate = oldDraft
        candidate.serverBaseURL = "https://example.com/next-scope"
        candidate.bearerToken = "new-token"
        credentialStore.saveError = MemoryCredentialError.writeFailed
        credentialStore.failSaveCallNumbers = [credentialStore.saveCallCount + 2]

        let committed = try SettingsStore.saveSettingsThrowing(
            candidate,
            defaults: defaults,
            credentialStore: credentialStore
        )
        guard case .envelope(let interruptedEnvelope) = credentialStore.credential else {
            return XCTFail("Expected the staged credential envelope to remain.")
        }
        XCTAssertEqual(
            interruptedEnvelope.pending?.settingsRevision,
            committed.settingsRevision
        )

        let loaded = SettingsStore.loadSettings(
            defaults: defaults,
            credentialStore: credentialStore
        )

        XCTAssertEqual(loaded.settingsRevision, committed.settingsRevision)
        XCTAssertEqual(loaded.serverBaseURL, candidate.serverBaseURL)
        XCTAssertEqual(loaded.bearerToken, "new-token")
    }

    func testCredentialRevisionMismatchRequiresRecoveryInsteadOfUsingToken() throws {
        var draft = AppSettings()
        draft.bearerToken = "correct-token"
        let committed = try SettingsStore.saveSettingsThrowing(
            draft,
            defaults: defaults,
            credentialStore: credentialStore
        )
        credentialStore.credential = .envelope(CredentialEnvelope(
            current: CredentialBinding(
                settingsRevision: UUID(),
                serverOrigin: try XCTUnwrap(committed.credentialOrigin),
                bearerToken: "wrong-revision-token"
            ),
            pending: nil
        ))

        let loaded = SettingsStore.loadSettings(
            defaults: defaults,
            credentialStore: credentialStore
        )

        XCTAssertNotNil(loaded.storageRecoveryMessage)
        XCTAssertTrue(loaded.bearerToken.isEmpty)
    }

    func testLegacyV2WithoutRevisionUsesStableMigrationRevision() throws {
        defaults.set(Data(#"""
        {
          "version": 2,
          "value": {
            "serverBaseURL": "https://example.com/dawnpilot"
          }
        }
        """#.utf8), forKey: "dawnPilot.settings.v2")
        credentialStore.credential = .legacyToken("legacy-json-token")

        let first = SettingsStore.loadSettings(
            defaults: defaults,
            credentialStore: credentialStore
        )
        let second = SettingsStore.loadSettings(
            defaults: defaults,
            credentialStore: credentialStore
        )

        XCTAssertEqual(first.settingsRevision, AppSettings.legacySettingsRevision)
        XCTAssertEqual(second.settingsRevision, first.settingsRevision)
        XCTAssertEqual(second.bearerToken, "legacy-json-token")
    }

    func testSaveRotatesRevisionExactlyOnceAndReturnsCommittedRevision() throws {
        let draft = AppSettings()

        let committed = try SettingsStore.saveSettingsThrowing(
            draft,
            defaults: defaults,
            credentialStore: credentialStore
        )
        let loaded = SettingsStore.loadSettings(
            defaults: defaults,
            credentialStore: credentialStore
        )

        XCTAssertNotEqual(committed.settingsRevision, draft.settingsRevision)
        XCTAssertEqual(loaded.settingsRevision, committed.settingsRevision)
    }

    func testInvalidDecodedClockTimeIsRejected() {
        let payload = #"""
        {
          "serverBaseURL": "https://example.com/dawnpilot",
          "rainyAlarmTime": { "hour": 99, "minute": 0 }
        }
        """#

        XCTAssertThrowsError(try JSONDecoder().decode(
            AppSettings.self,
            from: Data(payload.utf8)
        ))
    }

    func testInvalidDecodedWeekdayIsRejected() {
        let payload = #"""
        {
          "serverBaseURL": "https://example.com/dawnpilot",
          "enabledWeekdays": [8]
        }
        """#

        XCTAssertThrowsError(try JSONDecoder().decode(
            AppSettings.self,
            from: Data(payload.utf8)
        ))
    }

    func testNonexistentDSTClockTimeDoesNotNormalizeSilently() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 3,
            day: 8
        )))

        XCTAssertNil(ClockTime(hour: 2, minute: 30).date(on: day, calendar: calendar))
    }

    func testPickerDateKeepsWallTimeAcrossSpringForwardReferenceDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let springForwardDay = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 3,
            day: 8
        )))

        let pickerDate = ClockTime(hour: 2, minute: 30).pickerDate(
            calendar: calendar,
            referenceDate: springForwardDay
        )
        let components = calendar.dateComponents([.hour, .minute], from: pickerDate)

        XCTAssertEqual(components.hour, 2)
        XCTAssertEqual(components.minute, 30)
    }

    func testAlarmDateChoosesFirstOccurrenceOfRepeatedFallBackTime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let fallBackDay = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 11,
            day: 1
        )))

        let alarmDate = try XCTUnwrap(
            ClockTime(hour: 1, minute: 30).alarmDate(
                on: fallBackDay,
                calendar: calendar
            )
        )

        XCTAssertEqual(calendar.timeZone.secondsFromGMT(for: alarmDate), -4 * 60 * 60)
    }

    func testInvalidTimezoneUsesStableShanghaiCalendarInsteadOfProcessTimezone() {
        var settings = AppSettings()
        settings.timeZoneIdentifier = "Invalid/Timezone"

        XCTAssertEqual(settings.calendar.timeZone.identifier, "Asia/Shanghai")
        XCTAssertNotNil(settings.validationError)
    }

    func testLegacySettingsWithoutExampleConsentMigratesToUnconfirmed() throws {
        let payload = #"""
        {
          "serverBaseURL": "https://example.com/dawnpilot",
          "latitude": 31.2304,
          "longitude": 121.4737
        }
        """#

        let settings = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(payload.utf8)
        )

        XCTAssertTrue(settings.isUsingExampleLocation)
        XCTAssertFalse(settings.exampleLocationConfirmed)
    }

    func testServerBaseURLAllowsPathAndPortButRejectsCredentialsQueryAndFragment() {
        var settings = AppSettings()
        settings.serverBaseURL = "https://example.com:8443/dawnpilot"
        XCTAssertNil(settings.validationError)

        settings.serverBaseURL = "https://user:password@example.com/dawnpilot"
        XCTAssertNotNil(settings.validationError)
        settings.serverBaseURL = "https://example.com/dawnpilot?token=value"
        XCTAssertNotNil(settings.validationError)
        settings.serverBaseURL = "https://example.com/dawnpilot#section"
        XCTAssertNotNil(settings.validationError)
    }

    func testBearerTokenAllowsEmptyFallbackModeButRejectsWhitespace() {
        var settings = AppSettings()
        settings.bearerToken = ""
        XCTAssertNil(settings.validationError)

        settings.bearerToken = "token with space"
        XCTAssertNotNil(settings.validationError)
        settings.bearerToken = "token\nheader-injection"
        XCTAssertNotNil(settings.validationError)
    }
}

final class AlarmCoordinatorTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var calendar: Calendar!
    private var now: Date!
    private var credentialStore: MemoryCredentialStore!

    override func setUpWithError() throws {
        suiteName = "AlarmCoordinatorTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        credentialStore = MemoryCredentialStore()
        var settings = AppSettings()
        settings.timeZoneIdentifier = "Asia/Shanghai"
        calendar = settings.calendar
        now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 24,
            hour: 20
        )))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        calendar = nil
        now = nil
        credentialStore = nil
    }

    func testSnapshotPreservesUnknownScheduledAlarmUntilSafeRepair() async throws {
        let unknown = SystemAlarmSnapshot(
            id: UUID(),
            fireDate: now.addingTimeInterval(3_600),
            state: .scheduled
        )
        let driver = FakeAlarmDriver(alarms: [unknown])
        let coordinator = try makeCoordinator(driver: driver)

        let snapshot = await coordinator.snapshot(now: now)
        let currentAlarms = await driver.currentAlarms()

        XCTAssertFalse(snapshot.alarmsVerified)
        XCTAssertTrue(snapshot.records.isEmpty)
        XCTAssertEqual(currentAlarms.map(\.id), [unknown.id])
    }

    func testSnapshotStaysUnverifiedWhenCommittedHorizonCoverageIsMissing() async throws {
        var settings = AppSettings()
        settings.enabledWeekdays = Set(1...7)
        _ = try SettingsStore.saveSettingsThrowing(
            settings,
            defaults: defaults,
            credentialStore: credentialStore
        )
        let coordinator = try makeCoordinator(driver: FakeAlarmDriver())

        let firstSnapshot = await coordinator.snapshot(now: now)
        let secondSnapshot = await coordinator.snapshot(now: now)

        XCTAssertFalse(firstSnapshot.alarmsVerified)
        XCTAssertFalse(secondSnapshot.alarmsVerified)
    }

    func testLostPersistenceKeepsUnknownAlarmUntilPrepareBuildsReplacement() async throws {
        var settings = AppSettings()
        settings.timeZoneIdentifier = "Asia/Shanghai"
        settings.enabledWeekdays = Set(1...7)
        let localCalendar = settings.calendar
        let operationNow = try XCTUnwrap(localCalendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 24,
            hour: 20
        )))
        let tomorrow = try XCTUnwrap(
            localCalendar.date(byAdding: .day, value: 1, to: operationNow)
        )
        let unknownFireDate = try XCTUnwrap(
            settings.fallbackAlarmTime.date(on: tomorrow, calendar: localCalendar)
        )
        let unknown = SystemAlarmSnapshot(
            id: UUID(),
            fireDate: unknownFireDate,
            state: .scheduled
        )
        let driver = FakeAlarmDriver(alarms: [unknown])
        let coordinator = try makeCoordinator(driver: driver)

        _ = await coordinator.snapshot(now: operationNow)
        let preservedAlarmIDs = await driver.currentAlarmIDs()
        XCTAssertTrue(preservedAlarmIDs.contains(unknown.id))

        _ = try await coordinator.authorizeAndPrepare(
            settings: settings,
            now: operationNow
        )

        let finalAlarms = await driver.currentAlarms()
        let finalRecords = await coordinator.snapshot(now: operationNow).records
        XCTAssertFalse(finalAlarms.contains { $0.id == unknown.id })
        for record in finalRecords where record.fireDate > operationNow {
            XCTAssertTrue(finalAlarms.contains {
                $0.id == record.alarmID && $0.fireDate == record.fireDate
            })
        }
        XCTAssertTrue(finalRecords.contains {
            makeDateKey($0.fireDate, calendar: localCalendar)
                == makeDateKey(unknownFireDate, calendar: localCalendar)
        })
    }

    func testPendingReplacementWithScheduledNewAlarmCommitsAndCancelsOld() async throws {
        let oldRecord = makeRecord(
            dateKey: "2026-07-25",
            fireDate: now.addingTimeInterval(12 * 60 * 60)
        )
        let newRecord = makeRecord(
            dateKey: oldRecord.dateKey,
            fireDate: oldRecord.fireDate.addingTimeInterval(5 * 60),
            kind: .clear
        )
        try SettingsStore.saveRecordsThrowing([oldRecord], defaults: defaults)
        try SettingsStore.savePendingReplacementThrowing(
            PendingAlarmReplacement(
                oldRecord: oldRecord,
                newRecord: newRecord,
                phase: .prepared
            ),
            defaults: defaults
        )
        let driver = FakeAlarmDriver(alarms: [
            systemAlarm(for: oldRecord),
            systemAlarm(for: newRecord)
        ])
        let coordinator = try makeCoordinator(driver: driver)

        let snapshot = await coordinator.snapshot(now: now)
        let currentAlarmIDs = await driver.currentAlarmIDs()

        XCTAssertFalse(snapshot.alarmsVerified)
        XCTAssertEqual(snapshot.records, [newRecord])
        XCTAssertEqual(currentAlarmIDs, [newRecord.alarmID])
        assertPendingReplacementWasCleared()
    }

    func testOldAlarmCancellationFailureLeavesRecoverableJournal() async throws {
        let oldRecord = makeRecord(
            dateKey: "2026-07-25",
            fireDate: now.addingTimeInterval(12 * 60 * 60)
        )
        let newRecord = makeRecord(
            dateKey: oldRecord.dateKey,
            fireDate: oldRecord.fireDate.addingTimeInterval(5 * 60),
            kind: .clear
        )
        try SettingsStore.saveRecordsThrowing([oldRecord], defaults: defaults)
        try SettingsStore.savePendingReplacementThrowing(
            PendingAlarmReplacement(
                oldRecord: oldRecord,
                newRecord: newRecord,
                phase: .newAlarmScheduled
            ),
            defaults: defaults
        )
        let driver = FakeAlarmDriver(alarms: [
            systemAlarm(for: oldRecord),
            systemAlarm(for: newRecord)
        ])
        await driver.setCancelFailure(for: oldRecord.alarmID, enabled: true)
        let coordinator = try makeCoordinator(driver: driver)

        let failedSnapshot = await coordinator.snapshot(now: now)
        XCTAssertFalse(failedSnapshot.alarmsVerified)
        XCTAssertEqual(failedSnapshot.records, [newRecord])
        assertPendingReplacementExists(phase: .recordCommitted)

        await driver.setCancelFailure(for: oldRecord.alarmID, enabled: false)
        let recoveredSnapshot = await coordinator.snapshot(now: now)
        let currentAlarmIDs = await driver.currentAlarmIDs()
        XCTAssertFalse(recoveredSnapshot.alarmsVerified)
        XCTAssertEqual(currentAlarmIDs, [newRecord.alarmID])
        assertPendingReplacementWasCleared()
    }

    func testInvalidPendingAlarmIsPreservedWhenNoVerifiedOldAlarmExists() async throws {
        let expectedRecord = makeRecord(
            dateKey: "2026-07-25",
            fireDate: now.addingTimeInterval(12 * 60 * 60)
        )
        try SettingsStore.savePendingReplacementThrowing(
            PendingAlarmReplacement(
                oldRecord: nil,
                newRecord: expectedRecord,
                phase: .newAlarmScheduled
            ),
            defaults: defaults
        )
        let mismatchedSystemAlarm = SystemAlarmSnapshot(
            id: expectedRecord.alarmID,
            fireDate: expectedRecord.fireDate.addingTimeInterval(10 * 60),
            state: .scheduled
        )
        let driver = FakeAlarmDriver(alarms: [mismatchedSystemAlarm])
        let coordinator = try makeCoordinator(driver: driver)

        let snapshot = await coordinator.snapshot(now: now)
        let currentAlarmIDs = await driver.currentAlarmIDs()

        XCTAssertFalse(snapshot.alarmsVerified)
        XCTAssertTrue(snapshot.records.isEmpty)
        XCTAssertTrue(currentAlarmIDs.contains(mismatchedSystemAlarm.id))
        assertPendingReplacementExists(phase: .newAlarmScheduled)
    }

    func testCorruptRecordPersistenceBlocksCleanupAndNewScheduling() async throws {
        defaults.set(Data("not-json".utf8), forKey: "dawnPilot.records.v2")
        let unknown = SystemAlarmSnapshot(
            id: UUID(),
            fireDate: now.addingTimeInterval(3_600),
            state: .scheduled
        )
        let driver = FakeAlarmDriver(alarms: [unknown])
        let coordinator = try makeCoordinator(driver: driver)

        let snapshot = await coordinator.snapshot(now: now)
        let currentAlarmIDs = await driver.currentAlarmIDs()
        XCTAssertFalse(snapshot.alarmsVerified)
        XCTAssertEqual(currentAlarmIDs, [unknown.id])

        do {
            _ = try await coordinator.authorizeAndPrepare(
                settings: AppSettings(),
                now: now
            )
            XCTFail("Corrupt managed records must block blind alarm creation.")
        } catch let error as AlarmCoordinatorError {
            guard case .persistence = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testCancellationDuringSchedulePropagatesAndJournalRecovers() async throws {
        let gate = AsyncStartGate()
        let driver = FakeAlarmDriver(scheduleGate: gate)
        let coordinator = try makeCoordinator(driver: driver)
        let operationNow = try XCTUnwrap(now)
        let operation = Task {
            try await coordinator.authorizeAndPrepare(
                settings: AppSettings(),
                now: operationNow
            )
        }

        await gate.waitUntilStarted()
        operation.cancel()
        do {
            _ = try await operation.value
            XCTFail("Cancellation must not be converted into a fallback success.")
        } catch is CancellationError {
            // Expected.
        }
        assertPendingReplacementExists(phase: .prepared)

        let recoveredSnapshot = await coordinator.snapshot(now: now)
        XCTAssertFalse(recoveredSnapshot.alarmsVerified)
        XCTAssertTrue(recoveredSnapshot.records.isEmpty)
        assertPendingReplacementExists(phase: .prepared)
    }

    func testMorningHorizonRefreshKeepsVerifiedAlarmLaterToday() async throws {
        var settings = AppSettings()
        settings.timeZoneIdentifier = "Asia/Shanghai"
        settings.enabledWeekdays = Set(1...7)
        let localCalendar = settings.calendar
        let morning = try XCTUnwrap(localCalendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 24,
            hour: 7
        )))
        let today = localCalendar.startOfDay(for: morning)
        let todayFireDate = try XCTUnwrap(
            settings.fallbackAlarmTime.date(on: today, calendar: localCalendar)
        )
        let todayRecord = makeRecord(
            dateKey: "2026-07-24",
            fireDate: todayFireDate
        )
        try SettingsStore.saveRecordsThrowing([todayRecord], defaults: defaults)
        let driver = FakeAlarmDriver(alarms: [systemAlarm(for: todayRecord)])
        let coordinator = try makeCoordinator(driver: driver)

        _ = try await coordinator.rebuildFallbacks(settings: settings, now: morning)

        let currentAlarmIDs = await driver.currentAlarmIDs()
        let snapshot = await coordinator.snapshot(now: morning)
        XCTAssertTrue(currentAlarmIDs.contains(todayRecord.alarmID))
        XCTAssertTrue(snapshot.records.contains { $0.alarmID == todayRecord.alarmID })
    }

    func testTimezoneCollisionRekeysAndProtectsTodaysVerifiedAlarm() async throws {
        var settings = AppSettings()
        settings.timeZoneIdentifier = "America/Los_Angeles"
        settings.enabledWeekdays = Set(1...7)
        let localCalendar = settings.calendar
        let morning = try XCTUnwrap(localCalendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 24,
            hour: 7
        )))
        let today = localCalendar.startOfDay(for: morning)
        let todayFireDate = try XCTUnwrap(
            settings.fallbackAlarmTime.date(on: today, calendar: localCalendar)
        )

        // This is a valid old-zone key (for example UTC+14) that collides with
        // tomorrow's date key after switching to America/Los_Angeles.
        let protectedRecord = makeRecord(
            dateKey: "2026-07-25",
            fireDate: todayFireDate
        )
        try SettingsStore.saveRecordsThrowing([protectedRecord], defaults: defaults)
        let driver = FakeAlarmDriver(alarms: [systemAlarm(for: protectedRecord)])
        let coordinator = try makeCoordinator(driver: driver)

        _ = try await coordinator.authorizeAndPrepare(settings: settings, now: morning)

        let currentAlarmIDs = await driver.currentAlarmIDs()
        let snapshot = await coordinator.snapshot(now: morning)
        let rekeyedTodayRecord = snapshot.records.first {
            $0.alarmID == protectedRecord.alarmID
        }
        XCTAssertTrue(currentAlarmIDs.contains(protectedRecord.alarmID))
        XCTAssertEqual(rekeyedTodayRecord?.dateKey, "2026-07-24")
        XCTAssertTrue(snapshot.records.contains {
            $0.dateKey == "2026-07-25"
                && $0.alarmID != protectedRecord.alarmID
        })
    }

    func testSpringForwardHorizonSchedulesMissingTwoThirtyAtThree() async throws {
        var settings = AppSettings()
        settings.timeZoneIdentifier = "America/New_York"
        settings.fallbackAlarmTime = ClockTime(hour: 2, minute: 30)
        settings.enabledWeekdays = Set(1...7)
        let localCalendar = settings.calendar
        let operationNow = try XCTUnwrap(localCalendar.date(from: DateComponents(
            year: 2026,
            month: 3,
            day: 7,
            hour: 20
        )))
        let driver = FakeAlarmDriver()
        let coordinator = try makeCoordinator(driver: driver)

        let status = try await coordinator.authorizeAndPrepare(
            settings: settings,
            now: operationNow
        )

        let snapshot = await coordinator.snapshot(now: operationNow)
        let springForwardRecord = try XCTUnwrap(
            snapshot.records.first { $0.dateKey == "2026-03-08" }
        )
        let components = localCalendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: springForwardRecord.fireDate
        )
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 3)
        XCTAssertEqual(components.day, 8)
        XCTAssertEqual(components.hour, 3)
        XCTAssertEqual(components.minute, 0)
        XCTAssertEqual(status.alarmDate, springForwardRecord.fireDate)
    }

    func testSpringForwardWeatherRefreshReportsActualScheduledTime() async throws {
        var settings = AppSettings()
        settings.timeZoneIdentifier = "America/New_York"
        settings.clearAlarmTime = ClockTime(hour: 2, minute: 30)
        settings.enabledWeekdays = Set(1...7)
        settings.bearerToken = "test-token"
        settings.exampleLocationConfirmed = true
        let localCalendar = settings.calendar
        let operationNow = try XCTUnwrap(localCalendar.date(from: DateComponents(
            year: 2026,
            month: 3,
            day: 7,
            hour: 20
        )))
        let targetDay = try XCTUnwrap(
            localCalendar.date(byAdding: .day, value: 1, to: operationNow)
        )
        let forecast = ServerForecast(
            schemaVersion: 1,
            source: "test",
            fetchedAt: operationNow,
            servedAt: operationNow,
            stale: false,
            latitude: settings.latitude,
            longitude: settings.longitude,
            timezone: settings.timeZoneIdentifier,
            hourly: [
                makeForecastHour(day: targetDay, hour: 7, calendar: localCalendar),
                makeForecastHour(day: targetDay, hour: 8, calendar: localCalendar)
            ]
        )
        let driver = FakeAlarmDriver()
        let coordinator = AlarmCoordinator(
            alarmDriver: driver,
            weatherService: StaticForecastService(forecast: forecast),
            defaultsSuiteName: suiteName
        )

        let status = try await coordinator.refreshTomorrow(
            settings: settings,
            now: operationNow
        )

        let alarmDate = try XCTUnwrap(status.alarmDate)
        let components = localCalendar.dateComponents(
            [.hour, .minute],
            from: alarmDate
        )
        let snapshot = await coordinator.snapshot(now: operationNow)
        XCTAssertEqual(status.outcome, .clear)
        XCTAssertEqual(components.hour, 3)
        XCTAssertEqual(components.minute, 0)
        XCTAssertTrue(status.message.contains("03:00"))
        XCTAssertEqual(
            snapshot.records.first { $0.dateKey == "2026-03-08" }?.fireDate,
            alarmDate
        )
    }

    func testEveryRefreshTriggerPreservesFallbackForUnconfirmedExampleLocation() async throws {
        var settings = AppSettings()
        settings.bearerToken = "test-token"
        settings.exampleLocationConfirmed = false
        settings.enabledWeekdays = Set(1...7)
        let weatherService = CountingForecastService()
        let driver = FakeAlarmDriver()
        let coordinator = AlarmCoordinator(
            alarmDriver: driver,
            weatherService: weatherService,
            defaultsSuiteName: suiteName
        )

        let status = try await coordinator.refreshTomorrow(
            settings: settings,
            now: now
        )

        let fetchCount = await weatherService.currentFetchCount()
        let scheduledRecords = await driver.scheduledRecords()
        XCTAssertEqual(status.outcome, .fallback)
        XCTAssertTrue(status.message.contains("固定位置确认"))
        XCTAssertEqual(fetchCount, 0)
        XCTAssertFalse(scheduledRecords.isEmpty)
    }

    func testEveryRefreshTriggerPreservesFallbackWithoutBearerToken() async throws {
        var settings = AppSettings()
        settings.latitude = 0
        settings.longitude = 0
        settings.bearerToken = ""
        settings.enabledWeekdays = Set(1...7)
        let weatherService = CountingForecastService()
        let driver = FakeAlarmDriver()
        let coordinator = AlarmCoordinator(
            alarmDriver: driver,
            weatherService: weatherService,
            defaultsSuiteName: suiteName
        )

        let status = try await coordinator.refreshTomorrow(
            settings: settings,
            now: now
        )

        let fetchCount = await weatherService.currentFetchCount()
        let scheduledRecords = await driver.scheduledRecords()
        XCTAssertEqual(status.outcome, .fallback)
        XCTAssertTrue(status.message.contains("访问令牌"))
        XCTAssertEqual(fetchCount, 0)
        XCTAssertFalse(scheduledRecords.isEmpty)
    }

    func testFallbackStageFailureLeavesPreviouslyPersistedSettingsUnchanged() async throws {
        let credentials = MemoryCredentialStore()
        var oldSettings = AppSettings()
        oldSettings.enabledWeekdays = [2]
        try SettingsStore.saveSettingsThrowing(
            oldSettings,
            defaults: defaults,
            credentialStore: credentials
        )

        var newSettings = oldSettings
        newSettings.enabledWeekdays = Set(1...7)
        let driver = FakeAlarmDriver(scheduleFailureAfter: 0)
        let coordinator = AlarmCoordinator(
            alarmDriver: driver,
            credentialStore: credentials,
            defaultsSuiteName: suiteName
        )

        do {
            _ = try await coordinator.rebuildFallbacks(
                settings: newSettings,
                now: now
            )
            XCTFail("A failed stage must not commit new settings.")
        } catch FakeAlarmDriverError.scheduleFailed {
            // Expected.
        }

        let persisted = SettingsStore.loadSettings(
            defaults: defaults,
            credentialStore: credentials
        )
        XCTAssertEqual(persisted.enabledWeekdays, oldSettings.enabledWeekdays)
    }

    func testDisabledWeekdayIsCancelledOnlyAfterSettingsCommit() async throws {
        let credentials = MemoryCredentialStore()
        var oldSettings = AppSettings()
        oldSettings.enabledWeekdays = Set(1...7)
        try SettingsStore.saveSettingsThrowing(
            oldSettings,
            defaults: defaults,
            credentialStore: credentials
        )
        let tomorrow = try XCTUnwrap(
            oldSettings.calendar.date(byAdding: .day, value: 1, to: now)
        )
        let oldFireDate = try XCTUnwrap(
            oldSettings.fallbackAlarmTime.alarmDate(
                on: tomorrow,
                calendar: oldSettings.calendar
            )
        )
        let oldRecord = makeRecord(
            dateKey: "2026-07-25",
            fireDate: oldFireDate
        )
        try SettingsStore.saveRecordsThrowing([oldRecord], defaults: defaults)
        let driver = FakeAlarmDriver(alarms: [systemAlarm(for: oldRecord)])
        let coordinator = AlarmCoordinator(
            alarmDriver: driver,
            credentialStore: credentials,
            defaultsSuiteName: suiteName
        )

        var newSettings = oldSettings
        newSettings.enabledWeekdays = [1]
        credentials.saveError = MemoryCredentialError.writeFailed
        do {
            _ = try await coordinator.rebuildFallbacks(
                settings: newSettings,
                now: now
            )
            XCTFail("The injected settings commit must fail.")
        } catch let error as AlarmCoordinatorError {
            guard case .settingsCommitFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let alarmIDsBeforeCommit = await driver.currentAlarmIDs()
        let settingsBeforeCommit = SettingsStore.loadSettings(
            defaults: defaults,
            credentialStore: credentials
        )
        XCTAssertTrue(alarmIDsBeforeCommit.contains(oldRecord.alarmID))
        XCTAssertEqual(
            settingsBeforeCommit.enabledWeekdays,
            oldSettings.enabledWeekdays
        )

        credentials.saveError = nil
        _ = try await coordinator.rebuildFallbacks(
            settings: newSettings,
            now: now
        )

        let alarmIDsAfterCommit = await driver.currentAlarmIDs()
        let settingsAfterCommit = SettingsStore.loadSettings(
            defaults: defaults,
            credentialStore: credentials
        )
        XCTAssertFalse(alarmIDsAfterCommit.contains(oldRecord.alarmID))
        XCTAssertEqual(
            settingsAfterCommit.enabledWeekdays,
            newSettings.enabledWeekdays
        )
    }

    func testTimezoneRebuildNeverSchedulesUsingOldFireDateCivilDay() async throws {
        var oldSettings = AppSettings()
        oldSettings.timeZoneIdentifier = "Asia/Shanghai"
        oldSettings.enabledWeekdays = Set(1...7)
        let oldCalendar = oldSettings.calendar
        let lateNight = try XCTUnwrap(oldCalendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 24,
            hour: 23,
            minute: 30
        )))
        let oldDay = try XCTUnwrap(oldCalendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 25
        )))
        let oldFireDate = try XCTUnwrap(
            oldSettings.fallbackAlarmTime.date(on: oldDay, calendar: oldCalendar)
        )
        let oldRecord = makeRecord(dateKey: "2026-07-25", fireDate: oldFireDate)
        try SettingsStore.saveRecordsThrowing([oldRecord], defaults: defaults)
        let driver = FakeAlarmDriver(alarms: [systemAlarm(for: oldRecord)])
        let coordinator = try makeCoordinator(driver: driver)

        var newSettings = oldSettings
        newSettings.timeZoneIdentifier = "America/Los_Angeles"
        _ = try await coordinator.rebuildFallbacks(
            settings: newSettings,
            now: lateNight
        )

        let scheduledRecords = await driver.scheduledRecords()
        XCTAssertFalse(scheduledRecords.isEmpty)
        XCTAssertTrue(scheduledRecords.allSatisfy { $0.fireDate > lateNight })
    }

    func testServerErrorDescriptionNeverIncludesUpstreamBody() {
        let error = WeatherServiceError.server(
            statusCode: 500,
            message: "upstream-private-response-body"
        )

        XCTAssertFalse(error.localizedDescription.contains("upstream-private-response-body"))
        XCTAssertTrue(error.localizedDescription.contains("暂时不可用"))
    }

    private func makeRecord(
        dateKey: String,
        fireDate: Date,
        kind: ManagedAlarmKind = .fallback
    ) -> ManagedAlarmRecord {
        ManagedAlarmRecord(
            dateKey: dateKey,
            alarmID: UUID(),
            fireDate: fireDate,
            kind: kind,
            updatedAt: now
        )
    }

    private func makeCoordinator(driver: FakeAlarmDriver) throws -> AlarmCoordinator {
        AlarmCoordinator(
            alarmDriver: driver,
            credentialStore: credentialStore,
            defaultsSuiteName: suiteName
        )
    }

    private func makeForecastHour(
        day: Date,
        hour: Int,
        calendar: Calendar
    ) -> ForecastHour {
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = hour
        let time = calendar.date(from: components)!
        return ForecastHour(
            time: time,
            precipitationProbability: 5,
            precipitationMM: 0,
            rainMM: 0,
            showersMM: 0,
            snowfallCM: 0,
            weatherCode: 1
        )
    }

    private func systemAlarm(for record: ManagedAlarmRecord) -> SystemAlarmSnapshot {
        SystemAlarmSnapshot(
            id: record.alarmID,
            fireDate: record.fireDate,
            state: .scheduled
        )
    }

    private func makeDateKey(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private func assertPendingReplacementWasCleared(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch SettingsStore.loadPendingReplacementResult(defaults: defaults) {
        case .success(nil):
            break
        case .success(.some), .failure:
            XCTFail("Expected the pending replacement to be cleared.", file: file, line: line)
        }
    }

    private func assertPendingReplacementExists(
        phase: PendingAlarmReplacementPhase,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch SettingsStore.loadPendingReplacementResult(defaults: defaults) {
        case .success(let pending):
            XCTAssertEqual(pending?.phase, phase, file: file, line: line)
        case .failure(let error):
            XCTFail("Unable to load pending replacement: \(error)", file: file, line: line)
        }
    }
}

private enum MemoryCredentialError: LocalizedError {
    case readFailed
    case writeFailed
}

private final class MemoryCredentialStore: CredentialStoring, @unchecked Sendable {
    var credential: StoredCredential?
    var loadError: Error?
    var saveError: Error?
    var failSaveCallNumbers: Set<Int> = []
    private(set) var saveCallCount = 0

    func loadCredential() throws -> StoredCredential? {
        if let loadError {
            throw loadError
        }
        return credential
    }

    func saveCredential(_ credential: StoredCredential?) throws {
        saveCallCount += 1
        if let saveError, failSaveCallNumbers.isEmpty
            || failSaveCallNumbers.contains(saveCallCount) {
            throw saveError
        }
        self.credential = credential
    }

    func resolvedBearerToken() throws -> String? {
        switch try loadCredential() {
        case .none:
            nil
        case .legacyToken(let token):
            token
        case .envelope(let envelope):
            envelope.current?.bearerToken ?? envelope.pending?.bearerToken
        }
    }
}

private enum FakeAlarmDriverError: Error {
    case cancellationFailed
    case scheduleFailed
}

private enum CountingForecastError: Error {
    case unexpectedlyFetched
}

private actor CountingForecastService: ForecastFetching {
    private var fetchCount = 0

    func fetchForecast(settings: AppSettings) throws -> ServerForecast {
        fetchCount += 1
        throw CountingForecastError.unexpectedlyFetched
    }

    func currentFetchCount() -> Int {
        fetchCount
    }
}

private struct StaticForecastService: ForecastFetching {
    let forecast: ServerForecast

    func fetchForecast(settings: AppSettings) -> ServerForecast {
        forecast
    }
}

private actor FakeAlarmDriver: AlarmScheduling {
    private var authorization: AlarmAuthorization
    private var storedAlarms: [UUID: SystemAlarmSnapshot]
    private var recordsScheduledByTest: [ManagedAlarmRecord] = []
    private var cancelFailureIDs: Set<UUID> = []
    private let scheduleGate: AsyncStartGate?
    private let scheduleFailureAfter: Int?

    init(
        authorization: AlarmAuthorization = .authorized,
        alarms: [SystemAlarmSnapshot] = [],
        scheduleGate: AsyncStartGate? = nil,
        scheduleFailureAfter: Int? = nil
    ) {
        self.authorization = authorization
        storedAlarms = Dictionary(uniqueKeysWithValues: alarms.map { ($0.id, $0) })
        self.scheduleGate = scheduleGate
        self.scheduleFailureAfter = scheduleFailureAfter
    }

    func authorizationState() -> AlarmAuthorization {
        authorization
    }

    func requestAuthorization() -> AlarmAuthorization {
        authorization = .authorized
        return authorization
    }

    func alarms() -> [SystemAlarmSnapshot] {
        Array(storedAlarms.values)
    }

    func schedule(_ record: ManagedAlarmRecord) async throws {
        if let scheduleFailureAfter,
           recordsScheduledByTest.count >= scheduleFailureAfter {
            throw FakeAlarmDriverError.scheduleFailed
        }
        if let scheduleGate {
            await scheduleGate.markStarted()
            try await Task.sleep(for: .seconds(60))
        }
        try Task.checkCancellation()
        recordsScheduledByTest.append(record)
        storedAlarms[record.alarmID] = SystemAlarmSnapshot(
            id: record.alarmID,
            fireDate: record.fireDate,
            state: .scheduled
        )
    }

    func cancel(id: UUID) throws {
        if cancelFailureIDs.contains(id) {
            throw FakeAlarmDriverError.cancellationFailed
        }
        storedAlarms.removeValue(forKey: id)
    }

    func setCancelFailure(for id: UUID, enabled: Bool) {
        if enabled {
            cancelFailureIDs.insert(id)
        } else {
            cancelFailureIDs.remove(id)
        }
    }

    func currentAlarms() -> [SystemAlarmSnapshot] {
        Array(storedAlarms.values)
    }

    func currentAlarmIDs() -> Set<UUID> {
        Set(storedAlarms.keys)
    }

    func scheduledRecords() -> [ManagedAlarmRecord] {
        recordsScheduledByTest
    }
}

private actor AsyncStartGate {
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        started = true
        let pendingWaiters = waiters
        waiters.removeAll()
        for waiter in pendingWaiters {
            waiter.resume()
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
