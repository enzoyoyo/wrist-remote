# Wrist Remote

Wrist Remote 是一套以隐私和隔离为前提的 Apple Watch → macOS 遥控方案，由 Apple Watch App、iPhone 伴侣 App、Mac Bridge 和可选的自托管互联网 Relay 组成。

[English](README.en.md) · [文档目录](docs/zh-CN/getting-started.md)

## 功能

- 12 个虚拟按键，每个按键都有单击、双击、长按，共 36 个独立映射槽。
- 键盘按键、组合快捷键、音量与媒体、显示桌面、App 切换等系统动作。
- 由开发者在 Mac Bridge 中选择任意 App，再映射到手表；仓库不预置个人 App 清单。
- Apple Watch 触觉反馈、宽松按键布局、收藏按键和自动重连。
- Apple Watch 录音经 Mac 的系统 Speech Framework 进行中文转写；普通听写直接输入当前前台 App，Codex 任务回复则先形成草稿、确认后才发送。
- 可选 Codex 集成：手表首屏显示当前任务、完成状态和摘要，并可用中文语音确认回复。
- 局域网优先；可选的 Cloudflare Worker + Durable Object Relay 支持外网控制。

## 架构

```text
Apple Watch
  ├─ 局域网：WatchConnectivity → iPhone → 加密 TCP → Mac Bridge
  └─ 外网：HTTPS 端到端密文 → 你自己的 Cloudflare Relay
                                      ↓
                               Mac 主动建立 WSS 出站连接
```

Mac 不开放公网入站端口。未部署 Relay 时，默认 URL 使用保留的 `.invalid` 域名，外网功能不会意外连到作者或第三方服务。

## 系统要求

- macOS 13 或更新版本。
- iOS 17 或更新版本。
- watchOS 10 或更新版本。
- 完整版 Xcode、XcodeGen、Swift、Node.js 24+ 和 npm。
- 真机安装需要你自己的 Apple Developer Team、已开启开发者模式且与 Mac 建立开发连接的 iPhone 和 Apple Watch。
- 外网 Relay 可选，需要你自己的 Cloudflare 账号和 Wrangler 登录。

## 10 分钟快速开始

```bash
git clone YOUR_PRIVATE_REPOSITORY_URL wrist-remote
cd wrist-remote
make setup
make doctor
make test
```

`make setup` 会：

1. 检查 Xcode；缺少 XcodeGen、ripgrep 或 Gitleaks 且本机有 Homebrew 时安装对应工具。
2. 创建被 Git 忽略且权限为 `0600` 的 `Config/Local.xcconfig`。
3. 从 `project.yml` 生成两个 Xcode 工程。
4. 使用 `npm ci` 安装 Relay 的锁定依赖。

随后编辑 `Config/Local.xcconfig`：

```xcconfig
WRISTREMOTE_BUNDLE_PREFIX = org.example.wristremote
WRISTREMOTE_DEVELOPMENT_TEAM = REPLACE_WITH_YOUR_TEAM_ID
WRISTREMOTE_RELAY_BASE_URL = https:/$()/relay.example.invalid
WRISTREMOTE_CODEX_EXECUTABLE_PATH =
```

必须将 Bundle 前缀和 Team ID 换成你自己的值。不要提交这个文件。

安装 Mac Bridge：

```bash
make install-mac
```

默认安装到 `~/Applications/WristRemoteBridge.app`，本机已有同名 App 时会先移动到带时间戳的备份路径。脚本只在本机签名；仓库不会包含证书、Team ID、描述文件或已签名二进制。

真机安装：

```bash
make install-devices
```

脚本会自动选择唯一可用的 iPhone、Apple Watch 和 Apple Development 身份，临时构建、校验描述文件、安装并启动。若发现多个候选设备或 Team，会停止并要求你只为本次命令提供环境变量，避免装错设备。

Apple 登录、设备信任、开发者模式、辅助功能、麦克风和语音识别权限均必须由用户在系统界面确认，脚本不会绕过这些安全机制。

## 使用方法

1. 打开 Mac Bridge，允许本地网络、辅助功能和语音识别权限。
2. 在 iPhone 伴侣 App 中连接 Mac；首次连接会在 Mac 和 iPhone 显示六位确认码。
3. 在 iPhone 的自定义界面中调整四个收藏位置，以及每个按键的单击、双击和长按动作。
4. 如要启动自定义 App，先在 Mac Bridge 点击“添加 App…”，再在 iPhone 中选择该 App 配置。
5. Apple Watch 会优先使用可用的局域网路径；配置 Relay 后可在有网络时切换到外网路径。

## 外网 Relay（可选）

```bash
make deploy-relay
```

此命令会先执行类型检查和 21 个 Relay 测试，再部署到当前 Wrangler 登录的 Cloudflare 账号。初始化工具会：

- 在本机安全生成或复用单房间凭据。
- 将 Mac 凭据和端到端密钥写入 Keychain。
- 通过 stdin 写入 `ALLOWED_ROOM_ID` 与 `BOOTSTRAP_MAC_TOKEN` Wrangler secrets，不打印 secret 值。
- 把公开的 HTTPS Relay URL 写入被忽略的 `Config/Local.xcconfig`。
- 验证 `/healthz` 后提示重新构建三端 App。

Relay 是公网 HTTPS 服务，但你的 Mac/设备并不会被直接暴露到公网。详细威胁模型见 [docs/zh-CN/relay-deployment.md](docs/zh-CN/relay-deployment.md) 和 [THREAT_MODEL.md](THREAT_MODEL.md)。

## Codex 集成（可选）

Bridge 只监听 `127.0.0.1:60928/codex-hook`，并要求随机 Bearer Token。Token 首次启动时生成并保存到 Keychain。`scripts/codex-notify.sh` 会安全读取 Token 并把 Codex Hook 的 JSON 从 stdin 转发给 Bridge，不会把 Token 写进仓库或 shell 历史。

参照 [examples/codex-hooks.json](examples/codex-hooks.json)，把脚本路径换成你克隆仓库后的绝对路径，再合并到自己的 Codex Hook 配置中。不要覆盖已有 Hook。详见 [docs/zh-CN/codex-integration.md](docs/zh-CN/codex-integration.md)。

## 开发命令

| 命令 | 作用 |
|---|---|
| `make setup` | 准备工具、配置、Xcode 工程和 npm 依赖 |
| `make doctor` | 只读检查开发环境 |
| `make icons` | 从仓库内纯几何脚本重新生成全部 App 图标 |
| `make test` | Swift、Bridge 和 Relay 测试 |
| `make build` | 无签名构建 iOS/watchOS Simulator 与 macOS |
| `make install-mac` | 本机签名并安装 Mac Bridge |
| `make install-devices` | 用开发者自己的 Team 安装 iPhone/Watch 真机 |
| `make deploy-relay` | 部署并初始化可选私有 Relay |
| `make security` | 路径、凭据、私钥、禁止文件和 Git 历史扫描 |

开发接口与调用示例见 [docs/zh-CN/api.md](docs/zh-CN/api.md)，贡献流程见 [CONTRIBUTING.zh-CN.md](CONTRIBUTING.zh-CN.md)。

## 安全与隐私

- 设备/Mac 凭据与端到端密钥的客户端副本保留在 Apple Keychain；Cloudflare 加密的 Worker secret store 保存允许的 room ID 和 bootstrap Mac bearer，Durable Object SQLite 保存 Token 哈希、随机生成的 Relay device UUID、初始化时间及重放/限流状态。
- 指令、音频、任务摘要和回复内容在客户端与 Mac 间端到端加密。
- Relay 不存密文、不提供离线队列；Mac 离线时请求立即失败，过期动作不会补执行。
- Cloudflare 终止 HTTPS，因此能看到 Bearer header 以及 IP、时间、大小、频率和房间 URL 路径；没有独立端到端密钥时仍不能解密应用载荷。这不是匿名网络。
- Codex Hook 仅限回环地址、大小受限、两秒超时并需要 Bearer Token。
- Codex 语音草稿必须由用户确认后才发送。
- 普通听写会短暂使用 macOS 通用剪贴板向前台 App 粘贴文本，随后在剪贴板仍保持该值时恢复原内容。
- Codex 完成摘要可能依据系统设置出现在 Watch 通知预览中。
- 本项目使用独立 Bundle ID、Keychain service、Bonjour service、端口、偏好域和映射；不会读取或修改其他输入设备的配置。

报告漏洞前请阅读 [SECURITY.zh-CN.md](SECURITY.zh-CN.md)。隐私说明见 [PRIVACY.zh-CN.md](PRIVACY.zh-CN.md)。

## 已知边界

- CI 的构建和测试不能代替真机、辅助功能、Speech 权限、Watch 震动和外网切换验收。
- iOS/watchOS 没有可供所有开发者直接复用的通用签名包；每位开发者必须使用自己的 Apple Team。
- 初版只发布源码，不发布由维护者证书签名的 App、IPA、描述文件或归档。
- Codex CLI 当前的 `queue --message` 接口需要把已确认文本作为本机进程参数；同一 macOS 用户下具备进程检查权限的软件可能观察到短暂参数。详情见威胁模型。

## 许可证与商标

本项目按 GPL-3.0-only 发布，见 [LICENSE](LICENSE)。Apple、Apple Watch、iPhone、macOS、Codex、OpenAI 和 Cloudflare 是各自权利人的商标；本项目与这些公司不存在隶属或背书关系。
