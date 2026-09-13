# Wrist Remote

Wrist Remote 是一套以隐私和隔离为前提的 iPhone 与 Apple Watch 遥控 macOS 方案，由 Apple Watch App、iPhone App 和 Mac Bridge 组成。默认构建仅使用私有网络：支持局域网和可选的 iPhone Tailscale 路由，公网 Relay 被禁用。

[English](README.en.md) · [文档目录](docs/zh-CN/getting-started.md)

## 功能

- iPhone 12 键手机遥控面板，与 Apple Watch 共用全部 36 个手势映射槽；Mac 扫码配对入口及手机、手表独立连接状态。
- Apple Watch 前台局域网直连，使用独立设备身份；手机和手表可以同时连接。按键提供执行回执，未确认的操作不会在重连后补发。
- 12 个虚拟按键，每个按键都有单击、双击、长按，共 36 个独立映射槽。
- 键盘按键、组合快捷键、音量与媒体、显示桌面、App 切换等系统动作。
- 由开发者在 Mac Bridge 中选择任意 App，再映射到手表；仓库不预置个人 App 清单。
- Apple Watch 触觉反馈、宽松按键布局、收藏按键和自动重连。
- Watch 麦克风有两条隔离路径：普通前台听写使用 Mac Speech Framework 和临时剪贴板；Codex 语音使用已登录账号的 Codex 原生联网转写服务，再把文字排入所选任务，不使用 Mac 听写权限。
- 可选 Codex 集成：手表可浏览最近会话、选择精确目标、新建独立任务，并按住说话提交任务；首屏同时显示任务状态、摘要和最近一次语音结果。
- 局域网先行，Tailscale 私有网络可在不开放公网监听的情况下作为候选链路。仅私有网络构建不提供独立公网控制。
- 双向安装身份：Mac 使用长期 P-256 身份签署每次直连握手；iPhone 经双端确认后固定 Mac 指纹，Mac 同时固定 iPhone 身份。

## 架构

```text
Apple Watch
  ├─ 前台局域网按键：应用层加密 HTTP → Mac Bridge
  ├─ 中转 / 语音：WatchConnectivity → iPhone → Bonjour + 加密 TCP → Mac Bridge
  └─ 私有外网：WatchConnectivity → iPhone → Tailscale TCP → Mac Bridge
```

手机也可直接发送遥控按键。Watch 直连使用具体局域网地址上的 HTTP `60929`，不使用 Tailscale；HTTP 内的消息经过身份校验和应用层加密，语音仍由 iPhone 中转。扫码配对、独立手表授权和执行回执见[手机与 Watch 遥控连接](docs/zh-CN/phone-watch-connection.md)。

局域网 listener 只绑定允许的非隧道本地接口上的一个具体、不可公网路由地址（RFC1918 IPv4、IPv4 链路本地地址或 IPv6 ULA）；找不到安全地址时拒绝启动。独立 Tailscale listener 默认关闭，启用后只绑定 `utun` 上一个官方范围内的具体地址，固定使用 TCP `60927`。两种模式都不会开放公网入站端口。`WRISTREMOTE_PRIVATE_ONLY = YES` 在构建配置层禁用公网 Relay，`.invalid` URL 又独立阻止 provisioning 和网络请求；历史公网凭据不会被恢复使用。

## 系统要求

- macOS 13 或更新版本。
- iOS 17 或更新版本。
- watchOS 10 或更新版本。
- 完整版 Xcode 26 或更新版本（含已安装的 iOS 与 watchOS Simulator runtime）、XcodeGen、Swift、Node.js 24+ 和 npm。Mac 目标编译需要 macOS 26 SDK；运行时可用性检查仍保留较早系统的最低部署要求。CI 使用 Xcode 26.3。
- 真机安装需要你自己的 Apple Developer Team、已开启开发者模式且与 Mac 建立开发连接的 iPhone 和 Apple Watch。
- 私有网络备用链路要求已配对 iPhone 与 Mac 安装 Tailscale 并加入同一 tailnet；Watch 本身不加入 tailnet。
- 仅私有网络构建不需要 Cloudflare 账号或公网服务。

## 10 分钟快速开始

先从当前 GitHub 仓库页面复制 HTTPS 或 SSH Clone 地址，再执行：

```bash
git clone REPLACE_WITH_REPOSITORY_CLONE_URL
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
WRISTREMOTE_PRIVATE_ONLY = YES
WRISTREMOTE_RELAY_BASE_URL = https:/$()/relay.example.invalid
WRISTREMOTE_CODEX_EXECUTABLE_PATH =
```

必须将 Bundle 前缀和 Team ID 换成你自己的值。不要提交这个文件。

安装 Mac Bridge：

```bash
make install-mac
```

默认安装到 `~/Applications/WristRemoteBridge.app`，本机已有同名 App 时会先移动到带时间戳的备份路径。若需在其他位置受控就地升级，可执行 `scripts/build-macos.sh --install --target-app /absolute/path/WristRemoteBridge.app`；目标必须是非符号链接的绝对 `.app` 路径，且 Bundle ID 必须与已验证构建一致。若旧 Bridge 有经确认的历史 Bundle ID，只能在核实目标后把 `WRISTREMOTE_BRIDGE_BUNDLE_IDENTIFIER` 写入已忽略的 `Config/Local.xcconfig`。只要任何 `WristRemoteBridge` 进程仍在运行，安装就会拒绝继续且不会自动结束进程；请正常退出 App 后重试。脚本只在本机签名；仓库不会包含证书、Team ID、描述文件或已签名二进制。

真机安装：

```bash
make install-devices
```

脚本会自动选择唯一可用的 iPhone、Apple Watch 和 Apple Development 身份，临时构建、校验描述文件、安装并启动。若发现多个候选设备或 Team，会停止并要求你只为本次命令提供环境变量，避免装错设备。已有安装必须按[配置参考](docs/zh-CN/configuration.md#iphone-与-watch-受控原位升级)设置两个经核实的精确移动端 Bundle ID；门禁会核对当前 Team、历史 profile 和两台真机的现装身份，避免生成重复 App 或丢失 Bundle 派生的 Keychain 状态。

Apple 登录、设备信任、开发者模式、辅助功能、麦克风和语音识别权限均必须由用户在系统界面确认。语音识别权限只服务于普通前台听写，Codex 联网语音转写不使用它。脚本不会绕过这些安全机制。

## 使用方法

1. 打开 Mac Bridge，允许本地网络和辅助功能权限；只有需要普通前台听写时才授予语音识别权限。
2. 在 Mac Bridge 显示配对二维码，用 iPhone 系统相机扫描；也可使用自动发现或导入配对链接。首次使用，或从尚未固定 Mac 身份的旧版本升级后，需要在 iPhone 与 Mac 核对同一个六位码并由两端分别批准。二维码本身不会授权设备。成功后 iPhone 固定 Mac 身份，Mac 固定 iPhone 身份。
3. 在 iPhone 的自定义界面中调整四个收藏位置，以及每个按键的单击、双击和长按动作，再从首页进入“打开手机遥控”。手机和手表共用 12 个按键、36 个映射槽。
4. 如要启动自定义 App，先在 Mac Bridge 点击“添加 App…”，再在 iPhone 中选择该 App 配置。
5. 如需 Watch 局域网按键直连，在手表的“遥控连接”中启用“直接连接 Mac”，并在 Mac 批准独立的手表配对码。使用时保持手表 App 在前台；语音仍需要 iPhone 中转。详见[手机与 Watch 遥控连接](docs/zh-CN/phone-watch-connection.md)。
6. 配对 iPhone 会先给局域网 0.9 秒连接时间。显式配置 Tailscale 后，若局域网届时尚未 ready，则同时启动连接 Mac 官方 Tailscale 专用 IP 的候选链路，并采用首个 ready 的链路。仅私有网络构建中，iPhone 不可达时不提供 Watch 独立蜂窝控制。

## Tailscale 私有网络（可选）

在 Mac 和已配对 iPhone 安装 Tailscale 并加入同一 tailnet；在 Mac Bridge 开启私有网络 listener，再在 iPhone App 保存 Mac 的官方 Tailscale IPv4 或 IPv6 地址。仅私有网络构建会拒绝 DNS 名称、URL、端口、凭据、公网 IP 和无关私网 IP。Bonjour 先获得 0.9 秒 head start；若局域网 candidate 届时尚未 ready 并被采用，iPhone 也会启动通过 Tailscale 固定 TCP `60927` 的 candidate。首个 ready 的 candidate 被采用，另一个会被取消；已采用或已连接的 route 不被抢占，下一轮重连再从局域网优先开始。局域网失败或超时时会立即启动 Tailscale。

私有 listener 默认关闭，只绑定 `utun` 上官方范围内的 Tailscale 地址。Wrist Remote 自己的双向身份校验、首次双端批准和应用层加密始终强制执行。后续 Mac 身份发生变化时连接会直接失败。不要使用 Tailscale Funnel、路由器端口转发、公网代理或公网监听。Termius 只能作为独立 SSH 诊断工具，不是 App 的传输层。

官方 IP 校验、VPN On Demand、最小权限 Grant、真机验收和故障排查见 [docs/zh-CN/tailscale-private-network.md](docs/zh-CN/tailscale-private-network.md)。

## 仅私有网络构建禁用公网 Relay

仓库跟踪的配置和本地配置示例都设置 `WRISTREMOTE_PRIVATE_ONLY = YES`，并保留 `.invalid` Relay URL。这是两道独立门禁：只改 URL 不能启用公网路径，只改构建标志也仍会被 `.invalid` 阻止。Relay 源码仍保留给需要单独安全评审的变体，但它不是默认构建的运行时选项。不得用 Funnel、端口转发或公网代理替代。

## Codex 集成（可选）

在手表选择已有任务，或先创建独立任务，再按住录音、松开发送。录音经 iPhone 到达 Mac，使用已登录账号的 Codex 第一方联网服务转写。Bridge 再次核对目标后，通过本机 app-server 把文字排入这个精确任务。这需要互联网，不使用 macOS Speech 或剪贴板。队列回执表示已提交，不代表任务完成。

Bridge 只监听 `127.0.0.1:60928/codex-hook`，并要求随机 Bearer Token。Token 首次启动时生成并保存到 Keychain。`scripts/codex-notify.sh` 会安全读取 Token 并把 Codex Hook 的 JSON 从 stdin 转发给 Bridge，不会把 Token 写进仓库或 shell 历史。

把 [examples/codex-hooks.json](examples/codex-hooks.json) 复制到仓库外，将 `<REPO_ROOT>` 替换为克隆目录的绝对路径，再合并到自己的 Codex Hook 配置。不要提交定制后的文件，也不要覆盖已有 Hook。详见 [docs/zh-CN/codex-integration.md](docs/zh-CN/codex-integration.md)。

## 开发命令

| 命令 | 作用 |
|---|---|
| `make setup` | 准备工具、配置、Xcode 工程和 npm 依赖 |
| `make doctor` | 只读检查开发环境 |
| `make icons` | 从仓库内纯几何脚本重新生成全部 App 图标 |
| `make test` | Swift、Bridge 和 Relay 测试 |
| `make relay-audit` | 审计锁定的 Relay 依赖是否存在高风险漏洞 |
| `make test-simulators` | iOS 单元测试与无需实时 Bridge 的 watchOS UI 冒烟测试 |
| `make build` | 无签名构建 iOS/watchOS Simulator 与 macOS |
| `make install-mac` | 本机签名并安装 Mac Bridge |
| `make install-devices` | 用开发者自己的 Team 安装 iPhone/Watch 真机 |
| `make deploy-relay` | Relay 开发工具；`WRISTREMOTE_PRIVATE_ONLY = YES` 构建中不会成为可用路径 |
| `make security` | 路径、凭据、私钥、禁止文件和 Git 历史扫描 |
| `make verify` | 执行完整发布门禁，包括依赖审计和 Simulator 测试 |

开发接口与调用示例见 [docs/zh-CN/api.md](docs/zh-CN/api.md)，贡献流程见 [CONTRIBUTING.zh-CN.md](CONTRIBUTING.zh-CN.md)。

## 安全与隐私

- 直连指令、音频、任务摘要和结果在已配对 iPhone 与 Mac 之间加密。
- 仅私有网络构建的 Tailscale 模式在 iPhone 端只接受官方 Tailscale 专用 IP，在 Mac 端只接受具体 `utun` 地址和 Tailscale 来源；默认关闭，且不会削弱应用配对或加密。
- Mac 与 iPhone 的长期 P-256 身份、iPhone 固定的 Mac 指纹，以及 Mac 信任的 iPhone 指纹分别保存在独立、由 Bundle 派生的 Keychain service；两端都只在对应条目不存在时创建身份，条目损坏或不可读时拒绝连接，不会静默换钥。Mac 若无法持久保存获批的 iPhone 指纹，会在 ready 前拒绝本次会话。
- Codex Hook 仅限回环地址、大小受限、两秒超时并需要 Bearer Token。
- 选择“新建任务”时，先使用不含 fork/parent 的 `thread/start` 建立独立任务，再将结果注册为 existing 目标；目标未 ready 前不允许开始语音。
- Codex 语音经实时私有链路传输 PCM，在 Mac 写入只有所有者可读写的临时 WAV；Codex 第一方服务联网转写后，文字经本机 app-server 排入精确目标。凭据、转写、路径和音频不进入 Bridge 日志或幂等账本。已排队不代表任务完成，转写失败会明确显示未发送。
- 确认尚未入队的转写失败会安全释放本次投递记录，避免持续失败耗尽账本容量；已入队或结果未知时仍保留防重复保护。这不会自动重试，也不会清理历史未知记录。
- 连续录音的每个分包只有在 Mac 确认接收后才向前推进。断线时 fail closed，删除部分录音，不会在重连后自动补发。
- 普通听写会短暂使用 macOS 通用剪贴板向前台 App 粘贴文本，随后在剪贴板仍保持该值时恢复原内容。
- Codex 完成通知使用通用文案，不携带任务标题、摘要或会话标识。
- 当签名构建把 Relay URL 保持为 `.invalid` 时，三端不会恢复历史公网凭据；Bridge 会发送明确清除标记，iPhone 和 Watch 会删除对应 Keychain 条目。
- 本项目使用独立 Bundle ID、Keychain service、Bonjour service、端口、偏好域和映射；不会读取或修改其他输入设备的配置。

报告漏洞前请阅读 [SECURITY.zh-CN.md](SECURITY.zh-CN.md)。隐私说明见 [PRIVACY.zh-CN.md](PRIVACY.zh-CN.md)。

## 已知边界

- CI 的构建和测试不能代替真机、辅助功能、Speech 权限、Watch 震动、语音逐包 Mac 确认、VPN 唤醒和局域网到 Tailscale 切换验收。
- Tailscale 直连依赖可达的配对 iPhone；仅私有网络构建中，iPhone 不可达时不提供独立蜂窝 Watch 控制。
- 从尚未固定 Mac 身份的旧版本升级时，需要完成一次双端明确配对。若确认是 Mac 重装或 Keychain 重置导致身份改变，可在 iPhone App 中使用“忘记已信任的 Mac”，再由两端重新核对并批准六位码。若通过“重置此 iPhone 的配对身份”有意更换 iPhone 安装身份，Mac 会把它视为新 iPhone 并要求再次批准；不要用任一重置操作绕过来源不明的身份警告。
- iOS/watchOS 没有可供所有开发者直接复用的通用签名包；每位开发者必须使用自己的 Apple Team。
- 初版只发布源码，不发布由维护者证书签名的 App、IPA、描述文件或归档。
- Codex 会话列表、独立任务创建、语音目标锁定、联网转写与文字投递、断线失败关闭和发送回执仍需在目标 Mac、iPhone 和 Watch 上完成真机端到端验收；自动测试不能代替这一步。

## 许可证与商标

本项目按 GPL-3.0-only 发布，见 [LICENSE](LICENSE)。Apple、Apple Watch、iPhone、macOS、Codex、OpenAI 和 Cloudflare 是各自权利人的商标；本项目与这些公司不存在隶属或背书关系。
