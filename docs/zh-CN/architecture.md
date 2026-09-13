# 架构

[English](../en/architecture.md)

Wrist Remote 把交互、配置和动作执行分离。仓库当前的个人构建是仅私有网络版：局域网优先，Tailscale 是可选私有候选链路，公网 Relay 同时被构建标志和 endpoint 配置禁用。

## 数据流

```text
Apple Watch
  ├─ 前台 LAN 按键：加密 HTTP :60929 → Mac Bridge
  ├─ LAN 中转与语音：WatchConnectivity → iPhone → 加密 TCP :60927 → Mac Bridge
  └─ 私有外网：WatchConnectivity → iPhone → Tailscale TCP → Mac Bridge

Codex Hook 生产者 → 带 Bearer 的回环 HTTP :60928 → Mac Bridge
Codex 语音：Mac Bridge → Codex 联网转写 → 文字 → 本机 app-server stdin/stdout → 所选任务
```

Mac 不开放公网入站端口。仅私有网络构建也拒绝公网 Relay provisioning 和请求。Tailscale Funnel、路由器端口转发、公网代理和公网通配监听不属于支持架构。

## 组件职责

### Watch

- 提供 12 个虚拟按键、收藏、任务状态、最近会话选择、独立任务创建和原始语音入口。
- 在本地提交单击、双击和长按，避免 WAN 延迟改变手势语义。
- 在提交时触发语义化震动；系统“减弱动态效果”只影响视觉动效。
- 前台按键可使用独立配对的 LAN 直连，也可通过 WatchConnectivity 使用配对 iPhone；语音仍由 iPhone 中转。

### iPhone

- 保存和编辑 Watch/iPhone 共用的动作配置，并提供手机 12 键遥控板。
- 每份配置完整包含 12 个按键以及每键的三种触发方式。
- 发现 Bonjour 服务、管理 LAN/Tailscale 直连候选、完成配对，并把 Watch 操作与 Codex 会话请求转发给 Mac。

### Mac Bridge

- 把 `_wristremote._tcp` 的 `60927` 端口绑定到允许的非隧道本地接口上的一个具体 RFC1918 IPv4、IPv4 链路本地地址或 IPv6 ULA；没有安全地址就不启动 listener。
- 把 Watch HTTP 端点 `/v1/bridge` 的 `60929` 端口绑定到具体 LAN 地址；应用消息经过认证和加密，并非明文命令。
- 校验局域网来源、协议角色、能力和配置修订号。
- 通过 Accessibility 执行有限动作；不提供通用远程 shell。
- 只对普通前台听写使用系统 Speech Framework。
- 把 Codex PCM 写入 Bridge 自有的仅所有者可读写 WAV，使用已登录 Codex 账号进行第一方联网转写，再通过本机 app-server 把文字排入所选任务。
- 仅在 `127.0.0.1:60928` 提供经过认证的 Codex Hook。
- 仅私有网络构建中撤销历史 Relay provisioning，不发起公网 Relay 流量。

### 保留但未启用的 Relay 源码

- Relay 源码仍保留给需要单独安全评审的变体。
- 当前跟踪配置设置 `WRISTREMOTE_PRIVATE_ONLY = YES`；保留的 `.invalid` URL 是独立第二道门禁。
- 仅私有网络的 Apple App 和 Bridge 拒绝 Relay provisioning 和请求，即使 Keychain 里还存在旧凭据，也会发送撤销 tombstone。
- 公网 Relay 不是该构建的 LAN/Tailscale 运行时回退路径。

## 局域网安全会话

创建 listener 时，Mac 先把本地端点限制到允许的非隧道本地接口上一个具体、不可公网路由的地址。首次会话随后使用 Curve25519 密钥协商，P-256 安装身份对临时会话公钥签名，双方显示由会话密钥派生的六位确认码。用户批准后，消息使用 ChaChaPoly 认证加密。accept 后的独立来源门禁只接受回环、链路本地、私有 IPv4/IPv6 以及与物理接口同前缀的 IPv6 来源，不解析主机名来绕过来源检查。

## 排除公网 Relay

任何 Relay 路径运行前必须同时满足两个检查：`WRISTREMOTE_PRIVATE_ONLY` 必须为 `NO`，且 HTTPS endpoint 必须有效而不是 `.invalid`。当前跟踪值在两处都拒绝。因此单独评审的 Relay 构建需要明确的源码级构建决策和不同 endpoint，无法从运行中 App 开启。Funnel、端口转发和公网代理不是支持的替代方案。

## 路由选择

iPhone 路由中，局域网先获得 0.9 秒 head start。若仍未 ready，iPhone 可以竞速连接明确配置的 Tailscale IP，并采用首个 ready 的私有路径。一次手势或语音流在完成前固定使用同一路由。失败不会生成离线动作或音频队列；序列化或加密成功不等于执行或投递成功。

前台 Watch 按键也可使用 LAN HTTP `60929`，以独立 Watch 身份单独获得 Mac 批准。已认证的 iPhone 只向 Watch 同步公开端点和身份配置，绝不复制其私钥。这条路径要求完整配置修订获得确认，以请求 ID 匹配动作回执，拒绝过期或重复请求，并在退到后台时停止轮询；它不承载语音，也不提供 Watch Tailscale 路由。见[手机与手表连接](phone-watch-connection.md)。

## 配置一致性

动作配置使用修订号。Mac 只在完整验证并安装目标修订后执行动作；旧修订、缺失按键或不支持的动作会被拒绝。任务状态另有单调状态修订号和清除 tombstone，避免旧的完成摘要在重连后复活。

## 语音和任务回复

Watch 通过实时 iPhone 私有路径发送受限 PCM 分包。对普通前台听写，Mac Speech Framework 识别音频，`BridgeTextInjector` 随后把结果立即注入焦点输入框。对 Codex，Mac 把 16 kHz 单声道 PCM 写入 Bridge 自有临时 WAV（目录 `0700`、文件 `0600`）并计算摘要。`CodexNativeVoiceTranscriber` 使用 app-server 返回的已登录账号内存认证信息，把录音发送到固定的 Codex 第一方联网转写端点；禁止重定向与磁盘 HTTP 缓存。Bridge 再次校验目标后，通过 app-server stdin/stdout 把返回文字排入任务。这需要互联网；仅私网遥控不代表离线转写。Codex 语音不使用 macOS Speech 或剪贴板。音频、路径和转写不进入 Bridge 日志、账本或进程参数；本次处理结束后删除临时 WAV。部分或取消的录音立即删除；Bridge 启动时只清理自身超过 24 小时的 `watch-*.wav`。

Codex 录音必须绑定精确 existing 目标和 Mac 签发的短期租约。选择“新建任务”时，先执行不含 fork/parent 的独立 `thread/start`，把返回 thread 注册成 existing 目标，然后才允许录音。连续录音期间，每个 Watch 分包只有在 Mac 确认该精确序号后才向前推进。断线、超时或缺少回执时 fail closed，丢弃部分录音，重连后不自动补发。

`BridgeTextInjector` 会把识别文本短暂写入系统通用剪贴板并模拟 Command-V。约 450 ms 后，只有剪贴板仍是这段临时文本且期间未发生变更时才恢复原内容。其他同一用户进程可能在这段窗口内观察到文本；若其他进程改变了剪贴板，Bridge 会保留新内容而不覆盖它，但原剪贴板内容可能无法自动恢复。

## 交互与取消的归属

手表首页负责选择发送目标和原始录音，遥控器是独立的导航页面；会话目录不创建文本输入框。iPhone 把日常重连与需要明确确认的删除配对分开。

```text
空闲 → 按住阈值 → 准备 → 录音 → 收尾 → 等待回执
         ↓          ↓      ↓      ↓
       提前松开     取消   取消   取消
         ↓          └──────┴──────┘
        空闲             丢弃 → 空闲
```

开始录音后松开发送一次；移开、离开页面、系统中断或超过时长上限，均丢弃尚未提交的录音。停止/提交请求离开手表后，取消不能承诺撤回：界面继续等待回执，结果不明确时不自动重发。

Mac 在异步校验目标前预留带随机标识的启动票据。即使麦克风或 WAV 尚未建立，取消和停止也会使票据失效。启动回调、音频、停止和取消都绑定原始流；旧回调不能占用新流。目录能力续期等待录音与回执结束，仅续期同一线程、工作区与 Mac epoch，不覆盖发送结果，也不在后台发起重新选择。公网 Relay 撤销不能清空私有路径的回执状态。

展示层拆为首页、目录、语音控件、草稿和任务详情。纯状态机管理手指接触及延迟长按识别；单独的目录维护状态覆盖尚无回执时的取消。“减弱动态效果”关闭按压缩放，语义震动可独立设置。

工作区身份登记上限为 128 个别名。容量耗尽时拒绝新增身份，但不丢弃已有身份或删除工作树；它与数据损坏不同。扩大或回收容量前，必须设计保留规范身份的迁移策略。

## 持久化

| 数据 | 位置 |
|---|---|
| 动作映射、收藏和布局 | Apple App 自有容器 |
| 配对身份、固定信任、私有 endpoint、Hook token | Apple Keychain |
| 自定义 App 选择、带 Keychain 随机密钥 HMAC 的 Codex 幂等提交台账 | Mac Bridge 自有偏好、Keychain 或 Application Support |
| 活跃的 Codex 原始语音 WAV | Bridge 自有 Application Support 目录；`0600`，使用/取消后删除 |

Tailscale 仍是独立服务，可以观察自身账号、控制平面和传输元数据。详细边界见仓库根目录的英文版 `THREAT_MODEL.md`。
