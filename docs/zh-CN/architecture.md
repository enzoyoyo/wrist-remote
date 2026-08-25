# 架构

[English](../en/architecture.md)

Wrist Remote 把交互、配置、动作执行和公网中继分离。默认只使用局域网；外网模式是由开发者显式启用的自托管扩展。

## 数据流

```text
Apple Watch
  ├─ LAN：WatchConnectivity → iPhone → 加密 TCP → Mac Bridge
  └─ WAN：E2E 加密 HTTPS → Cloudflare Worker / Durable Object
                                           ↓
                                   Mac 主动建立 WSS

Codex Hook 生产者 → 带 Bearer 的回环 HTTP → Mac Bridge → 本机 Codex CLI
```

Mac 不开放公网入站端口。公网 Relay 是一个可从互联网访问的 HTTPS 端点，但 Watch、iPhone 和 Mac 都是客户端或出站连接方。

## 组件职责

### Watch

- 提供 12 个虚拟按键、收藏、任务状态和语音入口。
- 在本地提交单击、双击和长按，避免 WAN 延迟改变手势语义。
- 在提交时触发语义化震动；系统“减弱动态效果”只影响视觉动效。
- 通过 WatchConnectivity 使用 iPhone 局域网链路，或在前台直接使用已配置的 HTTPS Relay。

### iPhone

- 保存和编辑 Watch 专属动作配置。
- 每份配置完整包含 12 个按键以及每键的三种触发方式。
- 发现 Bonjour 服务、完成配对、建立局域网加密会话，并把配置和 Relay provisioning 传给 Watch。

### Mac Bridge

- 发布 `_wristremote._tcp`，使用固定本地端口 `60927`。
- 校验局域网来源、协议角色、能力和配置修订号。
- 通过 Accessibility 执行有限动作；不提供通用远程 shell。
- 使用系统 Speech Framework 转写 Watch 音频。
- 仅在 `127.0.0.1:60928` 提供经过认证的 Codex Hook。
- 对 Relay 只建立出站 WebSocket。

### Cloudflare Relay

- 一个部署对应一个允许的私有 room；Durable Object 以 room ID 确定性路由。
- Worker secret store 长期保存 `ALLOWED_ROOM_ID` 和 `BOOTSTRAP_MAC_TOKEN`；后者与客户端 Mac bearer 相同。
- Cloudflare edge 在鉴权时会接触请求中的 Bearer header。
- Durable Object SQLite 保存 Mac/device token 的 SHA-256 哈希、随机生成的 Relay device UUID、初始化时间，以及重放、序号和限流状态。
- 内存只保存等待 Mac 响应的短期关联；15 秒超时后失败。
- 不解密应用负载、不持久化 ciphertext、不提供离线队列。

## 局域网安全会话

首次会话使用 Curve25519 密钥协商，P-256 安装身份对临时会话公钥签名，双方显示由会话密钥派生的六位确认码。用户批准后，消息使用 ChaChaPoly 认证加密。Mac 只接受回环、链路本地、私有 IPv4/IPv6 以及与物理接口同前缀的 IPv6 来源，不解析主机名来绕过来源检查。

## 互联网会话

Bridge 首次 provisioning 产生互相独立的 room ID、device ID、device token、Mac token 和 32 字节端到端密钥。Mac、iPhone/Watch 按各自角色把所需 bearer 和 E2E 凭据保存在 Apple Keychain；E2E 密钥不发送给 Relay。Cloudflare Worker secret store 另存允许的 room ID，以及与 Mac bearer 同值的 bootstrap token。

Worker secret 泄漏会暴露 room ID 和 Mac bearer。攻击者可在 Relay 鉴权层冒充 Mac、抢占连接或制造拒绝服务；但没有客户端 E2E key 时仍不能解密应用 payload。Bearer header 会经过 Cloudflare edge；Durable Object 使用 token 哈希而非 bearer 明文持久化，不代表 Cloudflare 从未接触 bearer 明文。

设备请求包含协议版本、operation ID、sender ID、单调序号、签发/过期时间、方向和 ciphertext。Relay 与端点共同执行版本、时间、大小、方向、重放和响应匹配检查。公网按键还携带 Watch 本地提交时间；超过 3 秒的旧按键不会在网络恢复后补执行。

## 路由选择

局域网可用时优先使用局域网。一次按键手势或短队列在完成前固定使用同一路由，避免后发局域网动作越过先发公网动作。Relay 不可达不会自动把旧动作排队。状态界面必须区分“局域网”“互联网”和“离线”，不能把入队或加密成功显示成动作已执行。

## 配置一致性

动作配置使用修订号。Mac 只在完整验证并安装目标修订后执行动作；旧修订、缺失按键或不支持的动作会被拒绝。任务状态另有单调状态修订号和清除 tombstone，避免旧的完成摘要在重连后复活。

## 语音和任务回复

Watch 发送 PCM 音频，Mac 负责语言选择、重排、转写和结果回执。普通前台语音识别完成后立即通过 `BridgeTextInjector` 注入当前焦点输入框，不经过草稿确认；Codex 语音必须绑定当前任务的 thread、turn 和 revision。只有任务仍是同一个已完成任务且用户确认草稿时，Bridge 才调用本机 Codex CLI。

`BridgeTextInjector` 会把识别文本短暂写入系统通用剪贴板并模拟 Command-V。约 450 ms 后，只有剪贴板仍是这段临时文本且期间未发生变更时才恢复原内容。其他同一用户进程可能在这段窗口内观察到文本；若其他进程改变了剪贴板，Bridge 会保留新内容而不覆盖它，但原剪贴板内容可能无法自动恢复。

## 持久化

| 数据 | 位置 |
|---|---|
| 动作映射、收藏和布局 | Apple App 自有容器 |
| 配对身份、Hook token、各客户端所需 Relay credentials、E2E key | Apple Keychain |
| `ALLOWED_ROOM_ID`、与 Mac bearer 同值的 `BOOTSTRAP_MAC_TOKEN` | Cloudflare Worker secret store |
| 自定义 App 选择、任务提交台账 | Mac Bridge 自有偏好或 Application Support |
| Mac/device token SHA-256 哈希、Relay device UUID、初始化时间、replay/序号与限流状态 | 用户部署的 Durable Object SQLite |
| Relay ciphertext | 不持久化 |

Cloudflare edge 还会在鉴权时接触 Bearer header；Cloudflare 和网络提供商可观察 IP、时间、大小、频率和 room URL 路径。详细边界见仓库根目录的 `THREAT_MODEL.md`。
