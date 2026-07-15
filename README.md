# DawnPilot 晨航

面向 iOS 26 的个人通勤起床闹钟。DawnPilot（晨航）使用 AlarmKit 安排系统级闹钟，
根据 VPS 返回的明日小时天气，在本地选择“有降水”“无降水”或“保底”时间。

当前是可运行的 MVP，默认规则为：

- 有降水：07:50
- 天气或自动化不可用：08:00
- 无降水：08:05
- 判断窗口：07:00–09:00
- 降水概率阈值：40%
- 周一至周五启用

以上内容均可在 App 中修改。固定地点默认只是上海示例坐标，安装后必须改成
自己的通勤地点。

## 工作方式

1. Debian VPS 从 Open-Meteo 获取三天小时预报，并缓存已访问的固定地点。
2. iPhone 每晚通过“快捷指令”个人自动化运行 App Intent。
3. App 从 VPS 读取天气，在本地执行用户规则并替换明天的 AlarmKit 闹钟。
4. App 预先创建未来 14 天的一次性保底闹钟；天气更新失败不会造成完全无闹钟。
5. iOS 后台刷新会做额外尝试，但不作为可靠性的唯一来源。

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
xcodegen generate
xcodebuild archive \
  -project DawnPilot.xcodeproj \
  -scheme DawnPilot \
  -configuration Release \
  -archivePath build/DawnPilot.xcarchive

xcodebuild -exportArchive \
  -archivePath build/DawnPilot.xcarchive \
  -exportPath build \
  -exportOptionsPlist Config/ExportOptions.plist
```

生成的 `build/DawnPilot.ipa` 可交给 AltStore 安装。构建产物和 DerivedData 均已
从 Git 排除。

## 首次安装

1. 按 [VPS 部署说明](server/README.md)部署服务，并准备 HTTPS 地址和随机令牌。
2. App 已预填当前服务地址；在“地点与规则设置”中填写令牌、固定经纬度和时区。
3. 点“授权并创建保底闹钟”，同意 AlarmKit 权限。
4. 点“立即更新明日闹钟”，确认天气链路工作正常。
5. 打开“快捷指令”→“自动化”，创建每天 22:30 的时间自动化。
6. 添加“更新明日闹钟”动作，选择立即运行，并关闭运行前询问。

## 服务端

服务端只使用 Python 3 标准库，默认占用很低，适合 1 CPU / 1 GB VPS。它提供：

- `GET /healthz`：健康状态，无需令牌。
- `GET /v1/forecast`：规范化小时预报，需要 Bearer Token。
- 15 分钟请求缓存与 30 分钟后台刷新。
- 上游失败时返回持久化的最后一份成功数据，并标记 `stale: true`。

部署、systemd 与 Caddy 示例见 [server/README.md](server/README.md)。

## 已知边界

- 第一版使用 Open-Meteo，没有接入彩云天气或多来源投票。
- 固定地点由用户输入经纬度，不含地址搜索和实时定位。
- 默认只按星期判断，不识别中国法定节假日、补班或请假。
- AltStore 自签环境不使用 APNs；快捷指令和 iOS 后台任务仍无法提供数学意义上的
  100% 定时执行保证，因此保底闹钟是必要设计。
- AlarmKit 真机授权、静音/专注穿透和 Apple Watch 转发需要在实体 iPhone 上验收；
  模拟器只能验证构建、界面和业务规则。
