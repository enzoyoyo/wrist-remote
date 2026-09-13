# 配置参考

[English](../en/configuration.md)

## 配置层级

1. `Config/WristRemote.xcconfig`：仓库跟踪的安全默认值。
2. `Config/Local.xcconfig`：开发者本地覆盖，已被 Git 忽略并应保持 `0600`。
3. Apple Keychain：Mac 与 iPhone 安装身份、iPhone 固定的 Mac 指纹与经过校验的 Tailscale IP、Mac 信任的 iPhone 指纹，以及 Hook token。
4. Relay 凭据只属于另行安全审查的 Relay 版本，不在当前个人版的有效边界内。
5. 单次环境变量：只用于消除设备、Team 或安装目标歧义。

不要把运行时 secret 放在 xcconfig、`.env`、Wrangler 配置、命令参数、截图或问题报告中。

## Xcode 配置

| 变量 | 必需 | 说明 |
|---|---:|---|
| `WRISTREMOTE_BUNDLE_PREFIX` | 真机需要 | 自己控制的唯一反向域名；为新安装生成移动端、Bridge 和测试 Bundle ID 的安全默认值 |
| `WRISTREMOTE_IOS_BUNDLE_IDENTIFIER` | 否 | iPhone App 的精确 Bundle ID；默认是 `$(WRISTREMOTE_BUNDLE_PREFIX).ios`，只在经核实的原位升级中覆盖 |
| `WRISTREMOTE_WATCH_BUNDLE_IDENTIFIER` | 否 | Watch App 的精确 Bundle ID；默认位于 iPhone ID 的 `.watchkitapp` 命名空间，必须与现装 Watch App 完全一致 |
| `WRISTREMOTE_BRIDGE_BUNDLE_IDENTIFIER` | 否 | 经审查的 Mac Bridge 就地升级所用显式 Bundle ID 覆盖；默认是 `$(WRISTREMOTE_BUNDLE_PREFIX).bridge` |
| `WRISTREMOTE_EXISTING_INSTALL_REQUIRED` | 否 | 默认 `NO`；受控移动端升级设为 `YES`，要求两台真机都已安装精确匹配的 App |
| `WRISTREMOTE_DEVELOPMENT_TEAM` | 真机需要 | 开发者自己的 10 位 Team ID；仅用于本地签名 |
| `WRISTREMOTE_PRIVATE_ONLY` | 个人版 | 必须为 `YES`；在构建/配置层禁用公网 Relay |
| `WRISTREMOTE_RELAY_BASE_URL` | 私有版 | 必须保留在预留的 `.invalid` 顶级域下；这是排除公网 Relay 的第二道门禁 |
| `WRISTREMOTE_CODEX_EXECUTABLE_PATH` | 否 | 自定义 Codex 可执行文件路径；留空时 Bridge 安全自动发现 |

修改 xcconfig 后要重新生成/构建相关 App。个人版只有在两道 Relay 门禁同时存在时才可验收：`WRISTREMOTE_PRIVATE_ONLY = YES`，且产物内编入 `.invalid` Relay URL。

## 单次环境变量

| 变量 | 使用位置 | 说明 |
|---|---|---|
| `WRIST_DEVELOPER_DIR` | 真机安装 | 为当前命令显式指定 Xcode Developer 目录，不修改全局 `xcode-select`；只有显式指定时才允许预发布版 |
| `WRIST_TEAM_ID` | 真机安装 | 自动发现多个 Team 时指定一个 |
| `WRIST_IPHONE_UDID` | 真机安装 | 自动发现多个 iPhone 时指定一个 |
| `WRIST_WATCH_UDID` | 真机安装 | 自动发现多个 Watch 时指定一个 |
| `WRIST_CODESIGN_IDENTITY` | Mac 构建 | 自动选择存在歧义时，精确指定一个本机有效 Apple Development 身份 |
| `WRISTREMOTE_INSTALL_DIR` | Mac 安装 | 替代默认用户 Applications 目录 |
| `WRISTREMOTE_RELAY_BASE_URL` | Relay 部署脚本 | Wrangler 输出无法自动识别时仅为该命令提供 HTTPS URL |

这些变量可能出现在进程环境中。只在需要时设置，命令结束后清除，不要放进 shell 启动文件。

### Mac 构建签名选择

`make install-mac` 和 `scripts/build-macos.sh` 会检查本机有效的代码签名身份，但不会打印或持久化证书名称、哈希或 Team ID：

1. 非空的 `WRIST_CODESIGN_IDENTITY` 必须以完整证书哈希或完整 common name 精确匹配唯一一个本机有效 `Apple Development` 身份；无效、非开发身份或存在歧义都会停止构建。
2. 未指定覆盖值时，若恰好只有一个有效 `Apple Development` 身份，脚本会自动使用它，使重复本机安装具有稳定签名。
3. 若存在多个有效 `Apple Development` 身份，脚本会停止而不是猜测。
4. 只有完全不存在有效 `Apple Development` 身份时才使用 ad-hoc 签名；不允许通过 `WRIST_CODESIGN_IDENTITY=-` 强制降级为 ad-hoc。

选中的身份只存在于构建进程内存中，并直接传给 `codesign`；脚本的状态和错误提示不会包含身份细节。该方式仍属于本机开发安装，不是经过 Developer ID 公证的发行包。

## Bundle ID 与 Keychain

Bundle 前缀必须唯一，且不能保留 `example` 占位值。Keychain service 从最终 Bundle ID 或前缀派生，包括：

- iPhone 与 Watch 的安装身份和 private-only Relay 撤销标记；
- iPhone 私有网络 endpoint 配置；
- Mac 长期 P-256 服务端身份、iPhone 固定的 Mac 指纹，以及 Mac 信任的 iPhone 指纹；
- Bridge 的 private-only Relay 排除/撤销状态；
- Bridge 的 Codex Hook bearer token。

更换 Bundle 前缀或任一最终 Bundle ID 相当于创建新的安装身份：旧身份下的 Keychain、偏好、固定指纹和配对状态不会自动迁移，并可能在设备上产生第二个 App。

### iPhone 与 Watch 受控原位升级

只有在现有安装的精确身份已经从已签名产物、有效描述文件和真机列表分别核对后，才在被 Git 忽略的 `Config/Local.xcconfig` 同时设置 `WRISTREMOTE_IOS_BUNDLE_IDENTIFIER`、`WRISTREMOTE_WATCH_BUNDLE_IDENTIFIER` 与 `WRISTREMOTE_EXISTING_INSTALL_REQUIRED = YES`。不要把这些本机值复制到公开配置。

`scripts/install-devices.command --dry-run` 与实际安装都会验证：Watch ID 严格从 iPhone ID 派生、两个 ID 都不是占位值、当前 Apple Development Team 与历史描述文件的身份（新构建的描述文件仍必须在有效期内）一致，并且连接中的 iPhone 与 Watch 均存在精确同一身份。若发现同名但不同 ID 的 App、设备不可读、历史 profile 不匹配或现装 App 缺失，脚本会在构建/安装前停止。实际构建完成后还会再次读取两台真机，作为写入前的最终身份门禁。

该覆盖只改变移动端目标；`WRISTREMOTE_BRIDGE_BUNDLE_IDENTIFIER` 必须独立保持为当前已安装 Bridge 的身份，避免切换其 Keychain service 和长期服务器密钥。

### Mac Bridge 受控升级

`make install-mac` 安装到默认的用户级位置。如需升级其他位置中已核实的 Bridge，使用：

```bash
scripts/build-macos.sh --install --target-app /absolute/path/WristRemoteBridge.app
```

目标必须是非符号链接的绝对 `.app` 路径。安装脚本会比较现有目标可读取的 Bundle ID 与已验证构建产物，二者不一致时拒绝覆盖。若经确认的历史目标没有使用由前缀生成的默认 ID，只能在独立核对目标及其 Bundle ID 后，把 `WRISTREMOTE_BRIDGE_BUNDLE_IDENTIFIER` 写入已忽略的 `Config/Local.xcconfig`。

脚本会在构建前、替换前和打开安装结果前检查所有名为 `WristRemoteBridge` 的运行中进程，包括目标本身。只要存在运行中 Bridge，或某个进程无法解析到精确 App 路径，安装就会 fail closed。脚本不会发送结束信号；请正常退出所有 Bridge 后重试。该门禁避免替换期间第二个 Bridge 保留或争抢 TCP `60927`。

## 排除公网 Relay

当前个人版不部署、也不使用公网 Relay，必须同时保留两道独立门禁：

1. 构建配置中的 `WRISTREMOTE_PRIVATE_ONLY = YES`。
2. 位于预留 `.invalid` 顶级域下的 `WRISTREMOTE_RELAY_BASE_URL`。

不能为了让远程连接可用而换成非 `.invalid` 地址。仓库中存在 Relay 源码、部署说明或测试，不代表当前产物启用了 Relay。任何启用都需要单独的安全审查、构建、凭据配置与真机验收决定。

## 本地端口和服务

| 接口 | 地址 | 用途 |
|---|---|---|
| LAN Bridge | `_wristremote._tcp`, TCP `60927` | iPhone 与 Mac 的专用配对和加密协议 |
| Tailscale Bridge | 一个具体 Tailscale `utun` 地址，TCP `60927` | 使用同一配对和加密协议的可选私有网络备用链路 |
| Codex Hook | `127.0.0.1:60928/codex-hook` | 带 Bearer 的本机任务事件 |
| Relay | 已禁用 | 由私有版构建标志与 `.invalid` endpoint 双重排除 |

不要通过路由器端口转发、Tailscale Funnel、公网代理或公网通配监听暴露 `60927` 或 `60928`。

## Tailscale 私有网络配置

私有网络模式属于运行时配置，不使用 xcconfig：

1. Mac Bridge 保存一项独立的 `tailnetAccessEnabled` 偏好，默认值为 `false`，不会改变局域网 listener。
2. 启用后，Bridge 只查找 `utun` 上属于 Tailscale 官方 `100.64.0.0/10` 或 `fd7a:115c:a1e0::/48` 范围的具体地址，并在固定 TCP `60927` 启动独立 listener。
3. iPhone 把启用状态和经过校验的地址保存到自己的 Keychain service。地址必须是 Tailscale 官方 IPv4 或 IPv6 范围内的字面 IP。DNS 名称（包括 MagicDNS）、URL、路径、账号信息、任意端口、公网 IP 和无关私网 IP 都会被拒绝。
4. iPhone 先给 Bonjour 0.9 秒 head start；若局域网 candidate 届时尚未 ready 并被采用，则同时启动私有网络 candidate，首个 ready 的 candidate 获胜并取消另一个。已采用的 route 不被抢占，下一轮重连再从局域网优先开始；局域网失败或超时时会立即启动私有网络 candidate。
5. 局域网与 Tailscale 路径使用相同的双向安装身份校验、首次双端批准、绑定 transcript 的会话密钥协商和数据帧加密。

使用 [VPN On Demand](https://tailscale.com/docs/features/client/ios-vpn-on-demand) 控制 iPhone 隧道唤醒；使用最小权限 [Grant](https://tailscale.com/docs/features/access-control/grants)，只允许指定来源访问 Mac 的 `tcp:60927`。请直接填写 Mac 的官方 Tailscale IP，不使用 MagicDNS、Funnel、路由器端口转发或公网代理。完整配置和验收步骤见 [tailscale-private-network.md](tailscale-private-network.md)。

Watch 不接收或保存 Tailscale 地址。它通过 Watch Connectivity 把实时命令交给配对 iPhone，由 iPhone 管理两条直连路径。当前私有版在 iPhone 不可达时有意不支持独立蜂窝使用，也不会回退到公网 Relay。

## 直连配对身份生命周期

- Mac 只有在专用 Keychain 条目不存在时才创建长期 P-256 签名身份；条目被锁定、不可用或损坏时，两条直连 listener 都会停止，不会静默换钥。
- iPhone 的长期 P-256 客户端身份遵循同样的 fail-closed 规则：只在专用条目不存在时创建；条目锁定、不可读或损坏时拒绝连接，不会静默换钥。
- iPhone 先验证 Mac 签名，再显示信任界面。首次使用时需在 iPhone 本地批准，并发送同时绑定该 Mac 与本次临时密钥交换的客户端身份证明；Mac 也批准该会话后，iPhone 才保存 Mac 指纹。
- Mac 把获批的 iPhone 安装指纹保存到自己的 Keychain；只有客户端声明已经固定本 Mac 时，后续才允许自动重连。若该 Keychain 写入失败，Mac 会发送拒绝且不会把会话标记为 ready。因此，从早期单向信任流程升级后需要完成一次双端明确配对。
- 已保存 Mac 指纹不匹配、iPhone 信任存储不可用、签名无效或握手不完整时都会 fail closed。为同一台已验证 Mac 更新保存的官方 Tailscale IP，不会自行替换或重置固定的 Mac 身份。
- 若目标 Bridge 确实被本人重装并产生新身份，应先在 App 外确认该变更，再在 iPhone 选择 **忘记已信任的 Mac**，重新执行双端六位码配对。该操作只删除 iPhone 固定的 Mac 指纹，不会改变 endpoint 或按键映射。
- 只有在确认 iPhone 身份条目损坏，或明确需要新客户端身份时，才使用 **重置此 iPhone 的配对身份**。该破坏性操作另有二次确认，不会改变按键映射或其他遥控器；Mac 会把它视为新 iPhone，必须重新核对六位码并批准。

## 动作配置

动作配置由 iPhone 管理，完整包含 12 键 × 3 手势。可用动作包括基本按键、方向键、复制/粘贴/退出、显示桌面、上下文菜单、App 切换、音量/媒体、自定义快捷键和经过 Mac Bridge 选择的自定义 App。

自定义 App 使用 Bridge 生成的内部 profile ID，而不是由 iPhone 接收任意文件路径或 Bundle ID。删除或替换 Mac 端 App 配置后，应等待最新 profile revision 同步完成再测试。

## 权限

- Watch 麦克风：仅在用户启动语音时采集。
- iPhone/Bridge 本地网络：Bonjour 和局域网链路。
- iPhone 与 Mac 上的 Tailscale VPN：可选私有网络路径，由 Tailscale App 和操作系统控制，不由 Wrist Remote 管理。
- Bridge 辅助功能：按键动作和普通前台语音文本注入。
- Bridge 语音识别：仅供普通前台听写使用的系统 Speech Framework。
- 登录时启动：由用户在 Bridge 中选择，不是构建脚本的默认副作用。

权限被拒绝时功能应明确失败，不应回退到其他应用或全局输入链路。

普通前台听写使用系统 Speech Framework 与通用剪贴板模拟 Command-V：识别文本会短暂出现在剪贴板中，约 450 ms 后仅在剪贴板未被其他进程改变时恢复原内容。该路径不适合注入密码、token 或其他秘密；需要完全避免共享剪贴板暴露时应关闭普通语音输入。

Codex 任务语音是另一条独立路径：Watch 录制 PCM，Mac 写入仅文件所有者可读写的临时 WAV，再由 Bridge 使用已登录 Codex 账号进行第一方联网转写。再次校验所选目标后，通过本机 app-server 把返回文字排入任务。这需要互联网，不需要 macOS Speech 权限，也不使用剪贴板。新任务必须先完成无 parent/fork 关系的独立 `thread/start`，并成为已有目标后才启用语音。临时音频在处理结束、取消或音频流断线后删除；损坏的音频流 fail closed，绝不自动重放。
