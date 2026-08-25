# Codex 集成

[English](../en/codex-integration.md)

Codex 集成是可选的本机功能。它把当前任务的运行/完成状态和最多 160 个字符的摘要送到 Watch，并允许用户在已完成任务上确认语音回复。

## 安全边界

- Hook 只绑定 `127.0.0.1:60928`，不能从 LAN 或互联网访问。
- 每个请求都必须携带首次运行时随机生成的 32 字节 bearer token。
- Token 保存于 Bridge Keychain；仓库和 Hook 配置都不包含它。
- Header 最大 16 KiB，JSON body 最大 512 KiB，不接受 chunked transfer。
- 只接受 `POST /codex-hook` 和 `Content-Type: application/json`。
- Task reply 必须绑定当前精确的 thread、turn、工作目录和 task revision，并且任务仍为 completed。
- 语音文本必须由用户确认；Bridge 不自动发送草稿。

Hook 会向 Bridge 提供 thread/turn 标识和完整 `cwd`。Bridge 派生最多 72 个字符的任务标题和最多 160 个字符的摘要，并同步到 Apple 设备；启用外网 Relay 时，这些应用 payload 以 E2E 密文传输。不要在任务标题、路径或提示中放入不希望出现在 Watch 上的秘密。

任务完成后，Watch 会创建本地通知：正文包含摘要或标题，notification metadata 包含 thread、turn 和 revision。Apple Watch 可能依据通知预览设置在锁屏或通知中心显示这些内容；若任务文本敏感，请关闭预览或 Wrist Remote 通知。

## 配置 Hook

1. 完成基础安装并打开 Mac Bridge 一次，使其创建 Hook token。
2. 打开 `examples/codex-hooks.json`。
3. 把其中的命令占位符改为本次克隆中 `scripts/codex-notify.sh` 的实际绝对路径。
4. 合并 `UserPromptSubmit` 和 `Stop` 条目到自己的 Codex Hook 配置，不要覆盖其他 Hook。
5. 重启或重载 Codex Hook 配置。

通知脚本从 stdin 接收 Codex 生成的 JSON，从 `Config/Local.xcconfig` 取得 Bundle 前缀，再从对应 Keychain service 读取 token。它建立权限为 `0600` 的临时 curl 配置，并在退出时删除；token 不写入 shell 历史。

## 事件格式

Bridge 接受 Codex Hook 的下列字段：

| 字段 | 必需 | 约束 |
|---|---:|---|
| `session_id` | 是 | 非空、无空白、最多 128 字符；回复路径要求 UUID |
| `turn_id` | 是 | 非空、无空白、最多 128 字符 |
| `hook_event_name` | 是 | `UserPromptSubmit` 或 `Stop` |
| `cwd` | 是 | 运行时实际的绝对工作目录，最多 4096 UTF-8 字节 |
| `prompt` | 否 | 用户提示，用于运行中摘要 |
| `last_assistant_message` | 否 | 完成结果，用于完成摘要 |

不要在仓库内保存带真实路径、任务内容或标识符的 Hook 样本。

事件含义：

- `UserPromptSubmit`：任务进入 running。
- `Stop`：任务进入 completed，优先使用最后一条 assistant 消息生成摘要。
- 相同 session、turn、event 是幂等重复。
- completed 后迟到的 UserPromptSubmit 会被标记为 `ignoredOutOfOrder`。

## 当前 thread 选择

Bridge 收到首个有效 Hook 后会锁定（pin）该 thread。来自其他 thread 的事件不会自动接管 Watch 首屏。要切换任务，在 Mac Bridge 点“切换到下一条聊天”，然后等待目标 thread 产生下一条 Hook；切换按钮本身不会主动扫描或读取其他聊天。只有新 Hook 到达后，目标 thread 才会成为当前任务。

成功响应：

```json
{"accepted":true,"disposition":"accepted"}
```

新事件返回 HTTP 202；重复或乱序但已安全处理的事件返回 200；结构无效返回 422。HTTP 层还可能返回 400、401、404、405、413、415 或 431。

## 从 Watch 回复

1. Watch 首屏显示当前任务状态或完成摘要。
2. 仅在 completed 任务上启动 Codex 语音。
3. Mac 使用 Speech Framework 生成草稿。
4. 用户确认草稿。
5. Bridge 再次校验 thread、turn、cwd 和 revision 是否仍为当前精确完成任务。
6. Bridge 调用：`codex queue --thread <thread-id> --message <confirmed-text>`。
7. CLI 必须在 5 秒内接受请求；Bridge 返回明确回执并对 submission ID 去重。

若任务在录音期间变化，旧录音和旧回复会被拒绝，不会发送到新任务。

## Codex 可执行文件

默认留空 `WRISTREMOTE_CODEX_EXECUTABLE_PATH`，让 Bridge 在安全候选位置中查找可执行文件。若自动发现失败，在被忽略的 `Config/Local.xcconfig` 中填写本机 Codex 可执行文件的绝对路径，然后重新构建 Bridge。

不要把个人安装路径提交到仓库。

## 已知本机风险

当前 Codex CLI 把用户确认的文本作为 `--message` 进程参数。同一 macOS 用户下、具备进程检查能力的软件可能在很短时间内观察到该参数。这不影响 Relay 的 E2E 加密，但属于端点本机风险。不要用此功能发送密码、token 或其他秘密。

## 停用

从自己的 Codex Hook 配置中删除 Wrist Remote 的两个 Hook 条目即可停止任务事件。删除前先保留其他 Hook；不要覆盖整份配置。Bridge 的其他遥控和语音功能不依赖 Codex Hook。
