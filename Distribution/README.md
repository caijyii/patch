# 构建与签名边界

`Patch.entitlements` 提取自已经测试的沙盒权限集合，保留屏幕采集所需的运行时授权流程、录音权限及用户选择文件读写；未添加网络、自动化或临时沙盒例外。

`bash scripts/build-sandbox-app.sh` 构建 `.build/distribution-check/Patch.app`，显示名为 **Patch Development**，标识为 `dev.screenleaf.development`。它只用于本地验证，临时签名且不会自动启动或注册到系统。重新构建临时签名应用可能需要重新授权；不要同时运行它和日常试用包，以免全局快捷键相互占用。

`bash scripts/build-app.sh` 保留原本的非沙盒本地诊断构建，输出 `dist/Patch.app`。可以用 `SCREENLEAF_OUTPUT_DIR` 指定其他输出目录；不要把它当成商店包。`package-app.sh` 也只是本地 ZIP 打包。

正式商店 target 尚待完整 Xcode 和开发者账号：需使用已确认的产品标识、版本、签名团队和商店分发配置；纳入 `Resources/Info.plist`、`Resources/PrivacyInfo.xcprivacy`、`PatchStickers`、应用图标和沙盒权限文件，并重新做 Archive 验证和实际功能验收。不能仅给当前临时包换个文件名就提交。

不要提交证书私钥、开发者 API 密钥、描述文件或包含个人信息的 Xcode 用户设置。

## GitHub 安装包

首次打包先运行 `bash scripts/setup-dmg-tools.sh`，在项目 `.build/dmg-tools` 内安装固定版本的构建依赖（dmgbuild、ds-store、mac-alias）；这些依赖不会进入应用包或全局 Python。

运行 `bash scripts/package-release.sh v0.1.3`，从干净 Git 工作区构建 Apple Silicon 沙盒安装包，输出至 `dist/v0.1.3/`。已有输出目录时拒绝覆盖。

发布附件包括 `Patch-…-macOS-arm64.dmg`、`Patch-…-macOS-arm64.zip`、`INSTALL.md`、`INSTALL.en.md`、`release-manifest.json` 和 `SHA256SUMS.txt`。清单记录源码提交、架构、版本和签名状态；不包含本地日志或验收素材。应用使用源码既有标识 `dev.screenleaf.app`，与本机 Sandbox / Development 包分开，但不应同时运行。

当前安装包采用 ad-hoc 签名，启用 `Patch.entitlements` 沙盒权限，尚无 Developer ID 签名和 Apple 公证。维护者已确认 `v0.1.0` 作为首个正式版本发布，GitHub `prerelease=false`；版本发布状态与签名、公证状态分别记录，安装说明须明确首次启动的系统确认与权限限制。不能把本机运行成功视为干净系统安装验收。

`package-release.sh` 同时支持正式标签和 `-preview.N` 标签，清单中的 `channel` 分别为 `stable` 和 `preview`。历史预览版入口 `package-preview.sh` 保留，预览标签仍应标记 GitHub prerelease。

`package-dmg.sh` 也可将已有的 `Patch.app` 封装成 DMG，不重新编译或签名。磁盘映像使用暖白与浅绿拱形背景，固定图标位置与窗口尺寸，只显示应用、指向 `/Applications` 的快捷入口和方向箭头。完整安装说明仍随发行版以 `INSTALL.md` 单独提供。背景由 `scripts/generate-dmg-artwork.swift` 以 2× 分辨率生成；布局配置位于 `Distribution/DMG/settings.py`。打包不依赖 Finder 自动化，也不修改用户的 Finder 全局设置。对 `v0.1.0-preview.1`，后补 DMG 使用独立的 `dmg-manifest.json` 和 `SHA256SUMS-DMG.txt`，保留原 ZIP 与原校验附件不变；它们封装的是相同应用。

## 后续 Developer ID 签名与公证

1. 维护者开通 Apple Developer Program，创建 Developer ID Application 证书并安装到本机钥匙串；私钥和公证凭据不入仓库。
2. 确认正式版本号、构建号和产品标识。以 Hardened Runtime 构建／签名，沿用经验证的沙盒权限；签名后不再修改包内文件。
3. 使用 `notarytool` 将正式签名的应用归档提交给 Apple，检查返回结果；通过后将公证票据附加到应用，再生成 ZIP 与 DMG。DMG 也按 Apple 流程签名、公证并附加票据。
4. 校验签名、Gatekeeper 评估、公证票据、架构、SHA-256 和源码提交。当前 ad-hoc 打包脚本不完成上述正式签名步骤。
5. 在未安装过 Patch 的独立 Mac 或干净虚拟机中，从公开下载地址安装，验证首次启动、屏幕／录音／控制权限、核心功能与退出；再验证旧版到新版替换。确认后发布签名、公证的新安装包。

GitHub 版可后续接入 Sparkle；接入前仍是手动更新。沙盒、签名、公证、更新机制是独立设置，正式版无需为了改变发布状态而关闭沙盒。
