# 快速开始

[English](../en/getting-started.md)

本指南先建立局域网链路，再按需启用 Tailscale。仓库当前的个人构建是仅私有网络版，不开放公网路径。这样可以先验证 Apple 签名、系统权限、配对和按键映射，再引入私有网络配置。

## 组件

- Apple Watch App：显示任务状态、遥控按钮、收藏和语音入口，并在本地识别单击、双击与长按。
- iPhone 伴侣 App：管理 12 个按键的 36 个映射槽，并承接 WatchConnectivity 与局域网连接。
- Mac Bridge：执行经批准的键盘、媒体和 App 动作，只对前台听写使用系统语音识别，并提供使用已登录账号联网转写的可选 Codex 语音集成。
- Tailscale 私有网络：可选的 iPhone 到 Mac 备用链路，仅在开发者自己的 tailnet 内可达。
- 公网 Relay：当前仅私有网络构建通过 `WRISTREMOTE_PRIVATE_ONLY = YES` 和独立 `.invalid` endpoint 门禁同时禁用。

## 系统要求

- macOS 13、iOS 17、watchOS 10 或更新版本。
- 完整版 Xcode、Swift、XcodeGen、Git、ripgrep、Node.js 24 或更新版本，以及 npm。
- 真机安装需要开发者自己的 Apple Developer Team、已开启开发者模式且可被 Xcode 识别的 iPhone 和 Apple Watch。
- Homebrew 不是运行时依赖；如果缺少 XcodeGen，`make setup` 仅在检测到 Homebrew 时尝试安装。
- Tailscale 模式还要求已配对 iPhone 与 Mac 加入同一个 tailnet；Watch 本身不加入。
- 仅私有网络构建不需要 Cloudflare 账号或公网服务。

## 1. 准备工程

先从当前 GitHub 仓库页面复制 HTTPS 或 SSH Clone 地址，再执行：

```bash
git clone REPLACE_WITH_REPOSITORY_CLONE_URL
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
WRISTREMOTE_PRIVATE_ONLY = YES
WRISTREMOTE_RELAY_BASE_URL = https:/$()/relay.example.invalid
WRISTREMOTE_CODEX_EXECUTABLE_PATH =
```

把 Bundle 前缀换成自己控制的唯一反向域名，并填写自己的 10 位 Team ID。LAN/Tailscale 使用时保持两道仅私有网络门禁不变；只改任意一项都不能启用公网路径。不要提交此文件。

## 3. 安装 Mac Bridge

```bash
make install-mac
```

默认安装位置是当前用户的 `Applications` 目录。若已有同名 App，脚本会先移动为带时间戳的备份。若本机恰好存在一个有效 `Apple Development` 身份，脚本会自动使用它，使重复安装保持稳定签名；完全不存在时才回退 ad-hoc；存在多个时拒绝猜测，此时需通过单次环境变量 `WRIST_CODESIGN_IDENTITY` 精确指定一个有效身份。脚本不会打印或持久化身份细节。该安装方式适合本机开发，不等同于 Developer ID 公证发行包。

如需在其他位置受控就地升级，可执行 `scripts/build-macos.sh --install --target-app /absolute/path/WristRemoteBridge.app`。目标必须是非符号链接的绝对 `.app` 路径，且 Bundle ID 必须与已验证构建一致。若目标历史 Bridge 使用经确认的不同 Bundle ID，请先在已忽略的 `Config/Local.xcconfig` 设置 `WRISTREMOTE_BRIDGE_BUNDLE_IDENTIFIER` 再构建。只要任何 `WristRemoteBridge` 进程仍在运行，或无法解析到精确 App 路径，安装就会拒绝继续；脚本不会自动结束 App。请正常退出所有 Bridge 后重试。详见[配置参考](configuration.md#mac-bridge-受控升级)。

首次打开后，按功能授予：

- 本地网络：发现和接受局域网伴侣连接。
- 辅助功能：执行键盘、媒体和 App 聚焦动作。
- 语音识别：只用于普通前台听写；Codex 联网语音转写不使用该权限。

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

脚本只会自动选择唯一可用的 iPhone、Apple Watch 和 Apple Development 身份。Xcode 方面优先使用 `xcode-select` 指向的完整稳定版；若它不合格，再选已安装的最高稳定版。Beta、RC、Preview、Seed 和其他预发布版不会被自动选中；仅在明确知道要使用预发布版时，才对当前命令设置 `WRIST_DEVELOPER_DIR`。若设备或签名候选不唯一，脚本会停止；可只为当前命令设置 `WRIST_TEAM_ID`、`WRIST_IPHONE_UDID` 或 `WRIST_WATCH_UDID`。这些值不会写入仓库，输出也不回显设备标识符。

默认配置用于首次安装。若要保留已经安装的 iPhone/Watch App、Keychain 与配对状态，不能只更换 Bundle 前缀；请按[受控原位升级](configuration.md#iphone-与-watch-受控原位升级)同时设置两个经核实的精确 Bundle ID，并启用现装身份门禁。`--dry-run` 会只读核对当前 Team、历史描述文件和两台真机的现装身份；任一设备不可读、缺少原 App 或存在同名不同身份都会停止。

Apple 登录、设备信任、开发者模式、麦克风、辅助功能和语音识别提示必须由用户确认，脚本不会绕过系统安全机制。

## 5. 首次配对和映射

1. 打开 Mac Bridge、iPhone App 和 Watch App。
2. iPhone 发现 `_wristremote._tcp` 服务后发起连接。
3. 比较两端显示的六位配对码，只在一致时批准。
4. 在 Mac Bridge 中添加允许启动的 App。
5. 在 iPhone 上配置收藏，以及每个按键的单击、双击和长按。
6. 在 Watch 上测试方向、确定、返回、主页、菜单、TV、音量和电源按钮的映射。
7. 测试震动反馈和两条隔离语音路径：普通前台听写完成后应立即注入当前焦点输入框。Codex 语音需要互联网和已登录的 Codex 账号：第一方转写返回文字，再排入精确 existing 目标，不使用 macOS Speech 或剪贴板。确认队列回执；它不等于任务完成。
8. 创建一个“新建任务”，确认独立 `thread/start` 完成后才能录音。中断一次录音，确认部分音频被删除且重连后不会补发。

## 6. 可选功能

- [配置 Tailscale 私有网络](tailscale-private-network.md)
- [连接 Codex 任务 Hook](codex-integration.md)
- [配置参考](configuration.md)
- [故障排查](troubleshooting.md)

## 验收边界

`make test` 和 `make build` 证明协议、业务逻辑和无签名构建通过，但不能代替真机配对、系统权限、Watch 震动、前台中文识别、Codex 转写与任务投递、逐包 Mac 回执、网络切换和实际动作执行。发布前使用[发布检查表](release-checklist.md)完成这些手工门禁。
