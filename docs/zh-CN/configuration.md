# 配置参考

[English](../en/configuration.md)

## 配置层级

1. `Config/WristRemote.xcconfig`：仓库跟踪的安全默认值。
2. `Config/Local.xcconfig`：开发者本地覆盖，已被 Git 忽略并应保持 `0600`。
3. Apple Keychain：安装身份、Hook token，以及 Mac、iPhone/Watch 各自所需的 Relay bearer 和 E2E 凭据。
4. Cloudflare Worker secret store：长期保存允许的 room ID 与 `BOOTSTRAP_MAC_TOKEN`；后者与客户端 Mac bearer 相同。
5. 单次环境变量：只用于消除设备、Team 或安装目标歧义。

不要把运行时 secret 放在 xcconfig、`.env`、Wrangler 配置、命令参数、截图或问题报告中。

## Xcode 配置

| 变量 | 必需 | 说明 |
|---|---:|---|
| `WRISTREMOTE_BUNDLE_PREFIX` | 真机需要 | 自己控制的唯一反向域名；生成 `.ios`、`.watchkitapp`、`.bridge` 和测试 Bundle ID |
| `WRISTREMOTE_DEVELOPMENT_TEAM` | 真机需要 | 开发者自己的 10 位 Team ID；仅用于本地签名 |
| `WRISTREMOTE_RELAY_BASE_URL` | 外网需要 | HTTPS Relay 根 URL；`.invalid` 值会安全禁用外网 |
| `WRISTREMOTE_CODEX_EXECUTABLE_PATH` | 否 | 自定义 Codex 可执行文件路径；留空时 Bridge 安全自动发现 |

修改 xcconfig 后要重新生成/构建相关 App。Relay URL 会编入三端 Info.plist，因此部署 Relay 后需重新构建 Mac、iPhone 和 Watch。

## 单次环境变量

| 变量 | 使用位置 | 说明 |
|---|---|---|
| `WRIST_DEVELOPER_DIR` | 真机安装 | 指定一次 Xcode Developer 目录，不修改全局 `xcode-select` |
| `WRIST_TEAM_ID` | 真机安装 | 自动发现多个 Team 时指定一个 |
| `WRIST_IPHONE_UDID` | 真机安装 | 自动发现多个 iPhone 时指定一个 |
| `WRIST_WATCH_UDID` | 真机安装 | 自动发现多个 Watch 时指定一个 |
| `WRIST_CODESIGN_IDENTITY` | Mac 构建 | 替代默认 ad-hoc 签名 |
| `WRISTREMOTE_INSTALL_DIR` | Mac 安装 | 替代默认用户 Applications 目录 |
| `WRISTREMOTE_RELAY_BASE_URL` | Relay 部署脚本 | Wrangler 输出无法自动识别时仅为该命令提供 HTTPS URL |

这些变量可能出现在进程环境中。只在需要时设置，命令结束后清除，不要放进 shell 启动文件。

## Bundle ID 与 Keychain

Bundle 前缀必须唯一，且不能保留 `example` 占位值。Keychain service 从最终 Bundle ID 或前缀派生，包括：

- iPhone 和 Watch 的安装/Relay provisioning；
- Bridge 的 Relay credentials；
- Bridge 的 Codex Hook bearer token。

更换 Bundle 前缀相当于新安装：旧前缀下的 Keychain、偏好和配对状态不会自动迁移。

## Relay 配置

`apps/WristRemoteRelay/wrangler.jsonc` 只包含通用 Worker、Durable Object binding 和 migration。它不包含 Cloudflare account ID、真实 route 或 secret，默认通过开发者自己的 `workers.dev` 地址部署，且 observability 关闭。

两个 Worker secret：

| 名称 | 来源 | Worker 用途 |
|---|---|---|
| `ALLOWED_ROOM_ID` | 本机安全随机生成 | 在创建 Durable Object 前拒绝其他 room |
| `BOOTSTRAP_MAC_TOKEN` | 本机安全随机生成，与客户端 Mac bearer 同值 | 认证 room 初始化；初始化后同一 bearer 通过 DO 中的哈希鉴权 |

Mac、iPhone/Watch 按角色把 device/Mac bearer 和 E2E 凭据保存到各自 Apple Keychain。Cloudflare edge 在鉴权时会接触 Bearer header；Worker secret store 长期保存上述两个部署 secrets。Durable Object SQLite 保存 Mac/device token 的 SHA-256 哈希、随机生成的 Relay device UUID、初始化时间，以及重放、序号和限流状态；不保存 bearer 明文、E2E key、ciphertext 或 plaintext payload。

`BOOTSTRAP_MAC_TOKEN` 泄漏允许攻击者在 Relay 鉴权层冒充 Mac、抢占连接或制造拒绝服务；没有 E2E key 时仍不能解密应用 payload。发生泄漏时应立即轮换 secrets 并重新 provisioning。

## 本地端口和服务

| 接口 | 地址 | 用途 |
|---|---|---|
| LAN Bridge | `_wristremote._tcp`, TCP `60927` | iPhone 与 Mac 的专用配对和加密协议 |
| Codex Hook | `127.0.0.1:60928/codex-hook` | 带 Bearer 的本机任务事件 |
| Relay | 开发者自己的 HTTPS URL | 可选公网密文传输 |

不要用路由器端口转发暴露 `60927` 或 `60928`。

## 动作配置

动作配置由 iPhone 管理，完整包含 12 键 × 3 手势。可用动作包括基本按键、方向键、复制/粘贴/退出、显示桌面、上下文菜单、App 切换、音量/媒体、自定义快捷键和经过 Mac Bridge 选择的自定义 App。

自定义 App 使用 Bridge 生成的内部 profile ID，而不是由 iPhone 接收任意文件路径或 Bundle ID。删除或替换 Mac 端 App 配置后，应等待最新 profile revision 同步完成再测试。

## 权限

- Watch 麦克风：仅在用户启动语音时采集。
- iPhone/Bridge 本地网络：Bonjour 和局域网链路。
- Bridge 辅助功能：按键动作和普通前台语音文本注入。
- Bridge 语音识别：系统 Speech Framework。
- 登录时启动：由用户在 Bridge 中选择，不是构建脚本的默认副作用。

权限被拒绝时功能应明确失败，不应回退到其他应用或全局输入链路。

普通前台语音使用系统通用剪贴板模拟 Command-V：识别文本会短暂出现在剪贴板中，约 450 ms 后仅在剪贴板未被其他进程改变时恢复原内容。该路径不适合注入密码、token 或其他秘密；需要完全避免共享剪贴板暴露时应关闭普通语音输入。Codex 任务语音使用独立的草稿确认流程，不会把未确认草稿自动提交给 Codex。
