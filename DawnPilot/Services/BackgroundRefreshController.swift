import BackgroundTasks
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

    static func scheduleNext() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 6 * 60 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Shortcut automation remains the primary trigger. Background refresh is best effort.
        }
    }

    private static func handle(_ task: BGAppRefreshTask) {
        scheduleNext()
        let operation = Task {
            do {
                let settings = SettingsStore.loadSettings()
                _ = try await AlarmCoordinator.shared.refreshTomorrow(settings: settings)
                task.setTaskCompleted(success: true)
            } catch {
                task.setTaskCompleted(success: false)
            }
        }
        task.expirationHandler = {
            operation.cancel()
        }
    }
}
