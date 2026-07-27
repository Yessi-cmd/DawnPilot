import Foundation

/// Which day's alarm a weather refresh should update.
struct RefreshTarget: Equatable, Sendable {
    /// Start of the target civil day in the scheduling calendar.
    let day: Date
    /// True when the refresh corrects an alarm that rings later the same day,
    /// instead of preparing tomorrow's alarm.
    let isSameDayCorrection: Bool
}

/// Chooses between tomorrow's alarm — what the nightly automation prepares — and
/// today's alarm, which an early-morning run can still correct with a much
/// shorter forecast lead time.
///
/// A same-day correction is allowed only while every possible outcome (rainy,
/// clear, fallback) and the alarm currently scheduled for today are all at least
/// `AppSettings.minimumCorrectionLead` in the future. That way a correction can
/// never move an alarm into the past, and never reschedules an alarm that is
/// about to ring.
enum RefreshTargetResolver {
    static func resolve(
        settings: AppSettings,
        scheduledTodayFireDate: Date?,
        now: Date
    ) -> RefreshTarget? {
        let calendar = settings.calendar
        let today = calendar.startOfDay(for: now)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else {
            return nil
        }

        if settings.isEnabledAlarmDay(today),
           let earliest = earliestTouchableAlarmDate(
               settings: settings,
               scheduledFireDate: scheduledTodayFireDate,
               on: today
           ),
           now.addingTimeInterval(AppSettings.minimumCorrectionLead) <= earliest {
            return RefreshTarget(day: today, isSameDayCorrection: true)
        }
        return RefreshTarget(day: tomorrow, isSameDayCorrection: false)
    }

    /// Earliest instant a refresh of `day` could schedule or cancel an alarm at.
    /// Nil when the calendar cannot represent one of the alarm times on that day,
    /// for example inside a daylight saving gap.
    static func earliestTouchableAlarmDate(
        settings: AppSettings,
        scheduledFireDate: Date?,
        on day: Date
    ) -> Date? {
        let calendar = settings.calendar
        var candidates: [Date] = []
        for time in [
            settings.rainyAlarmTime,
            settings.clearAlarmTime,
            settings.fallbackAlarmTime
        ] {
            guard let date = time.alarmDate(on: day, calendar: calendar) else {
                return nil
            }
            candidates.append(date)
        }
        if let scheduledFireDate,
           calendar.isDate(scheduledFireDate, inSameDayAs: day) {
            candidates.append(scheduledFireDate)
        }
        return candidates.min()
    }
}
