# DawnPilot 修复与 UI 优化方案（2026-07-26）

本文档来自一次全量代码审查，按优先级列出本轮要落地的修复项与 UI 优化项。
每项标注位置、方案与验证方式；复选框用于对照实施进度。
更大的结构性重构（见文末"本轮不做"）单独立项，不混入本轮。

## P0 — 用户可见的错误与死代码

### 0.1 首页两处字符串插值 bug

- [x] `DawnPilot/Views/DashboardView.swift:253`：
  `"已有 (records.count) 个未来闹钟…"` 缺少 `\`，界面字面显示 `(records.count)`。
- [x] `DawnPilot/Views/DashboardView.swift:504`：
  `"预计有雨，已提前 (advance) 分钟"` 同样缺少 `\`。

方案：补上 `\(…)` 插值（0.1 的第一处随 5.2 的守护卡片重写一并完成）。
验证：模拟器构建 + 肉眼确认文案渲染出数字。

### 0.2 删除五个无引用的死视图

- [x] `DawnPilot/Views/NextAlarmSection.swift`（80 行）
- [x] `DawnPilot/Views/RefreshStatusSection.swift`（124 行）
- [x] `DawnPilot/Views/AlarmActionsSection.swift`（31 行）
- [x] `DawnPilot/Views/ConfigurationSection.swift`（25 行）
- [x] `DawnPilot/Views/AutomationGuideSection.swift`（15 行）

背景：`ec23388`（重做天气仪表盘）之后这五个视图不再被任何代码引用，
属于旧版 Form 界面的残留。`OperationFeedbackSection` 仍被 `SettingsView`
使用，保留。

方案：删除文件后运行 `xcodegen generate` 重新生成工程（文件清单变化）。
验证：全局 grep 无引用；模拟器构建通过。

## P1 — 正确性与 API 卫生

### 1.1 AlarmCoordinator 公开操作端到端串行化（本轮最重要的正确性修复）

- [x] `DawnPilot/Services/AlarmCoordinator.swift`

问题：进入 `AlarmCoordinator.shared` 的入口有三个——UI（`AppModel`，仅用
`isWorking` 挡住 UI 自己发起的操作）、快捷指令 App Intent、BGTask 后台刷新。
Swift actor 是可重入的：每个 `await alarmDriver.…` 都是让出点。具体场景：
每晚 22:30 自动化触发 `refreshTomorrow` 期间用户打开 App，`scenePhase`
变化触发 `loadSnapshot()`（`AppModel.isWorking` 对 Intent 一无所知），
`snapshot()` 里的 `reconcileSystemState` 会把 Intent 正在写的 in-flight
事务日志当成崩溃残留去 `recover()` / 回滚——可能取消对方刚排的闹钟、
清掉对方的日志，至少会产生"存在尚未恢复的事务"这类虚假错误。

方案：

1. 在 actor 内加一个 FIFO 串行队列：`operationTail: Task<Void, Never>?`，
   新操作链到上一个操作之后（创建链节点的读-建-写全程无 `await`，
   对可重入是原子的）。
2. 通过 `withTaskCancellationHandler` 把调用方取消转发给队列内任务，
   保持 BGTask 到期取消 `refreshTomorrow` 的现有语义。
3. `snapshot` / `authorizeAndPrepare` / `rebuildFallbacks` / `refreshTomorrow`
   四个公开方法改为薄包装，原实现改名为私有 `perform*`。
   四者互不调用（已核对内部调用图），无自嵌套死锁风险。

验证：全部既有协调器测试通过（语义不变：单入口顺序调用行为一致）；
构建通过（Swift 6 strict concurrency）。

### 1.2 授权状态用枚举传递，不再比较中文字符串

- [x] `DawnPilot/Services/AlarmCoordinator.swift`（`CoordinatorSnapshot`）
- [x] `DawnPilot/AppModel.swift:34`（`isAuthorized`）

问题：`isAuthorized` 靠 `authorizationText == "已授权"` 判断，改文案即破坏逻辑。

方案：`CoordinatorSnapshot.authorizationText: String` 改为
`authorization: AlarmAuthorization`；文案映射移入 `AppModel`
（未加载时显示"读取中"）；`DashboardStatusCard` 的颜色判断改用布尔参数。
验证：grep 确认无字符串比较残留；测试与构建通过。

### 1.3 天气校验去重

- [x] `DawnPilot/Services/WeatherService.swift:89`

问题：`fetchForecast` 内部与 `refreshTomorrow`（`AlarmCoordinator.swift:283`）
各调用一次 `WeatherService.validate`，且前者用不可注入的 `.now`。

方案：删除 `fetchForecast` 内部那次，保留协调器一侧（时钟可注入、对
mock 数据同样生效）。`fetchForecast` 的契约改为"解码后的原始预报，由调用方校验"。
验证：协议测试（直接调用静态 `validate`）不受影响；协调器测试通过。

### 1.4 无意义的 LazyVStack

- [x] `DawnPilot/Views/DashboardView.swift:16`

五张卡片用 `LazyVStack` 没有收益，改为 `VStack`。

## P2 — 服务端与工程卫生

### 2.1 单航班等待超时与客户端超时对齐

- [x] `server/dawnpilot_server.py:230`：等待者超时
  `max(timeout*2+5, 10)`（默认 35s）超过 iOS 客户端 20s 超时，等到答案时
  客户端早已放弃。改为 `timeout + 5`（默认 20s）。
- [x] `DawnPilot/Services/WeatherService.swift:68`：客户端
  `timeoutInterval` 20s → 30s（夜间后台场景对延迟不敏感，给拥有者路径
  留出余量）。

验证：Python 全部测试通过（现有测试不锁定该常量）。

### 2.2 .env.example 澄清防篡改固定项

- [x] `server/.env.example`

说明：`DAWNPILOT_BIND` / `DAWNPILOT_PORT` 被 `from_environment` 强制为
`127.0.0.1:8787`，改动即拒绝启动——这是被测试锁定的防篡改设计
（`test_rejects_non_loopback_or_nonstandard_port`），**保留不动**；
仅在 `.env.example` 加注释说明"固定值，修改会导致服务拒绝启动"，
消除"看似可配置"的误导。

### 2.3 新增服务端 CI

- [x] `.github/workflows/server-tests.yml`

在 ubuntu 上跑 `python3 -m unittest discover -s server/tests -v`。
服务端零依赖，CI 成本约十几秒。iOS 侧 CI 需要 Xcode 26.2 的 macOS
runner，本轮不加（见"本轮不做"）。

### 2.4 清理工作区构建垃圾

- [x] 删除 6 个本地 `DerivedData*` 目录（约 600MB，git 已忽略；
  AGENTS.md 要求 DerivedData 用 /tmp 路径）。`build/DawnPilot.ipa`
  是 canonical 工件，保留。

## UI 优化（保持现有天气场景 + 玻璃视觉语言）

### 5.1 主视觉增加响铃倒计时

- [x] `AlarmHeroView`：大字时间下方增加"X 小时 Y 分钟后响铃"，
  用 `TimelineView(.periodic(by: 60))` 每分钟刷新；不足 1 分钟显示
  "即将响铃"，超过一天显示"X 天 X 小时后"。时间计算全部走
  `settings.calendar`（遵守 AGENTS 的时区不变式）。

### 5.2 守护卡片内嵌"未来闹钟"一览

- [x] `DashboardProtectionCard`：在守护状态行下方内嵌横向滑动条，
  展示最近 7 条未来闹钟（星期 · 日期 · 时间 · 类型图标：雨天蓝 /
  晴天橙 / 保底灰）。数据来自既有 `model.records`，无新增状态。
  顺带重写第 253 行文案，完成 0.1 的第一处修复。

### 5.3 标题栏位置提示

- [x] `DashboardHeaderView`：使用示例坐标且未确认时，副标题改为橙色
  "示例位置 · 尚未确认"，引导用户进设置页；正常状态维持"固定天气位置"。

## 本轮不做（单独立项）

1. **用幂等对账替换事务日志体系**：以 AlarmKit 实际状态为唯一真相 +
   "先排新、验证后撤旧" + 启动全量对账，可删除 `PendingAlarmReplacement`
   / `PendingBulkAlarmRebuild` 全套机制（估计 -1500 行）。改动面大、
   需要完整迁移设计（老日志的一次性消化路径），不与本轮混合。
2. **凭据信封简化**：token 按 server origin 作为 Keychain key 存储，
   消除跨存储两阶段提交。依赖 1 的迁移窗口，一并做。
3. **iOS CI**：需确认 GitHub macOS runner 的 Xcode 26.2 可用性后再加。
4. **协调器测试拆分与并发交错测试**：`WeatherProtocolTests.swift` 应拆出
   `AlarmCoordinatorTests`；用可控 mock driver 在 await 点注入并发调用。
   1.1 落地后风险已大幅降低，拆分随重构一起做。

## 验证阶梯（本轮全部执行）

```bash
xcodegen generate
xcodebuild -project DawnPilot.xcodeproj -scheme DawnPilot \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/DawnPilot-Simulator-DerivedData \
  build CODE_SIGNING_ALLOWED=NO
xcodebuild test -project DawnPilot.xcodeproj -scheme DawnPilot \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /tmp/DawnPilot-Tests-DerivedData \
  CODE_SIGNING_ALLOWED=NO
python3 -m unittest discover -s server/tests -v
```

## 验证记录（2026-07-26）

- Swift 测试：iPhone 17 Pro 模拟器 65/65 通过（含全部协调器恢复场景）。
- Python 测试：30/30 通过。
- 模拟器构建、`xcodegen generate` 均通过；工程文件已随死视图删除重新生成。
- 模拟器实机截图确认：标题栏"示例位置 · 尚未确认"橙色提示（5.3）、
  主视觉空状态、守护卡片按"未来记录"计数（过期幽灵记录不再误计入）。
- 视图层在测试跑完后仅追加了一处修正（守护卡片改按未来记录计数），
  为纯视图改动，以增量构建验证。

### 验证中发现的环境边界（非本轮代码问题）

1. `CODE_SIGNING_ALLOWED=NO` 的无签名模拟器构建缺少
   application-identifier entitlement，**Keychain 全部调用失败**
   （"A required entitlement isn't present"），首启动必然进入
   设置恢复模式。手动验收 UI 请用 Xcode 正常（签名）运行；
   AltStore 重签后的真机版本不受影响。
2. 模拟器 cfprefsd 会把旧开发会话缓存的 defaults 域回写进
   重装后的新容器（本次复活了一条旧预览 fixture 记录）。
   App 的保守恢复行为处理正确；如需干净首装状态，请关机后
   删除容器 plist 或 erase 模拟器。
3. 倒计时与未来闹钟条需要已授权、有记录的状态才可见，
   属于遗留的 Xcode 签名运行 / 真机验收项。
