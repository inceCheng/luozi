# 落字的公开发布路线

## GitHub 开源

落字的[源码仓库](https://github.com/inceCheng/luozi)采用 [MIT 许可证](LICENSE)。构建和验收方法见 [README](README.md)。阿里云密钥由用户自行提供并保存在本机钥匙串。

当前验证平台为 macOS 26+、Apple Silicon。准备分发安装包时，从干净目录构建并完成下列签名和公证步骤，再将安装包作为对应版本的 GitHub Release 附件提供。

## 让用户从 GitHub 下载 Mac 版

1. 加入 Apple Developer Program。个人也可申请，标准费用为每年 99 美元或当地等值金额。在开发者账户中创建 **Developer ID Application** 证书，并把证书及对应私钥安装在签名机上。[加入开发者计划](https://developer.apple.com/help/account/membership/program-enrollment/) · [Developer ID](https://developer.apple.com/developer-id/)
2. 制作单独的发布构建，启用 Hardened Runtime，保留麦克风用途说明，添加 Audio Input entitlement。使用 Developer ID Application、`--options runtime` 和安全时间戳签名，执行严格签名验证。当前 `./build.sh` 用于本地开发，仅指定 `CODESIGN_IDENTITY` 仍不足以走完发布流程。[公证要求](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) · [音频输入授权](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.audio-input)
3. 把签好的应用打成 DMG，签署 DMG，使用本机钥匙串凭据通过 `xcrun notarytool submit 落字.dmg --keychain-profile <配置名> --wait` 提交。状态为 `Accepted` 后执行 `xcrun stapler staple 落字.dmg` 和 `xcrun stapler validate 落字.dmg`，再上传这份最终文件。[Apple 公证与装订流程](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
4. 用另一台受支持的 Mac 或干净系统，从浏览器下载最终的 DMG，拖进「应用程序」，从 Finder 首次打开。验收 Gatekeeper、麦克风和跨应用回填，并分别跑通一次本机和云端听写。正常的首次下载确认及隐私授权可以出现。

## Mac App Store

Mac App Store 要求应用使用 App Sandbox。落字直接回填依赖跨应用 Accessibility，右 Ctrl 和任意键提交也依赖全局键盘事件。先制作一个开启沙盒的测试版本，在备忘录与浏览器编辑器里逐项验证录音、两种快捷键、结束键拦截和回填。如果关键操作受限，可以保留完整功能的 Developer ID 直装版，另行评估以「复制终稿、手动粘贴」为主的商店版。[App Review Guidelines，第 2.4.5 条](https://developer.apple.com/app-store/review/guidelines/#hardware-compatibility)

通过可行性验证后，在 App Store Connect 创建应用，准备签名、截图、隐私政策、数据处理说明和审核演示步骤。默认 Apple 本机模式在设备上处理音频。用户启用阿里云前，应清楚看到音频将发送给阿里云百炼，并明确同意。隐私申报还需与上线版本以及服务提供方的实际数据处理方式一致。[Apple 用户数据与隐私要求](https://developer.apple.com/app-store/review/guidelines/#privacy)

## Windows 首版

建议采用 C#/.NET + WPF 做托盘与无焦点悬浮窗，WASAPI 按需录音。首版接入现有阿里云识别，复用音频规格、WebSocket 消息格式以及分段和修订测试用例。Key 保存到 Windows 凭据管理器。Apple 本机识别依赖 macOS Speech 框架，Windows 离线引擎单独选型并按需加载。

快捷键要能区分按下、释放和右 Ctrl。用 UI Automation 定位编辑器，验证焦点后再插入文本，失败时保留在剪贴板；验收记事本、浏览器富文本、中文输入法和高权限窗口。Windows 会限制低权限进程向高权限窗口注入输入。[Windows SendInput 文档](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput)

首发可以选择 MSIX 提交 Microsoft Store，由商店处理分发签名。若也提供站外安装包，需另行处理代码签名，并在干净系统验证 SmartScreen 的实际提示。[Microsoft 分发路径](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/choose-distribution-path)
