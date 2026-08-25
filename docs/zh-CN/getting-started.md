# 快速开始

[English](../en/getting-started.md)

本指南先建立局域网链路，再按需启用互联网 Relay。这样可以先验证 Apple 签名、系统权限、配对和按键映射，而不必一开始就引入公网依赖。

## 组件

- Apple Watch App：显示任务状态、遥控按钮、收藏和语音入口，并在本地识别单击、双击与长按。
- iPhone 伴侣 App：管理 12 个按键的 36 个映射槽，并承接 WatchConnectivity 与局域网连接。
- Mac Bridge：执行经批准的键盘、媒体和 App 动作，完成语音识别，并提供可选的 Codex 本地集成。
- Cloudflare Relay：可选的单房间密文中继。它由每位开发者部署到自己的 Cloudflare 账号。

## 系统要求

- macOS 13、iOS 17、watchOS 10 或更新版本。
- 完整版 Xcode、Swift、XcodeGen、Git、ripgrep、Node.js 24 或更新版本，以及 npm。
- 真机安装需要开发者自己的 Apple Developer Team、已开启开发者模式且可被 Xcode 识别的 iPhone 和 Apple Watch。
- Homebrew 不是运行时依赖；如果缺少 XcodeGen，`make setup` 仅在检测到 Homebrew 时尝试安装。
- 外网模式额外需要开发者自己的 Cloudflare 账号与 Wrangler 登录。

## 1. 准备工程

```bash
git clone YOUR_PRIVATE_REPOSITORY_URL wrist-remote
cd wrist-remote
make setup
make doctor
make test
```

`make setup` 会创建权限为 `0600` 且已被 Git 忽略的 `Config/Local.xcconfig`、重新生成两个 Xcode 工程，并用 `npm ci` 安装 Relay 的锁定依赖。它不会登录 Apple、注册设备、登录 Cloudflare 或创建公网服务。

## 2. 配置本地签名

编辑 `Config/Local.xcconfig`：

```xcconfig
WRISTREMOTE_BUNDLE_PREFIX = org.example.wristremote
WRISTREMOTE_DEVELOPMENT_TEAM = REPLACE_WITH_YOUR_TEAM_ID
WRISTREMOTE_RELAY_BASE_URL = https:/$()/relay.example.invalid
WRISTREMOTE_CODEX_EXECUTABLE_PATH =
```

把 Bundle 前缀换成自己控制的唯一反向域名，并填写自己的 10 位 Team ID。保留 `.invalid` Relay 地址即可使用纯局域网模式。不要提交此文件。

## 3. 安装 Mac Bridge

```bash
make install-mac
```

默认安装位置是当前用户的 `Applications` 目录。若已有同名 App，脚本会先移动为带时间戳的备份。默认使用本机 ad-hoc 签名；也可仅为本次命令设置 `WRIST_CODESIGN_IDENTITY` 使用自己的签名身份。该安装方式适合本机开发，不等同于 Developer ID 公证发行包。

首次打开后，按功能授予：

- 本地网络：发现和接受局域网伴侣连接。
- 辅助功能：执行键盘、媒体和 App 聚焦动作。
- 语音识别：把 Watch 音频转换为文本。

Mac Bridge 不需要读取其他输入设备或其他应用的偏好设置。

## 4. 安装 iPhone 与 Apple Watch App

先执行只读预检：

```bash
scripts/install-devices.command --dry-run
```

确认 Xcode 已登录、设备已解锁且开发连接正常后：

```bash
make install-devices
```

脚本只会自动选择唯一可用的 iPhone、Apple Watch 和 Apple Development 身份。若候选不唯一，它会停止；可只为当前命令设置 `WRIST_TEAM_ID`、`WRIST_IPHONE_UDID`、`WRIST_WATCH_UDID` 或 `WRIST_DEVELOPER_DIR`。这些值不会写入仓库。

Apple 登录、设备信任、开发者模式、麦克风、辅助功能和语音识别提示必须由用户确认，脚本不会绕过系统安全机制。

## 5. 首次配对和映射

1. 打开 Mac Bridge、iPhone App 和 Watch App。
2. iPhone 发现 `_wristremote._tcp` 服务后发起连接。
3. 比较两端显示的六位配对码，只在一致时批准。
4. 在 Mac Bridge 中添加允许启动的 App。
5. 在 iPhone 上配置收藏，以及每个按键的单击、双击和长按。
6. 在 Watch 上测试方向、确定、返回、主页、菜单、TV、音量和电源按钮的映射。
7. 测试震动反馈和两种语音路径：普通前台语音识别完成后应立即注入当前焦点输入框；Codex 任务语音应先显示草稿，用户确认后才提交。

## 6. 可选功能

- [部署互联网 Relay](relay-deployment.md)
- [连接 Codex 任务 Hook](codex-integration.md)
- [配置参考](configuration.md)
- [故障排查](troubleshooting.md)

## 验收边界

`make test` 和 `make build` 证明协议、业务逻辑和无签名构建通过，但不能代替真机配对、系统权限、Watch 震动、中文识别、网络切换和实际动作执行。发布前使用[发布检查表](release-checklist.md)完成这些手工门禁。
