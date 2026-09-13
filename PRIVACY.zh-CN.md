# 隐私说明

[English](PRIVACY.md)

Wrist Remote 是自托管软件。本仓库维护者不为项目运营 Relay、分析服务、广告服务或用户账号系统。

## 本地处理的数据

根据启用的功能，Apple App 和 Mac Bridge 可能处理按键动作、App 选择、麦克风录音、前台听写转写、Codex 原始音频输入、任务状态、摘要和投递结果。客户端凭据、配对状态、Mac 与 iPhone 的长期 P-256 安装身份、iPhone 固定的 Mac 指纹、Mac 信任的 iPhone 指纹和直连会话密钥存放于 Apple Keychain；本地偏好保留在 App 容器或 Application Support 目录。身份条目不可读或损坏时不会被静默替换，连接会停止，直到存储恢复可用或用户执行相应的显式恢复操作。

只有用户在 Watch 上主动操作后才会采集麦克风音频。普通前台听写使用 Mac Speech Framework，最终识别成功后会立即输入当前前台 App：Bridge 会把转写短暂写入 macOS 通用剪贴板、模拟粘贴，并在约 450 毫秒后仅当剪贴板仍是该值时恢复原内容。同一用户下的其他软件可能观察到临时值，并发剪贴板修改也可能使恢复条件不成立。

Codex 语音是与之隔离的路径，不使用 macOS Speech 识别或剪贴板。Watch 通过实时、已认证的链路发送受限 PCM 分包；Mac 把它们写入 Bridge 自有目录中的临时 WAV，目录权限为 `0700`、文件权限为 `0600`，录音最长两分钟。Bridge 使用当前 Codex 的 ChatGPT 登录态，把录音交给 Codex 第一方转写接口（`https://chatgpt.com/backend-api/transcribe`），再把返回文字排入所选任务。这需要联网，不是设备端转写。登录令牌仅通过本机 app-server 获取并短暂保留在内存中，不跟随重定向，不使用磁盘 HTTP 缓存。凭据、转写、路径和音频字节不进入日志或幂等账本。取消或断线时删除部分录音，转写与投递返回后删除已完结录音；Bridge 启动时只清理自身超过 24 小时的 `watch-*.wav`。

## 可选 Tailscale 私有网络

私有网络模式会在 iPhone Keychain 中保存启用状态以及经过校验的 Mac 官方 Tailscale 专用 IP。仅私有网络构建会拒绝 DNS 名称、URL、端口、凭据、公网 IP 和无关私网 IP。Mac 唯一的 Tailscale 专属偏好是是否启用独立 listener。与 Tailscale 配置分开，Mac Keychain 保存直连协议身份及信任的 iPhone 指纹，iPhone Keychain 保存固定的 Mac 指纹。Wrist Remote 不保存 Tailscale 账号凭据、auth key、tailnet 策略或 Termius SSH 凭据。

启用后，动作、音频、任务和回复载荷会经用户自己的 Tailscale 网络在 iPhone 与 Mac 之间传输，同时继续受到 Wrist Remote 双向认证加密会话保护。首次信任时会显示六位码和截短的 Mac 指纹，完整指纹只留在本机 Keychain。Tailscale 是独立服务，有自己的账号、控制平面、元数据、日志、保留和隐私条款；tailnet 运营者需自行负责相关设置并通过 Grant 限制访问。本项目不使用 Tailscale Funnel，也不会把 TCP `60927` 发布到公网。

Apple Watch 本身不会接收 Tailscale 地址，也不会加入 tailnet。私有网络实时命令通过 Watch Connectivity 交给配对 iPhone；Watch 无法访问 iPhone 时不能使用这条路径。

## 公网 Relay 与仅私有网络构建

仓库当前的个人构建设置 `WRISTREMOTE_PRIVATE_ONLY = YES`，并保留 `.invalid` Relay 端点。两道门禁必须同时允许 Relay，因此只修改任意一项都不会开启公网路径。历史 Relay provisioning 会被撤销，不会自动恢复。Relay 源码仍保留给需要单独评审的构建变体，但仅私有网络构建不会把指令、音频、任务或 Codex 流量发给 Cloudflare。

不得使用 Tailscale Funnel、路由器端口转发、公网代理或公网通配监听替代；这些机制会建立不同的隐私和威胁边界，不在支持范围内。

## Codex 集成

可选的本地 Hook 只在回环地址接收任务元数据。Watch 任务卡可接收 thread/turn 标识、工作区显示名（不是完整本机路径）、最多 72 个字符的标题和最多 160 个字符的摘要。会话选择器可接收最近会话标题、工作区显示名、临时随机标识和短期授权；完整工作目录始终只留在 Mac。

Codex 完成通知使用通用正文，不在通知正文或 metadata 中放入任务标题、摘要、thread 或 turn。语音投递结果只通过实时回执传递，不进入 Watch Connectivity 的持久 application context。选择“新建任务”时，先通过本机 `thread/start` 创建不含 fork/parent 的独立 thread，返回结果注册为 existing 目标后才能录音。Codex 转写后，文字通过本机 app-server 的 stdin/stdout 协议排队，不进入进程参数；排队回执不代表任务完成。转写结束后再次校验所选目标；取消、断线或目标变化不会新建兜底任务或自动重发。Watch 到 Mac 的会话选择和发送只走 Watch Connectivity 与 LAN/Tailscale 私有直连，不使用公网 Relay；Mac 到 Codex 的转写请求另走上述第一方互联网接口。用户仍需自行了解本机 Codex 所连接服务的隐私和数据保留政策。

## 诊断信息

本仓库不收集遥测。诊断输出保留在本机，除非用户主动分享。分享前必须移除凭据、标识、路径、转写、音频、截图、日志、描述文件、Tailscale 地址、tailnet 账号 selector 和策略导出。

## 删除

删除 App 不一定会同步删除 Keychain 条目。如需完整删除，用户应在自己的设备上移除 App 容器、Application Support 数据和 Wrist Remote Keychain 条目，包括安装密钥与信任指纹。**忘记已信任的 Mac** 只删除 iPhone 固定的 Mac 指纹；**重置此 iPhone 的配对身份** 只替换 iPhone 客户端身份，并使 Mac 要求重新批准。两项操作都不等同于完整删除，也不会更改按键映射或其他遥控器。Tailscale 设备成员关系和账号数据需另行在 Tailscale 中删除；若运营另行安全审查的 Relay 变体，还必须删除其 Worker、Durable Object namespace 和 secrets。
