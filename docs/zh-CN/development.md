# 开发指南

[English](../en/development.md)

## 仓库布局

| 路径 | 内容 |
|---|---|
| `apps/WristRemote/iOS` | iPhone 伴侣 App |
| `apps/WristRemote/Watch` | Apple Watch App |
| `apps/WristRemote/Shared` | 应用内部共享协议、profile 和 Relay 加密实现及测试目标 |
| `apps/WristRemoteBridge/Sources` | macOS Bridge、动作执行、语音与 Codex 集成 |
| `apps/WristRemoteRelay` | Cloudflare Worker、Durable Object 和测试 |
| `Config` | 跟踪的安全默认值与被忽略的本地覆盖 |
| `scripts` | 构建、安装、部署、诊断和安全检查入口 |
| `docs` | 中英文开发文档 |

Xcode 工程、Generated Info.plist、DerivedData、Swift `.build`、`node_modules` 和 Wrangler 状态都是可再生文件，不进入 Git。

`apps/WristRemote/Shared` 中的类型当前不是对外 `public` API。当前 private-only 构建的外部集成应使用 UI 或 Codex loopback Hook，不应假设可以从另一个 Swift package 直接 import 或构造这些内部类型。Relay HTTP/WSS 源码属于另行安全审查的变体；当 `WRISTREMOTE_PRIVATE_ONLY = YES` 且 endpoint 为 `.invalid` 时不会启用。

## 常用命令

```bash
make setup       # 工具、Local.xcconfig、XcodeGen 和 npm ci
make doctor      # 只读环境检查
make test        # Swift package、Bridge XCTest、Relay check
make relay-audit # 锁定 Relay 依赖的高风险漏洞审计
make test-simulators # iOS XCTest 与无需实时 Bridge 的 watchOS UI 冒烟测试
make build       # 所有 Apple target 的无签名构建
make install-mac # 唯一身份可用时稳定本机签名，再受控安装
make security    # 路径、凭据和 Git 历史扫描
make verify      # 完整发布门禁，包括依赖审计和 Simulator 测试
make clean       # 仅删除明确的生成目录
```

`make setup` 可能在已安装 Homebrew 时安装 XcodeGen，属于开发机状态变更。`make doctor` 不安装或修改任何内容。Simulator runtime 兼容性由 `make test-simulators` 和完整的 `make verify` 门禁检查，不属于 `make doctor`。

Mac 安装脚本只在唯一有效的本机 `Apple Development` 身份存在时自动选择。多个匹配会 fail closed，并要求通过单次 `WRIST_CODESIGN_IDENTITY` 精确指定；零匹配才使用 ad-hoc。辅助函数及其回归 fixture 不得打印或持久化证书名称、哈希或 Team ID。详见[配置参考](configuration.md#mac-构建签名选择)。

## 测试层次

- Shared Swift tests：profile 完整性、协议 shape、连接状态、Relay crypto 和手势解析。
- Bridge XCTest：动作、配对来源限制、配置会话、普通前台听写、Codex 联网转写/临时文件处理、独立新建任务、Hook/文字提交和隔离边界。
- Relay check：Wrangler typegen、两套 TypeScript typecheck 和 Workers runtime Vitest。
- Simulator tests：iOS XCTest target，以及七项离线 watchOS UI 测试，覆盖首页、全部遥控页、明确选择目标、反复关闭、长标题、大字号、完整目标阅读与语音状态退出。
- Unsigned builds：iOS Simulator、watchOS Simulator 和 macOS Release 编译。
- 连线/真机测试：其余 watchOS UI tests 需要实时 Bridge；真机继续覆盖配对、权限、36 个映射槽、震动、中文普通前台听写、Codex 转写与文字排队回执、逐包 Mac ACK、LAN/Tailscale 切换、无公网回退和生命周期重连。

自动化层不能替代连线与真机测试。系统缺少所需 Simulator runtime 或无法启用 UI automation 时，应报告环境阻塞，不能写成通过。

仅 Debug 模拟器支持 `--presentation-fixture` 启动参数：它展示合成任务与目录，不激活 WatchConnectivity、不录音、不联系 Mac，并明确显示离线。它不是连接或麦克风测试。修改首页底部区域前，至少检查 40 毫米布局与大字号；不得为预览加入生产传输绕过。

### 首页布局约束

- 发送目标在首页使用两行标题；选择页的“已选”区域允许完整名称和工作区换行、滚动阅读。不能只依靠辅助功能标签保留完整文本。
- 固定录音控件最小高度为 48 点，短提示放在控件内。完整“语音状态”使用滚动区域中至少 44 点的按钮，必须能够关闭回到首页。
- 长按控件作为一个辅助功能按钮暴露，保留开始、结束、取消和状态详情动作；遵守系统减少动态效果设置。
- UI 测试滚动时从固定录音控件上方的可见内容区起手。整屏上滑可能被按住录音手势接管，不能用它替代内容区滚动验证。
- 同时验证默认字号和大字号：入口可点击、录音控件不遮挡目标、没有意外键盘、重复关闭有效。截图复核和控件边界检查不能被“元素存在”断言替代。

原生安装、续签，以及不采用 LiveContainer 替代 watchOS 伴侣签名链的原因，见[私有安装与签名](signing.md)。

## 修改动作

新增或改变动作至少要同步检查：

1. `WatchActionKindWire` 与 profile 校验。
2. iPhone 的分类、标题、编辑器和默认映射。
3. Mac `WatchActionEngine` 的可执行实现。
4. Bridge 的自定义 App allowlist 边界。
5. 单击、双击、长按及 profile revision 测试。
6. 中英文 API、配置和使用文档。

不要加入任意 shell 命令执行。涉及 App 启动时，沿用用户在 Bridge 中明确选择、再通过内部 profile ID 引用的模型。

## 修改协议

LAN、Relay 和 profile 分别使用版本 7、3 和 1。协议变更需要：

- 保持旧端可选字段兼容，或明确升级对应版本。
- 同步 Swift 发送端、Swift 接收端、TypeScript Relay 校验和跨语言 fixtures。
- 测试错误版本、缺失字段、超大字段、重放、过期、错误方向和乱序。
- 保持“没有离线按键队列”“部分音频不重放”和“旧按键不补执行”。
- 更新 `docs/zh-CN/api.md` 与 `docs/en/api.md`。

仅增加 UI 文案或本地布局时，不应无故修改 wire schema。

## 修改 Relay

当前个人版通过两道独立门禁排除 Relay。本节只适用于另行安全审查的 Relay 变体；普通功能或连接问题不得修改任一 private-only 门禁。

- 一个 Durable Object 对应一个 room，不要把所有部署共享到全局对象。
- schema 初始化只在构造函数的 `blockConcurrencyWhile` 内进行；不要跨外部 I/O 持有该锁。
- token 先哈希再持久化；ciphertext 不写存储。
- WebSocket 使用 hibernation API 和 attachment 恢复连接角色。
- 所有外部输入先校验方法、路径、Content-Type、长度、时间和 shape。
- 新错误应保持稳定 JSON shape，并添加 Workers runtime 测试。
- `wrangler.jsonc` 不能加入真实账号、route 或 secret。

## 修改 Codex 集成

- Hook 必须保持 loopback-only 和 Bearer 鉴权。
- 不降低 header/body 上限检查或 constant-time token comparison。
- `UserPromptSubmit`、`Stop`、重复和乱序都需要测试。
- 新任务必须使用不含 parent/fork 字段的独立 `thread/start`，成功注册为已有目标，并在此之前保持语音禁用。
- Codex 语音必须保留 Watch 原始 PCM 直到第一方联网转写：只有 Mac 已投递才确认音频包，只在 Bridge 自有 `0700` 目录写入 `0600` WAV，使用已登录 Codex 账号，再次校验目标，并通过已初始化的 app-server stdin/stdout 排入返回文字。音频、路径、认证信息和转写不得进入日志，结果不明确时绝不自动补发。
- ACK 缺失、目标变化、取消或断线必须 fail closed，删除部分音频且绝不自动重放。最终文件在 app-server 调用返回后删除；限定范围的过期清理只是异常恢复兜底，不是正常保留机制。
- Speech 识别与临时剪贴板必须仅限普通前台听写。
- 不把 Hook token、真实任务、路径、transcript 或音频写入 fixture、日志或账本。
- 不得把 app-server 输入回退到 argv、shell interpolation 或日志。

## 依赖与生成文件

- Relay 使用 `package-lock.json`；测试与部署每次都用 `npm ci` 重装，不信任已有 `node_modules`。
- 不提交 `node_modules`、`.wrangler` 或自动生成的 Worker 类型。
- Xcode 工程由 `project.yml` 生成，不手工维护 `project.pbxproj`。
- 新依赖必须记录许可证、用途、精确版本及是否进入分发物。
- 不复制未经授权的图标、截图、音频、字体或第三方代码。

## 文档

面向开发者的行为变化必须同时更新 `docs/zh-CN` 和 `docs/en`。两种语言应拥有相同文件集、标题层级、命令、版本号、限制和安全披露；翻译不能删掉风险说明。

## 许可证

当前仓库使用 GPL-3.0-only。提交代码即表示贡献者有权按该许可证提供内容。复制或改写第三方实现前先核对来源和兼容许可证，并更新 `THIRD_PARTY_NOTICES.md`。许可证或资产授权不清时，不得发布。
