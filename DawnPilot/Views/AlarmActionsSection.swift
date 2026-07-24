import SwiftUI

struct AlarmActionsSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Section {
            Button(
                model.isAuthorized ? "修复 14 天保底闹钟" : "授权并创建 14 天保底闹钟",
                systemImage: "alarm.waves.left.and.right",
                action: model.authorizeAndPrepare
            )
            .disabled(model.isWorking)

            Button(
                "立即更新明日闹钟",
                systemImage: "arrow.clockwise",
                action: model.refreshNow
            )
            .disabled(model.isWorking)

            if model.isWorking {
                ProgressView(model.operationPhase.message)
            }
        } footer: {
            if model.needsWeatherConfiguration {
                Text("保底闹钟不依赖天气；立即更新会引导你先完成天气配置。")
            }
        }
    }
}
