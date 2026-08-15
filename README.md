# DawnPilot 晨航

面向 iOS 26 的个人通勤起床闹钟。DawnPilot（晨航）使用 AlarmKit 安排系统级闹钟，
根据 VPS 返回的明日小时天气，在本地选择“有降水”“无降水”或“保底”时间。

当前是可运行的 MVP，默认规则为：

- 明显降水（≥0.5mm）：07:50
- 零星小雨、拿不准，或天气/自动化不可用：08:00
- 无降水：08:05
- 判断窗口：07:00–09:00
- 降水概率阈值：25%
- 周一至周五启用

阈值同时作用于两种“雨”的定义：达到该概率的**明显降水**（≥0.5mm）走雨天时间；
只达到该概率的**零星降水**（≥0.1mm）走折中的保底时间；两者都不到才是晴天时间。
阈值刻意低于 50%——两个闹钟只差 15 分钟，而下雨天晚起的代价明显高于白早起，
临界点应落在两种错误期望代价相等处（约等于"被雨堵一次"相当于"白早起三次"）。

以上内容均可在 App 中修改。固定地点默认只是上海示例坐标；安装后请改成
自己的通勤地点，或在确认确实适用时显式确认该示例位置。

## 工作方式

1. Debian VPS 从 Open-Meteo 获取三天小时预报，并缓存已访问的固定地点。
2. iPhone 通过“快捷指令”个人自动化运行 App Intent：每晚 22:30 安排明天的闹钟，
   每天 07:00 再用更新的预报校准今天的闹钟。
3. App 从 VPS 读取天气，在本地执行用户规则并替换目标日期的 AlarmKit 闹钟。
4. App 预先创建未来 14 天的一次性保底闹钟；天气更新失败不会造成完全无闹钟。
5. iOS 后台刷新会做额外尝试，但不作为可靠性的唯一来源。

首页的“管理闹钟”可以逐条删除未来闹钟，也支持进入选择模式后一次删除多条。
删除日期会保留到当天结束，因此夜间或清晨自动化不会把用户明确删除的闹钟重新创建。
管理页会列出所有已删除日期，可逐个恢复；首页的“修复保底”则会一次恢复全部删除日期。

同一个 App Intent 自己判断该更新哪一天：只要今天是启用的闹钟日，且当天所有可能
的闹钟时间（雨天／晴天／保底）和已安排的闹钟都还有至少 15 分钟，就校准今天；否则
安排明天。清晨校准把预报提前量从约 10 小时压到约 1 小时，这通常比更换数据源更有效。
距离响铃不足 15 分钟时，刷新绝不会再改动当天闹钟。

清晨校准可以随时把闹钟**提前**；要把闹钟**推迟**，新判定必须是"无降水"。落在
"零星小雨／拿不准"档时保留当天已安排的更早闹钟——推迟是有风险的方向，只有在
有把握时才做。

AlarmKit 的闹钟可以穿透静音和专注模式。Apple 官方文档说明，响铃界面会转发给
已配对的 Apple Watch；它不是在手表“时钟”App 中创建一条独立闹钟。

## 工程要求

- Xcode 26.2 或更高版本
- iOS 26.0 或更高版本
- XcodeGen 2.44 或兼容版本
- AltStore / AltServer 自签环境
- 一台提供 HTTPS 域名的 Debian 12 VPS

本工程沿用相邻 `flashcount` 项目的 XcodeGen 与 development IPA 导出方式。
Release team ID 当前也是 `66WCCRKRLC`；如果你的实际签名团队发生变化，同时修改
`project.yml` 和 `Config/ExportOptions.plist`。

## 生成与验证 iOS 工程

```bash
xcodegen generate
xcodebuild \
  -project DawnPilot.xcodeproj \
  -scheme DawnPilot \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  build CODE_SIGNING_ALLOWED=NO
```

运行规则测试：

```bash
xcodebuild test \
  -project DawnPilot.xcodeproj \
  -scheme DawnPilot \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=NO
```

## 导出 AltStore IPA

```bash
./scripts/package-altstore.sh
```

脚本会全新编译未签名的 arm64 Release 真机版本，检查 IPA 结构并生成
`build/DawnPilot.ipa`。该文件不包含 provisioning profile 或开发签名，交给
AltStore 安装时使用你的 Apple ID 重签。构建产物和 DerivedData 均已从 Git 排除。
如果 canonical IPA 已存在，新 build number 必须严格递增；只有在明确批准替换后，
才可临时设置 `DAWNPILOT_ALLOW_NONINCREASING_BUILD=true` 覆盖这项保护。

## 首次安装

1. 按 [VPS 部署说明](server/README.md)部署服务，并准备 HTTPS 地址和随机令牌。
2. App 已预填当前服务地址；在“地点与规则设置”中填写令牌、固定经纬度和时区。
3. 点“授权并创建 14 天保底闹钟”，同意 AlarmKit 权限。
4. 点“立即更新明日闹钟”，确认天气链路工作正常。
5. 打开“快捷指令”→“自动化”，创建每天 22:30 的时间自动化。
6. 添加“更新起床闹钟”动作，选择立即运行，并关闭运行前询问。
7. 再建一条每天 07:00 的自动化，动作同样是“更新起床闹钟”，用于清晨校准。

这两条快捷指令个人自动化必须由用户手动创建；晨航无法自行在指定时间唤醒并联网。
没有它们时，系统后台刷新只会择机尝试，不能保证在 22:30 或 07:00 获取天气。

## 服务端

服务端只使用 Python 3 标准库，默认占用很低，适合 1 CPU / 1 GB VPS。它提供：

- `GET /healthz`：健康状态，无需令牌。
- `GET /v1/forecast`：规范化小时预报，需要 Bearer Token。
- 降水概率来自集成预报：并行请求 Open-Meteo 集成 API 的 ECMWF-IFS、ICON 和
  GEFS 三套模式（共约 119 个成员），每小时概率取“达到 0.1 mm 的成员占比”。
  降水量和 WMO 天气代码仍取确定性预报。集成请求失败时自动退回确定性概率，
  并在 `probability_source` 字段中标明，不会因此丢失预报。
- 最多缓存 32 个最近使用地点，15 分钟请求缓存与 30 分钟后台刷新。
- 过期数据会立即以 `stale: true` 返回，并在后台做单航班刷新和失败退避。
- 只有字段完整、时间有序且数值有效的 Forecast v1 数据才会替换最后成功缓存。

部署、systemd 与 Caddy 示例见 [server/README.md](server/README.md)。

## 已知边界

- 只使用 Open-Meteo（确定性 + 集成两套接口），没有接入彩云天气或中国雷达临近预报。
- 集成概率比原来的单一集成字段在尾部更有分辨率，因此同一个 40% 阈值会比以前
  更容易被触发；这偏向“提前起”，如需回到原来的触发频率应调高阈值。
- 固定地点由用户输入经纬度，不含地址搜索和实时定位。
- 默认只按星期判断，不识别中国法定节假日、补班或请假。
- AltStore 自签环境不使用 APNs；快捷指令和 iOS 后台任务仍无法提供数学意义上的
  100% 定时执行保证，因此保底闹钟是必要设计。
- AlarmKit 真机授权、静音/专注穿透和 Apple Watch 转发需要在实体 iPhone 上验收；
  模拟器只能验证构建、界面和业务规则。
