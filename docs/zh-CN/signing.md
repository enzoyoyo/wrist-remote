# 私有安装与签名

Wrist Remote 使用原生 iPhone + watchOS 伴侣 App，以及独立的 Mac Bridge。源码构建、自动化测试、签名和真机验收是四个不同阶段。

## 设备未连接时

在配置好完整 Xcode、模拟器运行时和项目依赖后运行：

```sh
make verify
```

这会检查敏感信息、测试、依赖漏洞、模拟器交互并构建未签名产物；不会安装到真机。构建成功不等于真机麦克风、触觉或跨网络通信已验收。

## 设备连接后

1. iPhone 和 Apple Watch 解锁，允许开发者模式及系统配对。
2. 在 Xcode 登录自己的 Apple 账号；证书留在本机钥匙串。
3. 运行 `scripts/install-devices.command --dry-run` 做只读检查。
4. 确认目标设备后运行 `make install-devices`。脚本核对 bundle ID、Team 与现有安装身份，原位升级；不会按显示名称删除 App。
5. 用同一句中文测试录音、取消、选择会话和新建独立会话，再验收断连重连与 Tailscale 路径。

免费 Personal Team 的描述文件自签发起 7 天过期，需要重新构建安装；不能承诺永久有效。付费开发者方案仍受证书与描述文件有效期约束。详见 [Apple 开发者账号说明](https://developer.apple.com/help/account/basics/about-your-developer-account)。

受控升级时，如果安装了 `ideviceinstaller`，脚本会只读校验 iPhone 现装 App 的精确签名 Bundle 与 Team，不依赖可能被清理的历史描述文件缓存；身份不匹配仍停止。如果当前 Watch 确认没有旧 App，可显式使用 `scripts/install-devices.command --allow-watch-first-install`，仅允许手表端首次安装，iPhone 原位升级约束和新包设备/签名检查不变。不要为绕过失败而修改 Team 或取消升级约束。

## LiveContainer 评估

不将 LiveContainer 作为此项目的安装方案。它是在宿主中运行 iOS guest App，并非本项目原生 watchOS 伴侣安装链的替代品。[官方 FAQ](https://livecontainer.github.io/docs/faq) 说明 guest 通常不能使用需要额外 App ID 的扩展；[官方仓库](https://github.com/LiveContainer/LiveContainer) 也提示第三方构建可访问容器内敏感数据。

Apple 的 [WatchConnectivity 示例](https://developer.apple.com/documentation/watchconnectivity/transferring-data-with-watch-connectivity) 要求配置原生目标的签名及伴侣 bundle 标识。基于这些约束，本项目保留原生签名与应用隔离；这里是兼容性与风险评估，不是假称已做过 LiveContainer 真机兼容测试。

不关闭 Gatekeeper，不导出私钥，不上传 Apple 账号或描述文件，不把配对凭据导入第三方容器。
