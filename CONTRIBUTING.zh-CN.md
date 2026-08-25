# 贡献指南

[English](CONTRIBUTING.md)

感谢改进 Wrist Remote。所有贡献都必须保留明确配对、端点隔离、无离线指令和仓库不含 secret 的安全边界。

## 提交 Issue 前

- 搜索已有 Issue 和文档。
- 开发环境允许时运行 `make doctor`、`make test` 和 `make build`。
- 使用合成数据把问题缩小到最小可复现用例。
- 移除姓名、邮箱、域名、IP、设备标识、Team ID、Bundle 前缀、路径、token、转写、截图、日志和描述文件。
- 漏洞使用 GitHub 私有漏洞报告，不要公开提交利用细节。

## 开发环境

```bash
make setup
make doctor
make test
make build
make security
```

使用自己的 Apple Team 和 Cloudflare 账号。不得要求维护者接收描述文件、证书、Keychain 导出、账号凭据或生产 secret。

## Pull Request

一个 PR 应当：

- 解决一个边界明确的问题，并解释用户可观察行为；
- 提供修改前失败、修改后通过的测试；
- 面向开发者的行为变化同时更新 `docs/en` 和 `docs/zh-CN`；
- 保持协议兼容，或明确升级正确的协议版本；
- 不提交生成工程、构建产物、依赖目录和本地配置；
- 通过 `make test`、`make build` 和 `make security`；
- 列出已经完成和仍未完成的真机检查。

提交和 PR 不得包含私有开发笔记、对话、研究记录、完整日志或真实用户内容。

## 安全相关修改

修改配对、密码学、token、Keychain、辅助功能、语音、Codex 提交、Relay 路由、TTL 或重放逻辑时，必须增加针对性的反向测试并更新威胁模型。

不接受以下改动：

- 任意远程 shell 执行；
- Mac 公网入站监听；
- 把凭据写入 URL、源码、示例、日志或 Git 跟踪配置；
- 持久化或延迟执行离线按键；
- 静默绕过权限或回退到无关应用；
- 默认启用遥测或维护者托管服务。

## 代码与协议规则

- 从 `project.yml` 生成 Xcode 工程，不提交生成工程。
- Relay 依赖使用 `npm ci`，修改依赖时同步锁文件。
- profile revision 和 task state revision 保持单调。
- 执行动作前完整校验 message shape。
- Relay 保持一部署一 room 的协调单元。
- Durable Object 持久化范围限于 token 哈希、Relay device UUID、初始化时间和 replay/rate 状态；不得在其中保存 ciphertext、plaintext payload、bearer 明文或 E2E key。
- Watch 本地确定手势，网络延迟不能改变单击/双击/长按含义。

## 双语文档

中英文文档必须包含相同的命令、版本、限制和安全披露。翻译可以改善表达，但不能弱化警告或删除已知风险。

## 许可证

Wrist Remote 使用 GPL-3.0-only。提交贡献表示你确认自己创作了内容，或有权按 GPL-3.0-only 提供它。PR 中应说明第三方来源和许可证；适用时更新 `THIRD_PARTY_NOTICES.md`。

不得提交来源或授权不明确的代码和资产。

## 行为规范

参与项目需遵守 [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)。
