# 参与开发

项目仓库：[caijyii/patch](https://github.com/caijyii/patch)。问题反馈与功能建议请使用仓库 Issues；改进可通过 Pull Request 提交。

- 使用 macOS 15 或更新版本和支持 Swift 6 的 Apple 工具链。
- `bash scripts/build-sandbox-app.sh` 构建隔离的本地开发包，不会自动启动或替换试用包。
- `bash scripts/test.sh` 检查坐标、拼接、录屏文件保存和权限流程模型。
- `bash scripts/verify-preferences.sh --model-only` 检查内存存储和虚拟热键后端；不注册真实系统快捷键。
- `bash scripts/verify-recent-content.sh` 用独立命名剪贴板、合成图片和内存偏好检查历史、自动收录、外观与界面；不读取或修改系统通用剪贴板。
- `bash scripts/verify-permissions.sh` 检查只读权限状态和授权提示顺序；`bash scripts/verify-workflow.sh` 检查中英菜单、按钮/快捷键授权入口与混合批量贴图。均不请求真实权限或读取通用剪贴板。
- `bash scripts/verify-home-options.sh` 检查同窗口设置、授权按钮、中英布局以及透明度与深浅色对照。
- `bash scripts/verify-stickers.sh` 检查图案顺序、拖排、持久化与工具栏同步；`bash scripts/verify-stickers-drag.sh` 在合成截图选区的真实贴纸弹窗中验证应用内按下、拖动、释放及取消事件链，不注入系统鼠标事件。`bash scripts/verify-recording-segments.sh` 使用合成音视频检查暂停后的片段衔接，`bash scripts/verify-recording-lifecycle.sh` 检查倒计时取消、暂停和控制窗状态，不采集桌面。
- `bash scripts/verify-status-recording.sh` 检查真实录制前后 Patch 只保留主菜单图标，不重复显示系统停止控件，只采集自建纯色测试窗口并丢弃帧，不录音或保存视频。需要已有截屏授权；未授权时明确显示 `SKIP`，不会申请权限。
- `bash scripts/verify-menu-activation.sh` 检查功能窗口的 Dock 生命周期，包括多窗口、关闭重开、隐藏、最小化和窗口交接。`bash scripts/verify-status-window-order.sh` 用两个测试进程连续检查菜单打开期间的窗口顺序及切换到其他应用的行为。后者使用程序触发菜单，还需用真实菜单栏点击验证。锁屏时以 `SKIP` 和退出码 77 结束，不能视为通过。
- 原生交互回归见 `scripts/verify-reopen.sh`、`verify-selection-ui.sh`、`verify-pin-ui.sh` 等，需要可用桌面。不要在锁屏或远程会话里把未完成的检查算作通过。

请保持改动聚焦，并说明测试范围。提交问题时只提供可公开的复现资料；不要附带真实用户截图、录音、录屏、凭据或完整系统日志。测试素材优先使用合成内容。安全问题请按 [SECURITY.md](SECURITY.md) 私下报告。

仓库代码使用 MIT 许可证。外部贡献需有权按项目许可证提供；不要提交第三方来源不明的代码、图片或字体。保留第三方许可声明。

开发包使用独立标识 `dev.screenleaf.development`，自己的分支也应更换标识，避免与官方安装包争用系统授权及快捷键。`dist/`、`.build/`、证书、私钥和本机设置不应提交。

- `bash scripts/verify-capture-windows.sh` 检查普通 Patch 窗口可被截图、操作浮层仍被排除；已有授权时只截取自建纯色窗口区域并丢弃像素，未授权则明确跳过像素检查。

本地诊断构建可在签名前将 `Info.plist` 的布尔值 `PatchWindowDiagnosticsEnabled` 设为 `true`。重启后，日志写入应用容器的 `Library/Application Support/Patch/Diagnostics/window-activation.log`，最多保留 200 条菜单、焦点、窗口编号及系统菜单栏状态，不记录窗口文本或剪贴内容。普通构建不设置此键。诊断结束后重新构建普通包即可停用。
