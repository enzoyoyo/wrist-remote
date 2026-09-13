# Codex 集成

[English](../en/codex-integration.md)

Codex 集成是可选功能。Watch 首屏可以查看当前 Codex 任务和完成摘要，也可以从最近会话中选择精确目标，或在经过 Mac 授权的工作区中创建独立任务。按住说话后，Codex 第一方联网服务将录音转写，文字再经本机 app-server 排入精确目标；不使用 macOS Speech 或剪贴板。

## Watch 上的使用流程

1. 保持 Mac Bridge、配对 iPhone 与 Watch App 可达。
2. 在 Watch 首屏轻点“发送到”。App 打开时会自动请求最新会话目录，也可下拉或点刷新按钮重试。
3. 需要与旧项目无关的任务时，选择“新建会话”里的“全新空白任务”；需要继续使用项目文件时，选择“在项目中新建”。“最近”用于继续已有会话。Watch 不能自行填写 thread 或工作目录。
4. 确认“新建并选择”后，Mac 执行不含 fork/parent 的独立 `thread/start`。空白任务使用 Bridge 分配的独立空目录，不复制旧项目、聊天或启动它的任务身份；沿用 Codex 全局设置。项目任务没有旧聊天，但仍使用项目文件和规则。等待返回结果被选中；结果不明时不会自动重复创建。
5. 返回首屏，按住青色语音按钮；录音开始的震动出现后说话，松开后由 Codex 转写并把文字排入这个精确 existing 会话。移开手指会取消本次录音。主页显示最近一次结果；“已排队”不是“任务已完成”。
6. 等待投递结果。断线、分包回执缺失、目标过期或 app-server 结果不明时都 fail closed，不会自动补发。

录音开始后，目标会话被冻结到这段录音。即使目录刷新、任务变化或用户离开页面，录音也不会静默改发到另一个会话。目标或连接租约过期时，投递会被拒绝，用户需刷新并重新选择。

“当前任务”卡片和“发送到”是两个概念：前者显示 Hook 同步的任务状态；后者决定语音实际进入哪个 Codex 会话。遥控按键位于独立页面，不会因 Codex 会话选择而改变映射。

## 安全与隐私边界

- Hook 只绑定 `127.0.0.1:60928`，不能从 LAN、tailnet 或互联网访问。
- 每个 Hook 请求都必须携带首次运行时随机生成的 32 字节 bearer token。Token 保存于 Bridge Keychain；仓库和 Hook 配置都不包含它。
- Header 最大 16 KiB，JSON body 最大 512 KiB，不接受 chunked transfer；只接受 `POST /codex-hook` 和 `Content-Type: application/json`。
- 会话目录、独立任务创建和文字投递由 Mac 上的 Codex `app-server` 通过 `stdio://` 完成，不创建网络 listener。录音使用 app-server 返回的短期内存登录态请求固定的第一方 `/backend-api/transcribe`，禁止重定向及磁盘 HTTP 缓存。转写后再次校验目标，文字仅通过标准输入提交，不出现在进程参数中；失败不会新建其他任务或自动重发。
- Watch 只收到经清理的会话标题、工作区显示名、状态和 Mac 签发的短期不透明 capability；完整工作目录只保留在 Mac Bridge 内。
- 空白任务目录由 Mac Bridge 在自有私有目录中按请求分配；项目任务目录只能来自 Mac 已看到的最近会话或当前有效 Hook。Watch 不能提交任意路径。Mac 校验返回的工作目录、项目归属、根会话身份及空历史，拒绝继承结果。
- 选择目标、独立任务创建、录音和投递分别绑定精确 operation ID、target lease、stream/submission ID 和音频摘要。Mac 会在每一步重新校验，过期、重放或错配都会失败关闭。
- 连续语音流的每个分包只有在 Mac 接收精确序号后才向 Watch 回执。连接中断会删除部分录音，重连时不自动补发。
- Mac 把 Codex 音频临时存入 Bridge 自有 `0700` 目录中的 `0600` WAV，最长两分钟。路径和音频字节不进入日志或幂等账本。app-server 返回、取消/失败或仅针对超过 24 小时的自有残留文件清理时会删除它。
- 幂等发送账本仅保存 UUID、由 thread 和音频摘要派生的 HMAC 指纹、阶段、thread ID 和队列回执，不保存音频、文件路径、转写或工作目录。
- 完成通知使用通用正文“任务已完成，打开 App 查看结果”，不把摘要、thread、turn、路径或 revision 写入通知 metadata。

Codex 会话控制明确不经过公网 Relay。当前个人版还要求 `WRISTREMOTE_PRIVATE_ONLY = YES` 与 `.invalid` Relay endpoint。其路径是 Watch Connectivity 到配对 iPhone，再由 iPhone 通过已配对、双向认证且加密的直连通道到 Mac；LAN 不可用时可以使用用户明确配置的 Tailscale 私网直连。Watch 无法到达配对 iPhone 时，这条会话控制路径不可用，也不会把操作排队等待以后执行。

## 配置 Hook

Hook 负责把“当前任务”状态与摘要同步到 Watch；选择会话和发送语音不依赖把 Codex 内容放进 Hook 配置。

1. 完成基础安装并打开 Mac Bridge 一次，使其创建 Hook token。
2. 打开 `examples/codex-hooks.json`。
3. 把其中的命令占位符改为本次克隆中 `scripts/codex-notify.sh` 的实际绝对路径。
4. 合并 `UserPromptSubmit` 和 `Stop` 条目到自己的 Codex Hook 配置，不要覆盖其他 Hook。
5. 重启或重载 Codex Hook 配置。

通知脚本从 stdin 接收 Codex 生成的 JSON，从 `Config/Local.xcconfig` 取得 Bundle 前缀，再从对应 Keychain service 读取 token。它建立权限为 `0600` 的临时 curl 配置，并在退出时删除；token 不写入 shell 历史。

## Hook 事件格式

Bridge 接受下列字段：

| 字段 | 必需 | 约束 |
|---|---:|---|
| `session_id` | 是 | 非空、无空白、最多 128 字符；回复兼容路径要求 UUID |
| `turn_id` | 是 | 非空、无空白、最多 128 字符 |
| `hook_event_name` | 是 | `UserPromptSubmit` 或 `Stop` |
| `cwd` | 是 | 运行时实际的绝对工作目录，最多 4096 UTF-8 字节；只在 Mac 内保留完整值 |
| `prompt` | 否 | 用户提示，用于运行中标题 |
| `last_assistant_message` | 否 | 完成结果，用于完成摘要 |

不要在仓库内保存带真实路径、任务内容或标识符的 Hook 样本。

- `UserPromptSubmit`：任务进入 running。
- `Stop`：任务进入 completed，优先使用最后一条 assistant 消息生成摘要。
- 相同 session、turn、event 是幂等重复。
- completed 后迟到的 `UserPromptSubmit` 会被标记为 `ignoredOutOfOrder`。

Bridge 收到首个有效 Hook 后会固定该 thread 作为“当前任务”。来自其他 thread 的事件不会自动抢占首屏；这个固定状态不限制“发送到”会话选择。

## 会话目录与工作区

Bridge 通过 Codex 本机 `thread/list` 读取最多 12 个最近会话，Watch 选择器显示最多 8 个最近会话。每个会话只跨设备发送清理后的标题、工作区末级名称、状态和短期 capability。

“全新空白任务”不依赖已有项目或最近会话。“在项目中新建”显示 Mac 从最近会话或当前 Hook 中确认过的工作区；Git 项目使用独立 worktree，普通目录继续使用该项目目录，两者都不是空文件夹。若空白入口不可用，更新并检查 Mac Bridge，再刷新目录。

## Codex 可执行文件

默认留空 `WRISTREMOTE_CODEX_EXECUTABLE_PATH`，让 Bridge 在安全候选位置中查找可执行文件。若自动发现失败，在被忽略的 `Config/Local.xcconfig` 中填写本机 Codex 可执行文件的绝对路径，然后重新构建 Bridge。

不要把个人安装路径提交到仓库。Bridge 固定启动 `app-server --listen stdio://`；消息和工作目录通过 JSON stdin 传输，不拼进 shell 命令。

## 断线与恢复

- Watch App 打开、Watch Connectivity 激活或 iPhone 恢复可达时，会自动请求状态和会话目录。
- iPhone 负责恢复到 Mac 的 LAN/Tailscale 私网连接；身份不匹配时保持拒绝，不会静默重新信任。
- 网络失败不会自动提交或补发音频。连接恢复后刷新目录，确认目标仍正确，再由用户主动重新录音。
- Mac 重启导致 server epoch 改变后，旧 target 会失效；这是防止错发的预期行为。

## 停用

从自己的 Codex Hook 配置中删除 Wrist Remote 的两个 Hook 条目即可停止任务状态同步。Watch 的遥控按键、前台听写和其他输入设备配置不依赖 Codex Hook。若不需要会话发送功能，不选择目标、不录音即可；项目不会后台自动发送任何 Codex 内容。
