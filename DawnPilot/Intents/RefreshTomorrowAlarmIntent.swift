import AppIntents

struct RefreshTomorrowAlarmIntent: AppIntent {
    static var title: LocalizedStringResource = "更新明日闹钟"
    static var description = IntentDescription("获取天气并更新明天的通勤起床闹钟。")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let settings = SettingsStore.loadSettings()
        let status = try await AlarmCoordinator.shared.refreshTomorrow(settings: settings)
        return .result(dialog: IntentDialog(stringLiteral: status.message))
    }
}

struct DawnPilotShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RefreshTomorrowAlarmIntent(),
            phrases: [
                "用 \(.applicationName) 更新明日闹钟",
                "更新 \(.applicationName) 的明日闹钟"
            ],
            shortTitle: "更新明日闹钟",
            systemImageName: "cloud.rain"
        )
    }

    static var shortcutTileColor: ShortcutTileColor = .purple
}
