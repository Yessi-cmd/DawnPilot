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

    static func scheduleNext() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date.now.addingTimeInterval(6 * 60 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Shortcut automation remains the primary trigger. Background refresh is best effort.
        }
    }

    private static func handle(_ task: BGAppRefreshTask) {
        scheduleNext()
        let session = BackgroundTaskSession(task: task)
        let operation = Task {
            do {
                try Task.checkCancellation()
                let settings = SettingsStore.loadSettings()
                _ = try await AlarmCoordinator.shared.refreshTomorrow(settings: settings)
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
