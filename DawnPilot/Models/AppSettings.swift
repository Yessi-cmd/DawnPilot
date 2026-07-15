import Foundation

struct ClockTime: Codable, Equatable, Hashable, Sendable {
    var hour: Int
    var minute: Int

    init(hour: Int, minute: Int) {
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
    }

    init(date: Date, calendar: Calendar = .current) {
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

    func pickerDate(calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: Date())
        return calendar.date(byAdding: .minute, value: minutesFromMidnight, to: start) ?? start
    }

    func date(on day: Date, calendar: Calendar) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = hour
        components.minute = minute
        components.second = 0
        return calendar.date(from: components)
    }
}

struct AppSettings: Codable, Equatable, Sendable {
    var serverBaseURL = "https://chat.laoxitv.top/dawnpilot"
    var bearerToken = ""
    var latitude = 31.2304
    var longitude = 121.4737
    var timeZoneIdentifier = "Asia/Shanghai"

    var rainyAlarmTime = ClockTime(hour: 7, minute: 50)
    var fallbackAlarmTime = ClockTime(hour: 8, minute: 0)
    var clearAlarmTime = ClockTime(hour: 8, minute: 5)

    var forecastWindowStart = ClockTime(hour: 7, minute: 0)
    var forecastWindowEnd = ClockTime(hour: 9, minute: 0)
    var precipitationProbabilityThreshold = 40

    // Calendar weekday values: Sunday = 1, Monday = 2, ... Saturday = 7.
    var enabledWeekdays: Set<Int> = [2, 3, 4, 5, 6]

    static let fallbackHorizonDays = 14
    static let maximumForecastAge: TimeInterval = 6 * 60 * 60

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        return calendar
    }

    var validationError: String? {
        guard let url = URL(string: serverBaseURL),
              let scheme = url.scheme?.lowercased(),
              (scheme == "https" || isLocalDevelopmentURL(url)) else {
            return "服务器地址必须是 HTTPS；本机调试可使用 localhost。"
        }
        guard (-90...90).contains(latitude), (-180...180).contains(longitude) else {
            return "经纬度超出有效范围。"
        }
        guard TimeZone(identifier: timeZoneIdentifier) != nil else {
            return "时区标识无效，例如 Asia/Shanghai。"
        }
        guard forecastWindowStart.minutesFromMidnight < forecastWindowEnd.minutesFromMidnight else {
            return "天气判断结束时间必须晚于开始时间。"
        }
        guard (0...100).contains(precipitationProbabilityThreshold) else {
            return "降水概率阈值必须在 0 到 100 之间。"
        }
        guard !enabledWeekdays.isEmpty else {
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
