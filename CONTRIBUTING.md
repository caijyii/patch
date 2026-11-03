# 参与开发

项目仓库：[caijyii/patch](https://github.com/caijyii/patch)。问题反馈与功能建议请使用仓库 Issues；改进可通过 Pull Request 提交。

- 使用 macOS 15 或更新版本和支持 Swift 6 的 Apple 工具链。
- `bash scripts/build-sandbox-app.sh` 构建隔离的本地开发包，不会自动启动或替换试用包。
- `bash scripts/test.sh` 检查坐标、拼接、录屏文件保存和权限流程模型。
- `bash scripts/verify-preferences.sh --model-only` 检查内存存储和虚拟热键后端；不注册真实系统快捷键。
- 原生交互回归见 `scripts/verify-reopen.sh`、`verify-selection-ui.sh`、`verify-pin-ui.sh` 等，需要可用桌面。不要在锁屏或远程会话里把未完成的检查算作通过。

请保持改动聚焦，并说明测试范围。提交问题时只提供可公开的复现资料；不要附带真实用户截图、录音、录屏、凭据或完整系统日志。测试素材优先使用合成内容。安全问题请按 [SECURITY.md](SECURITY.md) 私下报告。

仓库代码使用 MIT 许可证。外部贡献需有权按项目许可证提供；不要提交第三方来源不明的代码、图片或字体。保留第三方许可声明。

开发包使用独立标识 `dev.screenleaf.development`，自己的分支也应更换标识，避免与官方安装包争用系统授权及快捷键。`dist/`、`.build/`、证书、私钥和本机设置不应提交。
