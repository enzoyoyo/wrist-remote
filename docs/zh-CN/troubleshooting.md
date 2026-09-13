# 故障排查

[English](../en/troubleshooting.md)

先确定故障属于构建、签名、局域网/Tailscale、权限、语音、动作配置还是 Codex。当前个人版是 private-only，不存在公网 Relay 回退。不要用“已收到消息”代替最终动作、音频或文本结果。

## 基础检查

```bash
make doctor
make test
make build
```

- `make doctor` 缺少 XcodeGen：先安装 XcodeGen，或在已有 Homebrew 的机器上重新运行 `make setup`。
- `Config/Local.xcconfig` 缺失：运行 `make setup`。
- 权限不是 `0600`：执行 `chmod 600 Config/Local.xcconfig`。
- Bundle 前缀仍含 `example`：换成自己控制的唯一值。
- Node 版本过旧：升级到 Node.js 24 或更新版本，与 CI 保持一致。

## 真机安装失败

先运行：

```bash
scripts/install-devices.command --dry-run
```

常见原因：

- iPhone 或 Watch 锁定。
- Watch 尚未与目标 iPhone 配对。
- 开发者模式未开启。
- Xcode 尚未完成设备支持准备。
- 多个设备或多个 Apple Development identity 导致自动选择歧义。
- Team ID 与 Bundle ID 的 provisioning 不匹配。

只为当前命令设置脚本提示的环境变量。不要把 UDID、Team ID、描述文件或命令输出提交到问题报告。

## Watch 显示 Mac 未连接

1. 确认 Mac Bridge、iPhone App 和 Watch App 都在运行。
2. 确认 iPhone 和 Bridge 的本地网络权限已允许。
3. 首次连接必须在两端确认一致的六位码。
4. 检查 VPN、防火墙或访客 Wi-Fi 是否阻断 Bonjour 或客户端互访。
5. 如果 iPhone 被强制退出或锁屏状态限制了前台恢复，先打开 iPhone App。
6. 需要远程私网访问时，确认 Mac 与 iPhone 的 Tailscale 均已连接，且保存的 endpoint 是官方范围内的字面 Tailscale IP；DNS 名称与公网 endpoint 会被拒绝。

连接恢复只表示传输可用。再测试一个无破坏性映射，确认 Mac 实际执行。

## App 已连接但按键无效

- 等待 iPhone 显示最新 profile 已同步；Mac 不执行未安装修订的动作。
- 确认 Bridge 已获得辅助功能权限。
- 自定义 App 必须先在 Bridge 添加，再在 iPhone 选择对应 profile。
- 自定义快捷键应包含支持的 Control、Option、Shift、Command 修饰键和有效 key code。
- 用单击、双击和长按分别验证，不要从其中一种成功推断全部手势成功。

## 没有震动反馈

- 检查 Watch App 的按键震动设置。
- 检查 watchOS 系统触觉设置和佩戴状态。
- 确认动作真正提交；拖出按钮或取消手势不应产生成功震动。
- “减弱动态效果”会减少视觉动画，但不应自动关闭语义震动。

## 中文普通前台听写不识别

1. 允许 Watch 麦克风和 Mac 语音识别权限。
2. 确认 Bridge 已连接并且没有另一段 Watch 语音占用会话。
3. 检查 Mac 系统是否提供中文 Speech recognizer；简体中文会优先解析为 `zh-CN`，繁体中文按地区选择。
4. 说完后正常结束录音，等待最终结果而不是仅看 partial transcript。
5. 普通前台听写识别完成后会立即注入当前焦点输入框。
6. 若识别成功但文字未出现，确认目标输入框仍有焦点，并检查 Bridge 辅助功能权限。

只有普通前台听写使用 Bridge 的 Speech Framework 和临时剪贴板；它不依赖第三方输入法、虚拟麦克风或全局 Fn 模式。

普通语音注入会短暂使用系统通用剪贴板并模拟 Command-V。约 450 ms 后，仅当剪贴板仍是临时识别文本且没有被改变时才恢复原内容；其他进程可能短暂观察到文本。若期间有进程改变剪贴板，Bridge 不覆盖新内容，原内容也可能无法自动恢复。

## 私有版出现 Relay 路径

立即停止验收。个人版必须在所有产物中同时编入 `WRISTREMOTE_PRIVATE_ONLY = YES` 和 `.invalid` Relay endpoint。按私有版撤销流程清除历史 Relay 凭据，重启三端，并通过系统网络状态或抓包确认没有请求发往旧公网 endpoint。不能为了绕过连接问题而替换 `.invalid` 值。

## Codex 任务不显示

1. 打开 Bridge，确认 Hook 状态已就绪。
2. 确认 Bridge 首次启动后已生成 Keychain token。
3. 确认 Hook 配置中的脚本是当前克隆的实际绝对路径。
4. 只合并 `UserPromptSubmit` 和 `Stop`，并重载 Codex 配置。
5. `scripts/codex-notify.sh` 报本地配置错误时，检查 Bundle 前缀是否与当前 Bridge 构建一致。
6. 401 表示 token 不匹配；422 表示 Hook JSON 字段不合法。
7. 首个有效 Hook 会 pin 当前 thread；其他 thread 不会自动接管。要切换，在 Mac Bridge 点“切换到下一条聊天”，再让目标 thread 产生下一条 Hook。

不要把 Hook token、真实 task JSON、工作目录或 transcript 粘贴到公开 issue。

## Codex 回复失败

- 目标必须是当前精确选择且仍获授权的已有任务；具体操作仍受运行状态和 revision 门禁约束。
- 新任务必须先完成无 parent/fork 关系的独立 `thread/start`，出现在已有目标列表中，之后才允许语音。
- 在手表的「选择会话」中刷新，确认目标未过期且仍可接收输入。
- Codex 可执行文件必须可执行；自动发现失败时配置本地绝对路径并重建 Bridge。
- 本地 Codex app-server 需在限定时间内回复 `thread/list`、独立 `thread/start` 和文字 `thread/queue/add` 请求。语音还需要已登录 Codex 账号并能访问其联网转写服务。
- 相同 submission ID 携带不同内容会被拒绝。

Codex 语音不使用 macOS Speech 或剪贴板。Watch 通过 iPhone 发送原始 PCM；连续连接期间，只有收到 Mac 对当前音频包的 ACK 后才推进下一包。Mac 写入仅文件所有者可读写的临时 WAV，使用已登录 Codex 账号请求第一方联网转写，再次校验目标，并经本机 app-server 排入文字。ACK 缺失、链路断开或目标变化时，音频流会 fail closed，部分音频被删除，且不会自动重放；重连后需要重新录音。若提交结果不明确，先查看所选任务，避免重复发送。

## 安全地收集诊断

可分享：失败组件、源码版本、操作系统大版本、复现步骤、期望与实际状态，以及已经脱敏的错误 code。

分享前移除：姓名、邮箱、真实域名、IP、room ID、device ID、UDID、Team ID、Bundle 前缀、token、E2E key、路径、任务内容、transcript、截图、描述文件和完整日志。

安全问题使用 GitHub 私有漏洞报告，不要公开披露利用细节。
