import Foundation

struct ClockTime: Codable, Equatable, Hashable, Sendable {
    var hour: Int
    var minute: Int

    init(hour: Int, minute: Int) {
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let hour = try container.decode(Int.self, forKey: .hour)
        let minute = try container.decode(Int.self, forKey: .minute)
        guard (0...23).contains(hour), (0...59).contains(minute) else {
            throw DecodingError.dataCorruptedError(
                forKey: (0...23).contains(hour) ? .minute : .hour,
                in: container,
                debugDescription: "Clock time is outside the supported range."
            )
        }
        self.hour = hour
        self.minute = minute
    }

    init(date: Date, calendar: Calendar) {
        self.init(
            hour: calendar.component(.hour, from: date),
            minute: calendar.component(.minute, from: date)
        )
    }

    var minutesFromMidnight: Int {
        hour * 60 + minute
    }

    var displayText: String {
        String(format: "%02d:%02d", hour, minute)
    }

    func pickerDate(
        calendar: Calendar,
        referenceDate: Date = .now
    ) -> Date {
        let referenceDay = calendar.startOfDay(for: referenceDate)
        for dayOffset in 0..<14 {
            guard let day = calendar.date(
                byAdding: .day,
                value: dayOffset,
                to: referenceDay
            ) else {
                continue
            }
            if let representableDate = date(on: day, calendar: calendar) {
                return representableDate
            }
        }

        // Every valid ClockTime should be representable within two weeks. Keep a
        // deterministic fallback instead of coupling picker display to process time.
        var components = DateComponents()
        components.year = 2001
        components.month = 1
        components.day = 15
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components) ?? referenceDay
    }

    func date(on day: Date, calendar: Calendar) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = hour
        components.minute = minute
        components.second = 0
        guard let date = calendar.date(from: components) else { return nil }
        let resolved = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard resolved.year == components.year,
              resolved.month == components.month,
              resolved.day == components.day,
              resolved.hour == hour,
              resolved.minute == minute else {
            return nil
        }
        return date
    }

    func alarmDate(on day: Date, calendar: Calendar) -> Date? {
        let dayStart = calendar.startOfDay(for: day)
        guard let nextDayStart = calendar.date(byAdding: .day, value: 1, to: dayStart),
              let searchStart = calendar.date(
                  byAdding: .second,
                  value: -1,
                  to: dayStart
              ) else {
            return nil
        }

        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        components.second = 0
        guard let candidate = calendar.nextDate(
            after: searchStart,
            matching: components,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        ),
        candidate >= dayStart,
        candidate < nextDayStart else {
            return nil
        }
        return candidate
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hour, forKey: .hour)
        try container.encode(minute, forKey: .minute)
    }

    var isValid: Bool {
        (0...23).contains(hour) && (0...59).contains(minute)
    }

    private enum CodingKeys: String, CodingKey {
        case hour
        case minute
    }
}

struct AppSettings: Codable, Equatable, Sendable {
    var settingsRevision = UUID()
    var serverBaseURL = "https://chat.laoxitv.top/dawnpilot"
    var bearerToken = ""
    var latitude = 31.2304
    var longitude = 121.4737
    var timeZoneIdentifier = AppSettings.defaultTimeZoneIdentifier
    var exampleLocationConfirmed = false

    var rainyAlarmTime = ClockTime(hour: 7, minute: 50)
    var fallbackAlarmTime = ClockTime(hour: 8, minute: 0)
    var clearAlarmTime = ClockTime(hour: 8, minute: 5)

    var forecastWindowStart = ClockTime(hour: 7, minute: 0)
    var forecastWindowEnd = ClockTime(hour: 9, minute: 0)
    var precipitationProbabilityThreshold = 40

    // Calendar weekday values: Sunday = 1, Monday = 2, ... Saturday = 7.
    var enabledWeekdays: Set<Int> = [2, 3, 4, 5, 6]

    // A failed decode must not silently turn into usable default scheduling settings.
    var storageRecoveryMessage: String? = nil

    static let fallbackHorizonDays = 14
    static let maximumForecastAge: TimeInterval = 6 * 60 * 60
    static let maximumForecastClockSkew: TimeInterval = 5 * 60
    static let defaultTimeZoneIdentifier = "Asia/Shanghai"
    static let exampleLatitude = 31.2304
    static let exampleLongitude = 121.4737
    static let legacySettingsRevision = UUID(
        uuidString: "00000000-0000-4000-8000-000000000001"
    )!

    init() {}

    init(from decoder: Decoder) throws {
        let defaults = AppSettings()
        let container = try decoder.container(keyedBy: CodingKeys.self)

        settingsRevision = try container.decodeIfPresent(
            UUID.self,
            forKey: .settingsRevision
        ) ?? Self.legacySettingsRevision
        serverBaseURL = try container.decodeIfPresent(String.self, forKey: .serverBaseURL)
            ?? defaults.serverBaseURL
        // Decoding is retained only for migration from the v1 UserDefaults payload.
        bearerToken = try container.decodeIfPresent(String.self, forKey: .bearerToken) ?? ""
        latitude = try container.decodeIfPresent(Double.self, forKey: .latitude)
            ?? defaults.latitude
        longitude = try container.decodeIfPresent(Double.self, forKey: .longitude)
            ?? defaults.longitude
        timeZoneIdentifier = try container.decodeIfPresent(String.self, forKey: .timeZoneIdentifier)
            ?? defaults.timeZoneIdentifier
        // Existing payloads predate explicit example-location consent.
        exampleLocationConfirmed = try container.decodeIfPresent(
            Bool.self,
            forKey: .exampleLocationConfirmed
        ) ?? false
        rainyAlarmTime = try container.decodeIfPresent(ClockTime.self, forKey: .rainyAlarmTime)
            ?? defaults.rainyAlarmTime
        fallbackAlarmTime = try container.decodeIfPresent(ClockTime.self, forKey: .fallbackAlarmTime)
            ?? defaults.fallbackAlarmTime
        clearAlarmTime = try container.decodeIfPresent(ClockTime.self, forKey: .clearAlarmTime)
            ?? defaults.clearAlarmTime
        forecastWindowStart = try container.decodeIfPresent(
            ClockTime.self,
            forKey: .forecastWindowStart
        ) ?? defaults.forecastWindowStart
        forecastWindowEnd = try container.decodeIfPresent(
            ClockTime.self,
            forKey: .forecastWindowEnd
        ) ?? defaults.forecastWindowEnd
        precipitationProbabilityThreshold = try container.decodeIfPresent(
            Int.self,
            forKey: .precipitationProbabilityThreshold
        ) ?? defaults.precipitationProbabilityThreshold
        enabledWeekdays = try container.decodeIfPresent(Set<Int>.self, forKey: .enabledWeekdays)
            ?? defaults.enabledWeekdays
        storageRecoveryMessage = nil

        if let validationError {
            throw DecodingError.dataCorruptedError(
                forKey: .enabledWeekdays,
                in: container,
                debugDescription: validationError
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(settingsRevision, forKey: .settingsRevision)
        try container.encode(serverBaseURL, forKey: .serverBaseURL)
        // bearerToken intentionally lives only in Keychain.
        try container.encode(latitude, forKey: .latitude)
        try container.encode(longitude, forKey: .longitude)
        try container.encode(timeZoneIdentifier, forKey: .timeZoneIdentifier)
        try container.encode(exampleLocationConfirmed, forKey: .exampleLocationConfirmed)
        try container.encode(rainyAlarmTime, forKey: .rainyAlarmTime)
        try container.encode(fallbackAlarmTime, forKey: .fallbackAlarmTime)
        try container.encode(clearAlarmTime, forKey: .clearAlarmTime)
        try container.encode(forecastWindowStart, forKey: .forecastWindowStart)
        try container.encode(forecastWindowEnd, forKey: .forecastWindowEnd)
        try container.encode(
            precipitationProbabilityThreshold,
            forKey: .precipitationProbabilityThreshold
        )
        try container.encode(enabledWeekdays, forKey: .enabledWeekdays)
    }

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier)
            ?? TimeZone(identifier: Self.defaultTimeZoneIdentifier)
            ?? .gmt
        return calendar
    }

    var isUsingExampleLocation: Bool {
        abs(latitude - Self.exampleLatitude) < 0.000_001
            && abs(longitude - Self.exampleLongitude) < 0.000_001
    }

    var weatherConfigurationError: String? {
        var missingItems: [String] = []
        if bearerToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missingItems.append("访问令牌")
        }
        if isUsingExampleLocation, !exampleLocationConfirmed {
            missingItems.append("固定位置确认")
        }
        guard !missingItems.isEmpty else { return nil }
        return "请先完成\(missingItems.joined(separator: "和"))；如果暂时不使用天气判断，可以仅重建保底闹钟。"
    }

    var credentialOrigin: String? {
        guard let url = URL(string: serverBaseURL),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased() else {
            return nil
        }
        let hostText = host.contains(":") ? "[\(host)]" : host
        let isDefaultPort = (scheme == "https" && url.port == 443)
            || (scheme == "http" && url.port == 80)
        let portText = url.port.flatMap { isDefaultPort ? nil : ":\($0)" } ?? ""
        let trimmedPath = url.path == "/"
            ? ""
            : url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let pathText = trimmedPath.isEmpty ? "" : "/\(trimmedPath)"
        return "\(scheme)://\(hostText)\(portText)\(pathText)"
    }

    var validationError: String? {
        if let storageRecoveryMessage {
            return storageRecoveryMessage
        }
        guard let url = URL(string: serverBaseURL),
              let scheme = url.scheme?.lowercased(),
              url.host != nil,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              (scheme == "https" || isLocalDevelopmentURL(url)) else {
            return "服务器地址必须是无凭据、查询或片段的 HTTPS 基础地址；本机调试可使用 localhost。"
        }
        guard latitude.isFinite,
              longitude.isFinite,
              (-90...90).contains(latitude),
              (-180...180).contains(longitude) else {
            return "经纬度超出有效范围。"
        }
        guard TimeZone(identifier: timeZoneIdentifier) != nil else {
            return "时区标识无效，例如 Asia/Shanghai。"
        }
        guard forecastWindowStart.minutesFromMidnight < forecastWindowEnd.minutesFromMidnight else {
            return "天气判断结束时间必须晚于开始时间。"
        }
        if !bearerToken.isEmpty,
           bearerToken.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            return "访问令牌不能包含空格、换行或其他空白字符。"
        }
        guard (0...100).contains(precipitationProbabilityThreshold) else {
            return "降水概率阈值必须在 0 到 100 之间。"
        }
        guard rainyAlarmTime.isValid,
              fallbackAlarmTime.isValid,
              clearAlarmTime.isValid,
              forecastWindowStart.isValid,
              forecastWindowEnd.isValid else {
            return "时间设置超出有效范围。"
        }
        guard !enabledWeekdays.isEmpty,
              enabledWeekdays.isSubset(of: Set(1...7)) else {
            return "至少选择一个需要闹钟的星期。"
        }
        return nil
    }

    func isEnabledAlarmDay(_ date: Date) -> Bool {
        enabledWeekdays.contains(calendar.component(.weekday, from: date))
    }

    func alarmTime(for kind: ManagedAlarmKind) -> ClockTime {
        switch kind {
        case .rainy: rainyAlarmTime
        case .clear: clearAlarmTime
        case .fallback: fallbackAlarmTime
        }
    }

    private func isLocalDevelopmentURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http" else { return false }
        return ["localhost", "127.0.0.1", "::1"].contains(url.host?.lowercased() ?? "")
    }

    static func recoveryPlaceholder(message: String) -> AppSettings {
        var settings = AppSettings()
        settings.storageRecoveryMessage = message
        return settings
    }

    mutating func clearStorageRecoveryMarker() {
        storageRecoveryMessage = nil
    }

    private enum CodingKeys: String, CodingKey {
        case settingsRevision
        case serverBaseURL
        case bearerToken
        case latitude
        case longitude
        case timeZoneIdentifier
        case exampleLocationConfirmed
        case rainyAlarmTime
        case fallbackAlarmTime
        case clearAlarmTime
        case forecastWindowStart
        case forecastWindowEnd
        case precipitationProbabilityThreshold
        case enabledWeekdays
    }
}

struct WeekdayOption: Identifiable, Sendable {
    let id: Int
    let shortName: String

    static let all = [
        WeekdayOption(id: 2, shortName: "一"),
        WeekdayOption(id: 3, shortName: "二"),
        WeekdayOption(id: 4, shortName: "三"),
        WeekdayOption(id: 5, shortName: "四"),
        WeekdayOption(id: 6, shortName: "五"),
        WeekdayOption(id: 7, shortName: "六"),
        WeekdayOption(id: 1, shortName: "日")
    ]
}
