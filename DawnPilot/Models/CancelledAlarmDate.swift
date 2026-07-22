import Foundation

struct CancelledAlarmDate: Codable, Equatable, Identifiable, Sendable {
    var id: String { dateKey }

    let dateKey: String
    let cancelledAt: Date

    func dateDescription(calendar: Calendar) -> String {
        guard let date = LocalDateKey.date(from: dateKey, calendar: calendar) else {
            return dateKey
        }

        let components = calendar.dateComponents([.month, .day, .weekday], from: date)
        let weekdayNames = ["星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"]
        let weekdayIndex = max(1, min(7, components.weekday ?? 1)) - 1
        return "\(components.month ?? 0)月\(components.day ?? 0)日 · \(weekdayNames[weekdayIndex])"
    }
}
