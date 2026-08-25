# 故障排查

[English](../en/troubleshooting.md)

先确定故障属于构建、签名、局域网、Relay、权限、语音、动作配置还是 Codex。不要用“已收到消息”代替最终动作或文本结果。

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
6. Relay 仅在已部署、三端重建并完成 provisioning 后可作为外网路径。

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

## 中文语音不识别

1. 允许 Watch 麦克风和 Mac 语音识别权限。
2. 确认 Bridge 已连接并且没有另一段 Watch 语音占用会话。
3. 检查 Mac 系统是否提供中文 Speech recognizer；简体中文会优先解析为 `zh-CN`，繁体中文按地区选择。
4. 说完后正常结束录音，等待最终结果而不是仅看 partial transcript。
5. 普通前台语音识别完成后会立即注入当前焦点输入框；只有 Codex 任务语音使用草稿确认，并且还要求当前 completed task identity。
6. 若识别成功但文字未出现，确认目标输入框仍有焦点，并检查 Bridge 辅助功能权限。

此链路使用 Bridge 的 Speech Framework，不依赖第三方输入法、虚拟麦克风或全局 Fn 模式。

普通语音注入会短暂使用系统通用剪贴板并模拟 Command-V。约 450 ms 后，仅当剪贴板仍是临时识别文本且没有被改变时才恢复原内容；其他进程可能短暂观察到文本。若期间有进程改变剪贴板，Bridge 不覆盖新内容，原内容也可能无法自动恢复。

## Relay 健康检查失败

- HTTP 503 且 `configured=false`：`ALLOWED_ROOM_ID` 或 `BOOTSTRAP_MAC_TOKEN` 缺失/格式错误，重新运行 `make deploy-relay`。
- `mac_offline`：Worker 正常，但 Bridge 没有活跃 WSS；打开 Bridge 并确认其使用同一 Relay URL 和 Keychain credentials。
- `unauthorized`：设备或 Mac bearer 与 room 初始化值不一致；不要反复手工初始化。
- `replay_detected`：序号或 operation ID 已使用，调用者必须生成新 operation。
- `relay_timeout`：Mac 连接存在但 15 秒内未回复，检查 Bridge 状态和网络。
- 健康通过但 Watch 仍无互联网：确认部署后重新构建三端，并先完成一次 LAN provisioning。

Relay 不会保存离线按键。网络恢复后没有补执行是正确行为。

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

- 必须是当前精确的 completed task；运行中、已切换或旧 revision 都会拒绝。
- 用户必须确认非空草稿。
- `session_id` 必须是可用的 thread UUID。
- Codex 可执行文件必须可执行；自动发现失败时配置本地绝对路径并重建 Bridge。
- CLI 需在 5 秒内接受 `queue` 请求。
- 相同 submission ID 携带不同内容会被拒绝。

## 安全地收集诊断

可分享：失败组件、源码版本、操作系统大版本、复现步骤、期望与实际状态，以及已经脱敏的错误 code。

分享前移除：姓名、邮箱、真实域名、IP、room ID、device ID、UDID、Team ID、Bundle 前缀、token、E2E key、路径、任务内容、transcript、截图、描述文件和完整日志。

安全问题使用 GitHub 私有漏洞报告，不要公开披露利用细节。
