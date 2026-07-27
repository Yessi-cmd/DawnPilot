@preconcurrency import BackgroundTasks
import Foundation

enum BackgroundRefreshController {
    static let identifier = "com.yessicmd.dawnpilot.refresh"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(refreshTask)
        }
    }

    static let periodicInterval: TimeInterval = 6 * 60 * 60

    static func scheduleNext() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = preferredBeginDate(
            settings: SettingsStore.loadSettings(),
            now: .now
        )
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Shortcut automation remains the primary trigger. Background refresh is best effort.
        }
    }

    /// Aims the next opportunistic wake-up at the window shortly before the
    /// earliest alarm that a morning correction could still move, and never later
    /// than the periodic interval. iOS decides whether and when this actually runs;
    /// the Shortcuts automations remain the reliable trigger.
    static func preferredBeginDate(settings: AppSettings, now: Date) -> Date {
        let periodic = now.addingTimeInterval(periodicInterval)
        let calendar = settings.calendar
        let today = calendar.startOfDay(for: now)
        let earliestUsefulWake = now.addingTimeInterval(AppSettings.minimumCorrectionLead)

        for dayOffset in 0...1 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: today),
                  settings.isEnabledAlarmDay(day),
                  let earliestAlarm = RefreshTargetResolver.earliestTouchableAlarmDate(
                      settings: settings,
                      scheduledFireDate: nil,
                      on: day
                  ) else {
                continue
            }
            let wake = earliestAlarm.addingTimeInterval(-AppSettings.correctionLookahead)
            guard wake >= earliestUsefulWake else { continue }
            return min(wake, periodic)
        }
        return periodic
    }

    private static func handle(_ task: BGAppRefreshTask) {
        scheduleNext()
        let session = BackgroundTaskSession(task: task)
        let operation = Task {
            do {
                try Task.checkCancellation()
                let settings = SettingsStore.loadSettings()
                _ = try await AlarmCoordinator.shared.refreshUpcoming(settings: settings)
                try Task.checkCancellation()
                session.complete(success: true)
            } catch {
                session.complete(success: false)
            }
        }
        session.installExpirationHandler(operation: operation)
    }
}

// BGTask is not declared Sendable, but Apple invokes its expiration and completion
// APIs across scheduler queues. This narrow wrapper serializes ownership and makes
// setTaskCompleted exactly-once; no raw BGTask escapes into a Swift Task closure.
private final class BackgroundTaskSession: @unchecked Sendable {
    private let task: BGAppRefreshTask
    private let lock = NSLock()
    private var isCompleted = false

    init(task: BGAppRefreshTask) {
        self.task = task
    }

    func installExpirationHandler(operation: Task<Void, Never>) {
        lock.lock()
        if isCompleted {
            lock.unlock()
            operation.cancel()
            return
        }
        task.expirationHandler = { [weak self] in
            operation.cancel()
            self?.complete(success: false)
        }
        lock.unlock()
    }

    func complete(success: Bool) {
        lock.lock()
        guard !isCompleted else {
            lock.unlock()
            return
        }
        isCompleted = true
        lock.unlock()

        task.expirationHandler = nil
        task.setTaskCompleted(success: success)
    }
}
