import Foundation

enum AlarmDateSchedulingDecision: Equatable, Sendable {
    case schedule
    case disabledDay
    case userCancelled
}

enum AlarmDateSchedulingPolicy {
    static func decision(
        dateKey: String,
        isEnabledAlarmDay: Bool,
        cancelledDateKeys: Set<String>
    ) -> AlarmDateSchedulingDecision {
        if cancelledDateKeys.contains(dateKey) {
            return .userCancelled
        }
        return isEnabledAlarmDay ? .schedule : .disabledDay
    }
}

enum LocalDateKey {
    static func make(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    static func date(from value: String, calendar: Calendar) -> Date? {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            return nil
        }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return calendar.date(from: components)
    }
}
