import AppIntents

// The type name is this intent's App Intents identity. Automations the user has
// already created keep referring to it, so it stays stable even though the intent
// now updates whichever alarm weather can still decide.
struct RefreshTomorrowAlarmIntent: AppIntent {
    static let title: LocalizedStringResource = "更新起床闹钟"
    static let description = IntentDescription(
        """
        获取天气并更新下一个通勤起床闹钟：夜间运行时安排明天的闹钟，\
        清晨在响铃前运行时用更新的天气校准今天的闹钟。
        """
    )
    static let supportedModes: IntentModes = .background

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let settings = SettingsStore.loadSettings()
        let status = try await AlarmCoordinator.shared.refreshUpcoming(settings: settings)
        return .result(dialog: IntentDialog(stringLiteral: status.message))
    }
}

struct DawnPilotShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RefreshTomorrowAlarmIntent(),
            phrases: [
                "用 \(.applicationName) 更新起床闹钟",
                "用 \(.applicationName) 更新明日闹钟",
                "更新 \(.applicationName) 的明日闹钟"
            ],
            shortTitle: "更新起床闹钟",
            systemImageName: "cloud.rain"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .purple
}
