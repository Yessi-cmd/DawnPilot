import SwiftUI

struct ConfigurationSection: View {
    let guidance: String?

    var body: some View {
        Section("配置") {
            if let guidance {
                Label("天气配置尚未完成", systemImage: "slider.horizontal.3")
                    .foregroundStyle(.orange)
                Text(guidance)
                Text("你仍然可以先授权，并创建未来 14 天的保底闹钟。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            NavigationLink(value: ContentView.Route.settings) {
                Label(
                    guidance == nil ? "地点与规则设置" : "完成地点与天气设置",
                    systemImage: "slider.horizontal.3"
                )
            }
        }
    }
}
