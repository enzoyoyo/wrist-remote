# 部署互联网 Relay

[English](../en/relay-deployment.md)

Relay 是可选功能。默认 `.invalid` URL 会禁用外网路径；局域网遥控不需要 Cloudflare。

## 安全模型

- 每位开发者把 Worker 部署到自己的 Cloudflare 账号；项目不提供共享生产 Relay。
- 一个部署只允许一个随机 UUIDv4 room。其他 room 在 Durable Object 创建前返回 404。
- Mac 主动建立出站 WSS，不需要端口映射、UPnP 或公网入站监听。
- 指令、音频、配置、摘要和回复使用端到端 ChaChaPoly 密文；E2E key 不发送给 Worker。
- Cloudflare edge 在鉴权时会接触 Bearer header。Worker secret store 长期保存 `ALLOWED_ROOM_ID` 和 `BOOTSTRAP_MAC_TOKEN`，且后者与客户端 Mac bearer 相同。
- Durable Object SQLite 持久化 Mac/device token 的 SHA-256 哈希、随机生成的 Relay device UUID、初始化时间，以及重放、序号和限流状态；不保存 bearer 明文、E2E key、ciphertext 或 plaintext payload。
- Cloudflare 仍可看到 IP、时间、请求大小、频率和 room URL 路径。Relay 不是匿名网络。
- ciphertext 只在请求和等待响应期间流经内存，不写入 SQLite，也不做离线队列。

若 Worker secrets 泄漏，攻击者可以得到 room ID 和 Mac bearer，在 Relay 鉴权层冒充 Mac、抢占连接或制造拒绝服务；没有客户端 E2E key 时仍不能解密应用 payload。应将 secret 泄漏视为必须立即轮换并重新 provisioning 的安全事件。

## 前置条件

1. 完成 [快速开始](getting-started.md)，并在 `Config/Local.xcconfig` 设置唯一 Bundle 前缀。
2. 使用 Node.js 24 或更新版本，与 CI 保持一致。
3. 登录开发者自己的 Cloudflare 账号：

```bash
cd apps/WristRemoteRelay
npx wrangler login
cd ../..
```

不要在仓库、shell 启动文件或命令行参数中保存 Cloudflare API Token。

## 部署

```bash
make deploy-relay
```

脚本按以下顺序执行：

1. 确认本地配置和唯一 Bundle 前缀。
2. 安装缺失的锁定 npm 依赖。
3. 生成 Worker 类型、执行严格 TypeScript 检查和 Vitest。
4. 使用当前 Wrangler 登录部署 Worker。
5. 从 Wrangler 输出取得开发者自己的 HTTPS `workers.dev` URL；无法识别时可只为本次命令设置 `WRISTREMOTE_RELAY_BASE_URL`。
6. 在本机安全生成或复用 room、device、两个 bearer token 和 E2E key。
7. 把 Bridge credentials 写入 Keychain。
8. 通过 stdin 设置 `ALLOWED_ROOM_ID` 和 `BOOTSTRAP_MAC_TOKEN` Worker secrets，不打印值。
9. 把 Relay URL 写进被忽略的 `Config/Local.xcconfig` 并保持 `0600`。
10. 轮询 `/healthz`，要求配置完成。

首次启动新版 Mac Bridge 时，它会调用 room 初始化接口，Worker 才会把 Mac/device token 的 SHA-256 哈希、随机生成的 Relay device UUID、初始化时间，以及重放、序号和限流状态写入该 room 的 SQLite。客户端 bearer 和 E2E 凭据按角色保存在 Mac、iPhone/Watch 的 Apple Keychain；Worker secret store 中仍长期保留两个部署 secrets。

## 重新构建

Relay URL 是构建配置，不是远程下发设置。部署成功后重新构建和安装三端：

```bash
make install-mac
make install-devices
```

然后先在局域网连接一次，使 iPhone 从 Bridge 获得 device provisioning 并通过 WatchConnectivity 传给 Watch。

## 健康检查

```bash
curl --fail "<RELAY_BASE_URL>/healthz"
```

预期响应：

```json
{"ok":true,"configured":true,"service":"wrist-remote-relay","protocolVersion":3}
```

缺少或格式错误的 secrets 会返回 HTTP 503 且 `configured=false`。健康接口不证明 Mac 已连接，也不执行按键。

## API 和限制

Relay 同时识别根路径以及可选的 `/wristrelay` 前缀：

| 方法 | 路径 | 鉴权 | 用途 |
|---|---|---|---|
| GET | `/healthz` | 无 | 配置和协议健康 |
| POST | `/v1/rooms/{room}/init` | Mac bearer | 单次 room 初始化；相同重试幂等 |
| GET + Upgrade | `/v1/rooms/{room}/bridge` | Mac bearer | Mac 出站 WebSocket |
| POST | `/v1/rooms/{room}/command` | Device bearer | 密文指令和同步操作 |

当前限制：

- Relay protocol `3`。
- ciphertext 解码后最大 512 KiB；外层 JSON 最大 720 KiB。
- frame 生命周期最大 30 秒，并允许最多 30 秒时钟偏差。
- room 每 10 秒最多 120 次认证 command 尝试。
- 等待 Mac 响应最多 15 秒。
- Mac 离线立即返回 `mac_offline`，不会排队。
- Watch 按键还有更严格的 3 秒本地提交新鲜度门禁。

完整响应和错误定义见 [API](api.md)。

## 自定义域名

仓库默认不包含真实 route 或 account ID。若在自己的 fork 中添加 Cloudflare custom domain 或 route，必须：

1. 保持 HTTPS。
2. 把最终根 URL 作为本次部署的 `WRISTREMOTE_RELAY_BASE_URL`。
3. 重新构建三端。
4. 确认根路径或 `/wristrelay` 前缀与 Worker route 一致。
5. 重新运行健康检查和外网真机验收。

## 轮换、撤销和删除

当前 provisioning 工具会复用同一 Bundle 前缀下已有的 Keychain credentials；重复部署不是密钥轮换。

- 紧急撤销：在 Cloudflare 中禁用/删除 Worker，或把允许的 room secret 改为新的随机值。旧 room 会立即不可路由。
- 完整重配：先退出相关 App，通过 Keychain Access 删除该 Bundle 前缀对应的 Wrist Remote Relay credential，再重新部署和重装三端。该操作不可逆，应先保留动作映射备份。
- 完整删除：删除 Worker、Worker secrets、Durable Object namespace，以及 Apple 设备和 Mac 上对应的 Keychain/App 数据。

不要通过公开问题、日志或截图传递 room ID、token、E2E key 或 provisioning 内容。

## 真机验收

至少验证：

1. LAN 可用时显示并使用 LAN。
2. 在不关闭 App 的情况下切换到非局域网网络，Watch 显示互联网路径。
3. 单击、双击、长按语义不受 WAN 延迟影响。
4. 断网期间的按键不会在恢复后补执行。
5. Mac 离线得到明确失败。
6. 中文普通前台语音完成识别并立即注入；Codex 语音完成草稿、确认和最终回执。
7. 恢复 LAN 后自动切回。

测试前使用无破坏性的动作；CI 和 `/healthz` 不能替代这些步骤。
