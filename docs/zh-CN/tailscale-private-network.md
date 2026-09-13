# Tailscale 私有网络模式

[English](../en/tailscale-private-network.md)

Tailscale 模式可在 Bonjour 局域网不可用或未在 head-start 窗口内 ready 时，为 iPhone 伴侣 App 到 Mac 建立另一条私有直连候选链路。它不会把 Mac 发布到公网，也不会替代 Wrist Remote 自己的配对、身份校验和加密会话。

## 连接顺序

```text
Apple Watch
    │ WatchConnectivity
    ▼
已配对 iPhone
    ├─ 先行 0.9 秒：Bonjour 局域网发现 → 加密 TCP → Mac Bridge
    └─ 延迟候选：官方 Tailscale IP → TCP 60927 → Mac Bridge
```

iPhone 先给 Bonjour 0.9 秒 head start。若届时局域网 candidate 尚未 ready 并被采用，则同时启动已配置的 Tailscale candidate；首个 ready 的 candidate 被采用，另一个会被取消。已采用或已连接的 route 不被抢占，下一轮重连再从局域网优先开始；局域网 candidate 失败或超时时也会立即启动 Tailscale。Tailscale 与局域网使用相同的双向身份握手、首次双端六位码批准和应用层加密。

Watch App 本身不加入 tailnet。手表实时操作仍要求配对 iPhone 可通过 [Watch Connectivity](https://developer.apple.com/documentation/watchconnectivity) 到达。若 Apple Watch 独立使用蜂窝网络、同时配对 iPhone 不可达，当前私有版会有意停止工作，不会回退到公网 Relay。

## 安全属性

- Mac 的 Tailscale listener 默认关闭，与局域网 listener 相互独立。
- 启用后只绑定 `utun` 上一个具体的 Tailscale 地址，范围限制为官方记录的 `100.64.0.0/10` 或 `fd7a:115c:a1e0::/48`，固定使用 TCP `60927`。
- 接受连接时还会校验来源地址属于 Tailscale 范围；不会绑定 `0.0.0.0`、`::`、物理公网地址或任意其他隧道地址。
- iPhone 只接受 Tailscale 官方 IPv4 或 IPv6 范围内的字面 IP；DNS 名称（包括 MagicDNS）、URL、账号信息、路径、任意端口、公网 IP 和无关私网 IP 都会被拒绝。
- 私有网络地址保存到 iPhone Keychain，并在每次读取时重新校验。
- Mac 与 iPhone 分别在自己的 Keychain 中保存长期 P-256 安装身份，并且只在专用条目不存在时创建。Keychain 被锁定、不可用、不可读或身份损坏时会停止连接，不会静默生成新身份。
- iPhone 验证 Mac 签名并使用首次信任（TOFU）：保存 Mac 指纹前显示六位码与截短指纹，并要求用户在 iPhone 明确批准；Mac 还会单独要求批准同一个六位码，再保存 iPhone 指纹。
- 后续连接要求双端固定身份同时匹配。Mac 指纹改变、iPhone 信任或身份存储不可读、签名无效、握手字段不完整，或 Mac 无法持久保存获批的 iPhone 指纹时，都会在会话 ready 或接受应用数据前拒绝连接。
- Tailnet 只提供网络访问层。Wrist Remote 仍会把双端安装身份绑定到本次密钥交换、协商绑定 transcript 的会话密钥并加密数据帧。
- 没有离线指令队列。Watch、iPhone 或 Mac 实时不可达时，动作会失败，不会在稍后补执行。

Tailscale 官方文档说明了[保留地址范围](https://tailscale.com/docs/reference/reserved-ip-addresses)和 [Grants](https://tailscale.com/docs/features/access-control/grants)。应按自己当前的 tailnet 配置复核这些规则。Wrist Remote 有意要求官方范围内的字面 IP，而不是 DNS 名称。

## 前置条件

1. 在 Mac 和已配对 iPhone 安装 Tailscale，并登录同一个 tailnet。
2. 确认两台设备都出现在 Tailscale 管理后台，且能互相访问。
3. 复制 Mac 的 Tailscale IPv4 或 IPv6 地址，并确认它位于 `100.64.0.0/10` 或 `fd7a:115c:a1e0::/48`。
4. 保持 iPhone 可被 Apple Watch 实时访问。
5. Mac、iPhone 与 Watch 安装相同版本的 Wrist Remote。

只填写字面 IP，例如：

```text
<MAC_TAILSCALE_IP>
```

该数值只是示例，不是默认地址。输入框中不要包含 DNS 名称、协议、端口、路径、用户名或密码。

## 配置 Mac

1. 打开 **腕上遥控桥**。
2. 在 **私有网络** 中启用 **允许 Tailscale 私有网络连接**。
3. 等待状态显示 **私有监听已就绪**。

这个开关与局域网服务相互独立。Tailscale 未运行或没有符合范围的隧道地址时，私网 listener 会保持等待，原有 Bonjour 局域网 listener 仍正常工作。

## 配置 iPhone

1. 打开 Wrist Remote 伴侣 App。
2. 在 **私有网络** 中启用 **启用 Tailscale 私有直连**。
3. 输入 Mac 的官方 Tailscale IP。
4. 点击 **保存并重新连接**。
5. 首次使用，或从尚未固定 Mac 身份的旧版本升级后，核对六位确认码，并分别在 iPhone 与 Mac 批准身份；两端批准完成前不会接受应用会话。

状态区会明确显示当前直接链路是 **局域网** 还是 **Tailscale 私有网络**。地址中无需填写端口，因为 Wrist Remote 固定使用 TCP `60927`。

## 身份恢复与旧版升级

从旧版直连协议升级后，需要明确完成一次双端配对，让 iPhone 固定 Mac 的长期身份。这是预期行为，不应自动绕过。

完成配对后，如果出现 **Mac 身份与已信任记录不一致**，它是安全阻断，不是普通网络故障。不要通过修改已保存 endpoint 或反复重连绕过。应先确认目标 Bridge 是否改用了新的 Bundle ID、Mac Keychain 是否被明确重置，或当前响应的是另一台 Mac。

只有确认身份更换是本人有意操作后，才能：

1. 打开 iPhone 伴侣 App。
2. 在连接状态下选择 **忘记已信任的 Mac**。
3. 重新连接，在两端核对新的六位码，并分别批准。

该操作只删除 iPhone 固定的 Mac 指纹，不会更改 Tailscale 地址、开放 listener、删除按键映射或修改其他遥控器。如果身份变化并非本人操作，应保持阻断并排查 Mac 与 tailnet。

**重置此 iPhone 的配对身份** 是另一项独立的破坏性恢复操作。只有在确认 iPhone 身份条目损坏，或明确需要创建新客户端身份时才能使用。App 会再次要求确认，不会更改 endpoint、按键映射或其他遥控器；Mac 必须把新身份视为新 iPhone，重新核对六位码并批准。损坏或不可读的身份绝不会被自动替换。

## 推荐的 VPN On Demand 设置

[Tailscale VPN On Demand](https://tailscale.com/docs/features/client/ios-vpn-on-demand) 可以在 iPhone 网络变化时保持或自动启动隧道。请对需要始终启用 Tailscale 的网络接口选择 **Always**。Wrist Remote 拒绝 DNS endpoint，因此不使用按主机名触发的规则。

Tailscale 明确说明 iOS 同一时间只能有一个 VPN App 启用 On Demand。如果其他 VPN 接管，应先重新连接 Tailscale 再测试 Wrist Remote。iPhone 重启后，先解锁一次再依赖 Watch 的实时连接：Wrist Remote 的直连身份与私网地址使用 `AfterFirstUnlockThisDeviceOnly` 钥匙串可访问级别，同时仍需确认 Watch/iPhone 会话实时可达。

## 推荐的最小权限 Grant

把来源限制为指定用户或设备，把目的地限制为 Mac 的 TCP `60927`。下面只是合成示例；所有占位符都应在 Tailscale 管理后台替换，不要把真实账号写入仓库：

```json
{
  "groups": {
    "group:wristremote-clients": ["user@example.invalid"]
  },
  "tagOwners": {
    "tag:wristremote-mac": ["autogroup:admin"]
  },
  "grants": [
    {
      "src": ["group:wristremote-clients"],
      "dst": ["tag:wristremote-mac"],
      "ip": ["tcp:60927"]
    }
  ]
}
```

只给目标 Mac 添加 `tag:wristremote-mac`。Grant 是叠加生效，较窄规则不会覆盖已有的宽泛放行；必须检查完整策略，并在确认不会影响其他服务后再移除不需要的宽泛权限。当前语法见 Tailscale 的 [Grant 示例](https://tailscale.com/docs/reference/examples/grants)。

## 明确不要启用的功能

- 不要为 TCP `60927` 配置路由器端口转发、UPnP/NAT-PMP 暴露、公网反向代理或通配监听。
- 不要使用 [Tailscale Funnel](https://tailscale.com/docs/features/tailscale-funnel)。Funnel 的用途是把服务提供给更广泛的互联网，不属于本模式的安全边界。
- Wrist Remote 直接连接原始 TCP listener，不需要 Tailscale Serve。
- 不要因为设备已在同一个 tailnet 就关闭 Wrist Remote 的配对或应用层加密。

## Termius

[Termius](https://termius.com/download/ios) 只是可选的 SSH 运维和诊断客户端，不是 Wrist Remote 的传输层，也不会创建 tailnet。不要把 Wrist Remote 的配对信息或加密凭据交给 Termius。若通过 Tailscale 使用 Termius，应为 SSH 的 `tcp:22` 单独配置最小权限 Grant，并确保 SSH 凭据不进入本仓库。

## 在不暴露 Mac 的前提下验收

1. iPhone 与 Mac 在同一 Wi-Fi 时，确认 App 显示 **已通过局域网连接**。
2. iPhone 切换到蜂窝网络并保持 Tailscale 已连接，确认显示 **已通过 Tailscale 私有网络连接**。
3. 确认 Mac Bridge 显示 **私有监听已就绪**，且不是公网监听地址。
4. 关闭 iPhone 上的 Tailscale。私网链路必须失败，不得回退到公网 IP，也不得在稍后补执行动作。
5. 验证公网 IP、任意私网 IP、DNS 名称与 URL 都会被 endpoint 校验拒绝；不得出现公网 listener 或 Relay 回退。
6. 仅在测试安装上验证替换后的 Mac 身份会被拒绝；随后使用 **忘记已信任的 Mac**，执行双端重新配对，并确认只有新身份成功固定后才能重连。
7. 复核现有局域网遥控器或其他输入设备仍保持原映射。Wrist Remote 使用独立标识、偏好、Keychain service、协议和动作配置。

以上属于真机验收门槛。自动化测试或 Simulator 构建通过，不能证明某一组真机上的 VPN 唤醒、Watch 可达性、震动和网络切换已经通过。

## 故障排查

| 现象 | 检查 |
|---|---|
| Mac 显示 **等待 Tailscale** | 启动 Mac 上的 Tailscale，确认 `utun` 接口上存在官方范围内的 Tailscale IPv4 或 IPv6 地址。 |
| iPhone 拒绝地址 | 使用 Tailscale 官方范围内的字面 IP，并删除 DNS 名称、`https://`、端口、斜杠、账号信息和空格。 |
| Wi-Fi 可用、蜂窝不可用 | 检查 iPhone Tailscale 状态、VPN On Demand、tailnet Grant 和蜂窝网络权限。 |
| 其他 VPN 正在运行 | iOS 同时只能让一个 VPN 使用 On Demand；重新连接 Tailscale 后重试。 |
| Watch 显示 iPhone 不可用 | 打开 iPhone 伴侣 App；iPhone 重启后先解锁一次，并确认 Watch/iPhone 会话实时可达。 |
| iPhone 不在身边时蜂窝 Watch 无法控制 | 这是当前私有版的预期边界。让配对 iPhone 回到 Watch Connectivity 可达范围；不存在公网回退。 |
| Mac 身份与已信任记录不一致 | 停止连接，先确认目标 Bridge 是否被本人有意更换；只有确认后才能使用 **忘记已信任的 Mac** 并重新完成双端配对。 |
