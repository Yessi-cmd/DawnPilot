import SwiftUI

struct AutomationGuideSection: View {
    var body: some View {
        Section("每晚自动更新") {
            Label("在快捷指令中创建“时间”个人自动化", systemImage: "1.circle")
            Label("建议设置为每天 22:30", systemImage: "2.circle")
            Label("选择“立即运行”，并关闭运行前询问", systemImage: "3.circle")
            Label("添加“更新明日闹钟”动作", systemImage: "4.circle")
            Text("系统后台刷新只会额外尝试；每晚自动化仍是主要更新方式。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
