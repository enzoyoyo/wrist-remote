# 安全策略

[English](SECURITY.md)

## 支持范围

安全修复覆盖最新标签版本和当前 `main` 分支。较旧版本通常需要先升级。

## 报告漏洞

请使用本仓库的 GitHub 私密漏洞报告或 Security Advisory。不要在 Issue 中提交密钥、Token、房间标识、设备标识、个人信息、本机路径、私密转写或描述文件。

若暂时无法私密报告，请只创建一个请求建立私密沟通渠道的公开 Issue，不要公开漏洞细节。

有帮助且可公开的脱敏信息包括：

- 受影响的提交或版本；
- Watch、iPhone、Mac Bridge、Relay 或工具链中的受影响组件；
- 完全使用合成数据的最小复现；
- 预期安全边界和实际行为；
- 影响，以及攻击是否需要本机、局域网或互联网访问。

维护者应在收到完整报告后七天内确认。修复时间取决于影响和可复现性，请在公开披露前预留协调修复时间。

## 安全边界

- Mac Bridge 在接受 TCP 连接前，只把局域网传输绑定到允许的非隧道本地接口上的一个具体、不可公网路由地址（RFC1918 IPv4、IPv4 链路本地地址或 IPv6 ULA）；找不到安全地址时拒绝启动。accept 后还会独立校验局域网来源，再进入显式配对。
- Tailscale 使用独立、默认关闭的 listener。启用后只在 Tailscale 官方 IPv4/IPv6 范围内的一个具体 `utun` 地址上监听 TCP `60927`，只接受 Tailscale 范围内的来源，并继续要求 Wrist Remote 双向身份校验、首次双端明确配对和加密会话。
- 仅私有网络构建中，iPhone 私有网络设置只接受官方 Tailscale 专用 IP，保存在 App 独立 Keychain service 中，并在使用前重新校验；DNS 名称、公网 URL、嵌入式凭据、任意端口、公网 IP 和无关私网 IP 都会被拒绝。
- 不得为 Wrist Remote 启用 Tailscale Funnel、路由器端口转发、公网反向代理或公网通配监听；tailnet Grant 应只允许指定来源访问指定 Mac 的 `tcp:60927`。
- Mac 与 iPhone 使用专用 Keychain 条目中的长期 P-256 身份签署直连握手证明，并且只在对应条目不存在时创建身份；iPhone 只有在本机批准且 Mac 也批准同一个六位码会话后才固定 Mac 指纹，Mac 另行保存获批的 iPhone 指纹。
- Mac 身份改变、身份或信任存储不可读/损坏、签名无效、transcript 不完整、未签名旧客户端、任一长期身份不可用，或 Mac 无法持久保存获批的 iPhone 指纹时，都在 ready 前 fail closed。实现不会静默换掉已保存身份，也不会仅因网络 endpoint 看似未变就信任替代身份。
- 仓库当前的个人构建设置 `WRISTREMOTE_PRIVATE_ONLY = YES`，并保留 `.invalid` Relay URL。构建标志与 endpoint 校验是两道独立门禁，任何一道都不能单独启用公网路径。历史 Relay 凭据会被撤销，普通重启或保留 Keychain 的重装不会恢复它。
- Relay 源码只保留给需要单独评审的构建变体。Tailscale Funnel、路由器端口转发、公网反向代理和公网通配监听不是替代方案，不在支持范围内。
- Codex Hook 只绑定 `127.0.0.1`，需要每次安装随机生成的 Bearer Token，并限制请求大小和处理时间。
- Codex 会话授权短期且绑定目标。“新建任务”先在本机执行不含 fork/parent 的 `thread/start`，再把结果转换为 existing 目标；目标 ready 前不能开始录音。
- Watch 到 Mac 的 Codex 语音通过 iPhone 使用实时私有链路。Mac 写入仅所有者可读写的 WAV，再使用 app-server 返回的已登录账号内存认证信息，把录音发送到 Codex 固定的第一方联网转写服务。再次校验目标后，经本机 app-server stdin/stdout 排入返回文字。这需要互联网；仅私网遥控不代表离线转写。禁止重定向和磁盘 HTTP 缓存。Codex 语音不使用 macOS Speech 或剪贴板；音频、路径、认证信息和转写不进入 Bridge 日志或账本。临时录音在处理结束或取消后删除。
- 连续连接中的每个音频分包只有在 Mac 确认接收后才允许 Watch 向前推进。断线或缺少回执时 fail closed，删除部分录音，不会在重连后自动补发。
- 签名凭据、描述文件、本地配置、生成工程、日志和构建产物均不得进入源码仓库。
- Mac 受控升级要求绝对、非符号链接目标，Bundle ID 与构建产物一致，且没有任何运行中的 `WristRemoteBridge` 进程。安装器 fail closed 且不会自动结束已有 Bridge，以降低覆盖错误 App 或第二个 listener 争抢 TCP `60927` 的风险。
- Wrist Remote 使用独立标识和存储，不得读取、改写或拦截其他遥控器及输入设备的配置。

Tailscale 路径仍依赖配对 iPhone；Watch 本身不加入 tailnet，仅私有网络构建中明确不支持独立蜂窝 Watch 控制。从尚未固定 Mac 身份的旧版本升级后需完成一次双端明确配对。若经核实的重装确实更换了 Mac 身份，可在 iPhone 使用 **忘记已信任的 Mac** 后重新配对。若通过 **重置此 iPhone 的配对身份** 有意更换 iPhone 身份，Mac 必须把它作为新 iPhone 再次批准；不得用任一重置操作绕过原因不明的身份不匹配。启用私有网络前请阅读 [docs/zh-CN/tailscale-private-network.md](docs/zh-CN/tailscale-private-network.md)。

完整信任模型和残余风险见英文版 [THREAT_MODEL.md](THREAT_MODEL.md)。

## 发布门槛

发布前必须通过测试、无签名构建、仓库隐私扫描、敏感信息扫描、依赖审计及 Git 精确文件树人工复核。涉及直连链路的变更还必须真机验证局域网 head start 与首个 ready route 采用、私网连接、VPN 唤醒、首次双端配对、固定身份重连、身份不匹配拒绝、两项显式身份恢复操作、持久化失败拒绝、来源拒绝和断线不补执行。Codex 变更还必须真机验证独立任务创建、联网转写前后的精确目标绑定、文字排队投递、逐包 Mac 回执、中断清理、不自动补发和前台听写隔离。源码发布不得包含已签名 App、归档、描述文件、证书、日志、扫描产物、真实指纹、Tailscale IP、账号 selector、tailnet 策略导出或录制音频。
