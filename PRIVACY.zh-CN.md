# 隐私说明

[English](PRIVACY.md)

Wrist Remote 是自托管软件。本仓库维护者不为项目运营 Relay、分析服务、广告服务或用户账号系统。

## 本地处理的数据

根据启用的功能，Apple App 和 Mac Bridge 可能处理按键动作、App 选择、麦克风录音、语音转写、任务状态、摘要及用户确认的回复。客户端凭据、配对状态和端到端加密密钥存放于 Apple Keychain；本地偏好保留在 App 容器或 Application Support 目录。

只有用户在 Watch 上主动操作后才会采集麦克风音频。普通听写在最终识别成功后会立即输入当前前台 App：Bridge 会把转写短暂写入 macOS 通用剪贴板、模拟粘贴，并在约 450 毫秒后仅当剪贴板仍是该值时恢复原内容。同一用户下的其他软件可能观察到临时值，并发剪贴板修改也可能使恢复条件不成立。Codex 任务语音走另一条路径，提交前始终保留为待用户确认的草稿。

## 可选 Relay

只有开发者部署并初始化自己的 Cloudflare Worker 后，外网模式才会启用。应用载荷在 Apple 设备与 Mac 之间端到端加密；Cloudflare Worker secret store 保存允许的 room ID 和 bootstrap Mac bearer，Durable Object SQLite 保存 Token 哈希、随机生成的 Relay device UUID、初始化时间及重放/限流状态。Relay 不持久化密文，也不提供离线队列。

Cloudflare 终止 HTTPS，因此能看到 Bearer header；Cloudflare 和网络服务商还可观察 IP、时间、请求大小、请求频率和房间路径等元数据。部署者需自行负责 Cloudflare 配置、保留策略、司法辖区和隐私义务。

## Codex 集成

可选的本地 Hook 在回环地址接收任务元数据。Watch 会收到 thread/turn 标识、规范化的完整工作目录、最多 72 个字符的提示标题，以及最多 160 个字符的完成摘要。完成通知会把摘要或标题作为正文，并在通知 metadata 中保存 thread、turn 和 revision；根据 Apple Watch 的通知预览设置，这些文字可能出现在锁屏或通知中心。如任务内容敏感，请关闭通知预览或 Wrist Remote 通知。用户确认的回复会通过本机安装的 Codex CLI 提交。用户需自行了解所连接服务的隐私和数据保留政策。

## 诊断信息

本仓库不收集遥测。诊断输出保留在本机，除非用户主动分享。分享前必须移除凭据、标识、路径、转写、截图、日志和描述文件。

## 删除

删除 App 不一定会同步删除 Keychain 条目。如需完整删除，用户应在自己的设备上移除 App 容器、Application Support 数据和 Wrist Remote Keychain 条目。Relay 部署者还应删除自己的 Worker、Durable Object namespace 和 secrets。
