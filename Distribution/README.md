# 构建与签名边界

`Patch.entitlements` 提取自已经测试的沙盒权限集合，保留屏幕采集所需的运行时授权流程、录音权限及用户选择文件读写；未添加网络、自动化或临时沙盒例外。

`bash scripts/build-sandbox-app.sh` 构建 `.build/distribution-check/Patch.app`，显示名为 **Patch Development**，标识为 `dev.screenleaf.development`。它只用于本地验证，临时签名且不会自动启动或注册到系统。重新构建临时签名应用可能需要重新授权；不要同时运行它和日常试用包，以免全局快捷键相互占用。

`bash scripts/build-app.sh` 保留原本的非沙盒本地诊断构建，输出 `dist/Patch.app`。可以用 `SCREENLEAF_OUTPUT_DIR` 指定其他输出目录；不要把它当成商店包。`package-app.sh` 也只是本地 ZIP 打包。

正式商店 target 尚待完整 Xcode 和开发者账号：需使用已确认的产品标识、版本、签名团队和商店分发配置；纳入 `Resources/Info.plist`、`Resources/PrivacyInfo.xcprivacy`、`PatchStickers`、应用图标和沙盒权限文件，并重新做 Archive 验证和实际功能验收。不能仅给当前临时包换个文件名就提交。

不要提交证书私钥、开发者 API 密钥、描述文件或包含个人信息的 Xcode 用户设置。
