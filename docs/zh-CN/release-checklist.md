# 发布检查表

[English](../en/release-checklist.md)

初始仓库保持 private。只有下面所有门禁通过并由仓库所有者明确批准后，才能考虑公开。private 仓库也不能存放 secret 或个人资料。

## 1. 内容范围

- [ ] 仓库只包含 Wrist Remote 客户端、Bridge、Relay、通用脚本、示例和公开开发文档。
- [ ] 没有迁入原始工作仓库的 `.git` 历史、Bug 记录、研究/计划、内部讨论、对话、过程日志或测试证据。
- [ ] 没有 DerivedData、`.build`、`build`、Generated、Xcode user data、`node_modules`、`.wrangler`、缓存或临时文件。
- [ ] 没有用户照片、真机截图、录音、私有任务或本机诊断包。
- [ ] 生成文件可由 `make setup` / `make build` 重建。

## 2. 脱敏与 secret

- [ ] `make security` 成功。
- [ ] gitleaks 已扫描工作树和全部 Git 历史，结果为零。
- [ ] `git ls-files` 已人工逐项审查。
- [ ] 没有姓名、邮箱、真实域名、IP、账号、设备名、设备 ID、UDID、Team ID 或本机绝对路径。
- [ ] 没有 token、Cookie、API Key、证书、私钥、描述文件、Keychain 导出、`.env`、`.dev.vars` 或生产 xcconfig。
- [ ] 图片和二进制已检查元数据与 strings；不存在 EXIF、路径或签名身份。
- [ ] 示例仅使用明确占位符或 TEST_ONLY 数据，不使用真实格式秘密伪装成示例。
- [ ] Git commit 作者使用批准的组织身份或 noreply 地址。

扫描报告不得复制命中的 secret 内容；只记录相对文件、类别和通过/失败。

## 3. 许可证与来源

- [ ] `LICENSE` 明确为 GPL-3.0-only。
- [ ] 贡献者对全部代码和资产拥有 GPL-3.0-only 授权权利。
- [ ] 没有从来源不明、许可证不兼容或禁止再分发的项目复制内容。
- [ ] `THIRD_PARTY_NOTICES.md` 与锁文件中的直接依赖一致。
- [ ] App Icon 和其他资产的授权记录完整；没有第三方商标素材。
- [ ] 新依赖已完成许可证兼容性和供应链审查。

许可证或 provenance 不明确即停止发布，不能因为仓库暂时 private 而跳过。

## 4. 文档

- [ ] README、SECURITY、PRIVACY、贡献指南及 `docs/zh-CN` / `docs/en` 信息一致。
- [ ] 两种语言文件集、协议版本、命令、限制和风险披露一致。
- [ ] 所有内部链接有效。
- [ ] 安装文档明确 Apple 登录、设备信任、Developer Mode 和权限必须人工确认。
- [ ] Relay 文档明确每位开发者自托管、Mac 仅出站、Cloudflare 可见元数据。
- [ ] 文档没有真实配置、路径、截图或历史验收陈述。

## 5. 自动化验证

```bash
make doctor
make verify
git status --short
```

`make verify` 包含 Relay 依赖高风险审计以及 iOS/watchOS Simulator 测试；缺少兼容 runtime 时必须失败，不能跳过。

- [ ] Shared Swift tests 通过。
- [ ] Bridge XCTest 通过。
- [ ] Relay typegen、typecheck、Vitest 和高风险 npm audit 通过。
- [ ] iOS/watchOS Simulator 与 macOS 无签名构建通过。
- [ ] CI 从不接收 Apple、Cloudflare、Relay 或 Keychain production secrets。
- [ ] GitHub Actions 使用最小权限，第三方 Action 固定到完整 commit SHA。
- [ ] 工作树只包含预期变更；ignored 文件未被强制加入。

## 6. 真机与运行时验收

- [ ] 新安装可以使用开发者自己的 Team 完成签名、安装和启动。
- [ ] 首次六位码配对和拒绝流程均正确。
- [ ] 12 键的单击、双击和长按逐项验证。
- [ ] 收藏、自定义快捷键和自定义 App profile 同步正确。
- [ ] 震动开关、按下/取消手势与 Reduce Motion 行为正确。
- [ ] 中文普通前台语音完成录音、最终识别，并立即注入当前焦点输入框。
- [ ] 普通语音注入后原剪贴板会在约 450 ms 后恢复；期间若剪贴板被改变，Bridge 保留新内容且不会误覆盖。
- [ ] Codex 完成任务、摘要、语音确认、提交和回执完整；任务变化会拒绝旧回复。
- [ ] LAN 优先，外网切换、Mac 离线、断网恢复和 LAN 恢复行为符合文档。
- [ ] 断网期间的按键不会在恢复后补执行。
- [ ] App 与 Mac 重启后的重连行为已验证。
- [ ] 未读取、覆盖或拦截其他应用和输入设备配置。

自动化、构建、健康检查和代理操作不能代替这些真机结果。未执行的项目必须标记未验收。

## 7. GitHub private 暂存阶段

- [ ] 仓库 visibility 为 private。
- [ ] 默认分支为 `main`；当前候选 commit 已在 private CI 中通过 `Privacy, secrets, and history`、`Relay checks` 和 `Apple builds and tests`。
- [ ] Actions 默认 `contents: read`，不向 pull request 注入 production secrets。
- [ ] 初始发布只含源码，不含签名 App、IPA、描述文件、证书或私有 Release 资产。
- [ ] 未配置 GitHub Pages、公开 Wiki 或自动 public visibility。
- [ ] 从 private 远端 fresh clone 后，仓库安全门禁、本机可执行的测试和无签名构建全部通过。

仓库处于 private 时，如果账号没有对应的 GitHub Code Security 权益，CodeQL job 会按设计跳过。此时不得声称 CodeQL 已覆盖，也不得把 CodeQL 设为 required check；本地与 CI gitleaks 门禁必须继续保留。

## 8. 公开切换与公开后安全设置

- [ ] 从干净 clone 重新执行 setup、test、build 和 security。
- [ ] 扫描远端完整历史，而不只扫描本地最新工作树。
- [ ] 重新下载任何候选源码归档并扫描、解包、逐文件核对。
- [ ] 仓库所有者已查看最终文件树、文档、许可证、威胁模型和未解决问题。
- [ ] 仓库所有者在当前发布时点明确批准改为 public。
- [ ] 由仓库所有者单独把 visibility 改为 public，并验证未登录访问与 `main` 默认分支。
- [ ] 对公开 commit 手动触发 CodeQL，要求 `JavaScript and TypeScript` 与 `Swift` 两项均成功。
- [ ] 启用公开仓库可用的 secret scanning、push protection、Dependabot security updates 和私有漏洞报告。
- [ ] 只有成功的 CI 与 CodeQL check run 已真实存在后，才按其实际名称设置 `main` branch protection，并从 GitHub 回读配置。
- [ ] 确认没有发布 Release、deployment、Pages 站点、签名二进制、描述文件、证书或私有验收资料。

可见性切换必须是仓库所有者的独立操作；构建、测试和发布脚本不得自动把 private 仓库改为 public。branch protection 不得要求一个从未在公开 commit 上成功完成的检查。
