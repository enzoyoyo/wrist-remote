# 开发接口与协议

[English](../en/api.md)

本页描述当前带版本的 wire 接口：Relay protocol 3、LAN/Watch protocol 7、动作 profile format 1，以及本地 Codex Hook。协议版本要求精确匹配，不自动降级。`apps/WristRemote/Shared` 下的 Swift 文件只是 App 内部实现和测试 target，不是对外导出的 SwiftPM SDK。

## Relay HTTP/WSS API

所有 JSON 响应使用 `Content-Type: application/json` 和 `Cache-Control: no-store`。凭据必须放在 `Authorization: Bearer ...`；URL 中出现 `macToken` 或 `deviceToken` 查询参数会被拒绝。

### 健康检查

```http
GET /healthz
```

已配置返回 200：

```json
{"ok":true,"configured":true,"service":"wrist-remote-relay","protocolVersion":3}
```

### 初始化 room

```http
POST /v1/rooms/{roomUUID}/init
Authorization: Bearer <MAC_TOKEN>
Content-Type: application/json
```

请求体包含 `deviceID` 和 32 字节无填充 base64url `deviceToken`。首次匹配初始化返回 201；完全相同的重试返回 200；不同 credential 返回 409。不要手工构造生产请求，使用 `make deploy-relay`。

### Bridge WebSocket

```http
GET /v1/rooms/{roomUUID}/bridge
Authorization: Bearer <MAC_TOKEN>
Upgrade: websocket
```

新认证连接替换旧 Bridge。Relay 发出：

```json
{"type":"relayRequest","requestID":"<uuid>","frame":{"...":"encrypted frame"}}
```

Bridge 以同一 `requestID` 回应 `relayResponse`。文本 `ping` 由 Durable Object hibernation auto-response 回 `pong`。

### Device command

```http
POST /v1/rooms/{roomUUID}/command
Authorization: Bearer <DEVICE_TOKEN>
Content-Type: application/json
```

frame 外层字段：

| 字段 | 类型 | 说明 |
|---|---|---|
| `protocolVersion` | integer | 必须为 3 |
| `operationID` | UUID | 请求与响应关联及去重 |
| `senderID` | UUID | 序号隔离域 |
| `sequence` | non-negative integer | 每发送者、每方向单调递增 |
| `issuedAtEpochMilliseconds` | integer | 签发时间 |
| `expiresAtEpochMilliseconds` | integer | 过期时间 |
| `direction` | string | `deviceToMac` 或 `macToDevice` |
| `ciphertext` | base64 | ChaChaPoly combined data |

Header 字段作为 authenticated data，密文解开后才得到 operation。

operation kind：`status`、`profileUpdate`、`buttonEvent`、`voiceStart`、`audio`、`voiceStop`、`codexReplySubmit`。

### Relay 错误

稳定错误结构：

```json
{"error":{"code":"mac_offline","message":"Mac bridge is not connected; nothing was queued."}}
```

常见 code：

| HTTP | code | 含义 |
|---:|---|---|
| 400 | `invalid_frame`, `invalid_json`, `invalid_room_id` | 请求格式或时间/方向错误 |
| 401 | `unauthorized` | Bearer 缺失或不匹配 |
| 404 | `room_not_found`, `room_not_initialized`, `not_found` | room 或路径不存在 |
| 409 | `room_already_initialized`, `replay_detected` | credential 冲突或重放 |
| 413 | `payload_too_large`, `ciphertext_too_large_or_invalid` | 超过大小限制 |
| 415 | `unsupported_media_type` | 不是 JSON |
| 429 | `rate_limited` | 超过 room 限流；含 `Retry-After` |
| 502 | `bridge_disconnected`, `bridge_replaced`, `invalid_bridge_response` | Bridge 会话中断或响应无效 |
| 503 | `private_relay_not_configured`, `mac_offline` | 未配置或 Mac 离线 |
| 504 | `relay_timeout` | 15 秒内没有 Bridge 响应 |

## LAN / Watch protocol 7

LAN 使用 `_wristremote._tcp` 与 TCP `60927`。握手、六位确认和加密会话不是 HTTP API。主要 message kind：

- `buttonEvent`：command + press/release + profile revision。
- `voiceStart` / `voiceStop`：stream ID、语音 intent 和可选任务 identity。
- `requestStatus` / `status`：连接、映射、收藏、标题、语音、任务和 Relay provisioning。
- `favoritesUpdate`：四个收藏按钮。
- `codexTaskSnapshot`：任务 snapshot 或明确 clear tombstone。
- `voiceOutcome`：转写和最终音频确认。
- `codexReplySubmit`：已确认文本、submission ID 和精确任务 identity。

仓库内 App 使用 `apps/WristRemote/Shared` 的内部构造器和校验器。外部集成应使用本文档化的 Hook 与 Relay 接口；不要把这些内部 Swift 类型当成公开 package API，也不要绕过 wire schema 手写生产消息。

## 动作 profile format 1

按键 ID：

```text
power, up, left, ok, right, down, back, volume_up,
home, volume_down, menu, tv
```

每键必须完整包含 `singleClick`、`doubleClick`、`longPress`。绑定形状：

```json
{
  "action": "customShortcut",
  "shortcut": {
    "keyCode": 0,
    "modifierFlagsRawValue": 0,
    "keyLabel": "Example"
  },
  "applicationProfileID": null
}
```

`customShortcut` 必须包含合法 shortcut；`openCustomApplication` 必须包含由 Bridge 分配的 UUID profile ID。

## Codex Hook API

```http
POST http://127.0.0.1:60928/codex-hook
Authorization: Bearer <KEYCHAIN_TOKEN>
Content-Type: application/json
Content-Length: ...
```

生产调用应使用：

```bash
scripts/codex-notify.sh < hook-event.json
```

脚本安全读取 Keychain token。不要把 Bearer 放到示例命令、源文件或 shell 历史。字段和返回值见 [Codex 集成](codex-integration.md)。

## 兼容策略

- Relay、LAN 和 profile 各自版本化。
- 新字段若要兼容旧端必须是可选字段，并在三端测试缺失与存在两种情况。
- 改变手势语义、密钥派生域、direction、TTL、profile 完整性或任务 identity 时必须升级相应协议版本。
- 版本不兼容时明确拒绝，不回退到未认证或其他应用的传输。
