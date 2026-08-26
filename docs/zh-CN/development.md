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

`apps/WristRemote/Shared` 中的类型当前不是对外 `public` API。外部集成应使用 UI、Codex loopback Hook 或 Relay HTTP/WSS，不应假设可以从另一个 Swift package 直接 import 或构造这些内部类型。

## 常用命令

```bash
make setup       # 工具、Local.xcconfig、XcodeGen 和 npm ci
make doctor      # 只读环境检查
make test        # Swift package、Bridge XCTest、Relay check
make relay-audit # 锁定 Relay 依赖的高风险漏洞审计
make test-simulators # iOS XCTest 与无需实时 Bridge 的 watchOS UI 冒烟测试
make build       # 所有 Apple target 的无签名构建
make security    # 路径、凭据和 Git 历史扫描
make verify      # 完整发布门禁，包括依赖审计和 Simulator 测试
make clean       # 仅删除明确的生成目录
```

`make setup` 可能在已安装 Homebrew 时安装 XcodeGen，属于开发机状态变更。`make doctor` 不安装或修改任何内容。Simulator runtime 兼容性由 `make test-simulators` 和完整的 `make verify` 门禁检查，不属于 `make doctor`。

## 测试层次

- Shared Swift tests：profile 完整性、协议 shape、连接状态、Relay crypto 和手势解析。
- Bridge XCTest：动作、配对来源限制、配置会话、语音代际、Codex Hook/回复和隔离边界。
- Relay check：Wrangler typegen、两套 TypeScript typecheck 和 Workers runtime Vitest。
- Simulator tests：iOS XCTest target，以及两项不依赖实时 Bridge 的 watchOS UI 冒烟测试。
- Unsigned builds：iOS Simulator、watchOS Simulator 和 macOS Release 编译。
- 连线/真机测试：其余 watchOS UI tests 需要实时 Bridge；真机继续覆盖配对、权限、36 个映射槽、震动、中文语音、Codex 回执、LAN/WAN 切换和生命周期重连。

自动化层不能替代连线与真机测试。系统缺少所需 Simulator runtime 或无法启用 UI automation 时，应报告环境阻塞，不能写成通过。

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
- 保持“没有离线按键队列”和“旧按键不补执行”。
- 更新 `docs/zh-CN/api.md` 与 `docs/en/api.md`。

仅增加 UI 文案或本地布局时，不应无故修改 wire schema。

## 修改 Relay

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
- 回复必须继续要求用户确认、精确当前 completed task 和幂等 submission ID。
- 不把 Hook token、真实任务、路径或 transcript 写入 fixture。
- 若 CLI 改成 stdin 传输，应同步更新威胁模型中现有进程参数风险。

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
