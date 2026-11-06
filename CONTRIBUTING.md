# 参与开发

项目仓库：[caijyii/patch](https://github.com/caijyii/patch)。问题反馈与功能建议请使用仓库 Issues；改进可通过 Pull Request 提交。

新增功能时参照 [产品与交互基线](docs/product-baseline.md)；视觉与文案改动参照 [设计基线](docs/design-baseline.md)。按改动读取相关章节，已有约定与实现模式分开处理。

Swift 模块与源码目录统一为 `Patch`（`Sources/Patch`），测试模块为 `PatchTests`（`Tests/PatchTests`）。现有 `dev.screenleaf.*` 运行标识、剪贴板类型和 `SCREENLEAF_*` 脚本环境变量保留兼容，不随源码改名进行全局替换。

- 使用 macOS 15 或更新版本和支持 Swift 6 的 Apple 工具链。
- `bash scripts/build-sandbox-app.sh` 构建隔离的本地开发包，不会自动启动或替换试用包。
- `bash scripts/test.sh` 检查坐标、拼接、录屏文件保存和权限流程模型。
- `bash scripts/verify-scroll-fixed.sh` 用合成图像检查完整选区的真实像素硬接缝、固定元素重复、双向回访和内存上限；`bash scripts/verify-scroll-ui.sh` 检查原选区框线稳定、匹配失败后继续采样、已有结果可完成或标注，以及重选取消的会话隔离。`bash scripts/verify-selection-ui.sh --scroll-only` 验证长截图默认窗口识别、直接拖动框选、普通截图转长截图及选择器取消回调。这些检查不截取用户桌面或发送滚轮事件；两个 UI 脚本均支持 `--build-only`。
- `bash scripts/verify-preferences.sh --model-only` 检查内存存储和虚拟热键后端；不注册真实系统快捷键。
- `bash scripts/verify-multi-shortcut-ui.sh` 检查双快捷键的单行布局、编辑操作和屏幕像素对齐，使用内存设置与虚拟热键；加 `--build-only` 可只编译。
- `bash scripts/verify-recent-content.sh` 用独立命名剪贴板、合成图片和内存偏好检查历史、自动收录、外观与界面；不读取或修改系统通用剪贴板。
- `bash scripts/verify-recent-quotas.sh` 验证文字、图片和视频的独立容量，以及合成视频的文件引用、缩略图、去重、清空竞态和失效处理。输出的合成视频可传给 `bash scripts/verify-history-video-ui.sh <合成视频路径>`，检查视频过滤、复制、播放器失败和原文件失效提示；使用独立命名剪贴板与注入的播放器，不启动真实播放器。
- `bash scripts/verify-permissions.sh` 检查只读权限状态和授权提示顺序；`bash scripts/verify-workflow.sh` 检查中英菜单、按钮/快捷键授权入口与混合批量贴图。均不请求真实权限或读取通用剪贴板。
- `bash scripts/verify-home-options.sh` 检查同窗口设置、授权按钮、中英布局以及透明度与深浅色对照。
- `bash scripts/verify-stickers.sh` 检查图案顺序、拖排、持久化与工具栏同步；`bash scripts/verify-stickers-drag.sh` 在合成截图选区的真实贴纸弹窗中验证应用内按下、拖动、释放及取消事件链，不注入系统鼠标事件。`bash scripts/verify-recording-segments.sh` 使用合成音视频检查暂停后的片段衔接，`bash scripts/verify-recording-lifecycle.sh` 检查倒计时取消、暂停和控制窗状态，不采集桌面。
- `bash scripts/verify-status-recording.sh` 检查真实录制前后 Patch 只保留主菜单图标，不重复显示系统停止控件，只采集自建纯色测试窗口并丢弃帧，不录音或保存视频。需要已有截屏授权；未授权时明确显示 `SKIP`，不会申请权限。
- `bash scripts/verify-menu-activation.sh` 检查功能窗口的 Dock 生命周期，包括多窗口、关闭重开、隐藏、最小化和窗口交接。`bash scripts/verify-status-window-order.sh` 用两个测试进程连续检查菜单打开期间的窗口顺序及切换到其他应用的行为。后者使用程序触发菜单，还需用真实菜单栏点击验证。锁屏时以 `SKIP` 和退出码 77 结束，不能视为通过。
- `bash scripts/verify-pin-visibility.sh` 使用合成图文窗口检查最近隐藏组的恢复、窗口位置和关闭后的状态，不读取系统剪贴板。
- `bash scripts/verify-pin-ui.sh` 检查贴图选中、工具栏、拖动及隐藏恢复，并用自动退出的普通辅助窗口验证其他应用保持前台时的文字编辑和内嵌标注，以及仅显示图片不激活、单击图片后激活 Patch 的捏合前提。不会切换全屏桌面；跨原生全屏 Space 的实际显示仍需手动验收。可用 `--build-only` 只编译。
- `bash scripts/verify-pin-image-geometry.sh` 用合成图检查整图等比适屏、触点缩放、超屏拖动与裁切绘制的像素一致性，不创建窗口。`bash scripts/verify-toolbar-metrics.sh` 检查 1×／2× 操作栏排布、像素对齐和不缩放图标的交互反馈，真实显示器检查只创建隐藏窗口。`verify-images.sh` 和 `verify-toolbar-motion.sh` 也支持 `--build-only`，用于先编译、再单独运行有参数保护的验证程序。
- `bash scripts/verify-pin-gestures.sh --verify` 将合成滚动事件通过可见测试窗口投递到图片视图，检查未选中及已选中贴图的缩放；短暂显示测试小窗，不激活应用、不注入系统事件。它不替代实际触控板捏合测试。`verify-selection-ui.sh` 的 `--overlay-only` 检查各显示器覆盖层的非激活输入、跨屏焦点和取消通知，不切换真实全屏桌面。
- 原生交互回归见 `scripts/verify-reopen.sh`、`verify-selection-ui.sh`、`verify-pin-ui.sh` 等，需要可用桌面。不要在锁屏或远程会话里把未完成的检查算作通过。

长截图保留完整选区，允许固定栏和浮层保留或重复，不混合像素或编造隐藏内容。无法定位的帧不加入结果，继续采样；自动模式转为手动，已有结果仍可完成或标注。重新框选是可选操作，确认后开始新结果，Esc 返回旧结果。动态布局和多滚动容器不保证都能可靠拼接。

请保持改动聚焦，并说明测试范围。提交问题时只提供可公开的复现资料；不要附带真实用户截图、录音、录屏、凭据或完整系统日志。测试素材优先使用合成内容。安全问题请按 [SECURITY.md](SECURITY.md) 私下报告。

仓库代码使用 MIT 许可证。外部贡献需有权按项目许可证提供；不要提交第三方来源不明的代码、图片或字体。保留第三方许可声明。

开发包使用独立标识 `dev.screenleaf.development`，自己的分支也应更换标识，避免与官方安装包争用系统授权及快捷键。`dist/`、`.build/`、证书、私钥和本机设置不应提交。

- `bash scripts/verify-capture-windows.sh` 检查普通 Patch 窗口可被截图、操作浮层仍被排除；已有授权时只截取自建纯色窗口区域并丢弃像素，未授权则明确跳过像素检查。

本地诊断构建可在签名前将 `Info.plist` 的布尔值 `PatchWindowDiagnosticsEnabled` 设为 `true`。重启后，日志写入应用容器的 `Library/Application Support/Patch/Diagnostics/window-activation.log`，最多保留 200 条菜单、焦点、窗口编号及系统菜单栏状态，不记录窗口文本或剪贴内容。普通构建不设置此键。诊断结束后重新构建普通包即可停用。

贴图手势诊断另需 `dev.screenleaf.development` 标识和布尔值 `PatchPinGestureDiagnosticsEnabled=true`。日志写入该应用临时目录的 `patch-pin-gestures.log`，最多 2000 行，记录应用、窗口、图片视图及缩放四层的手势类型与数值，不记录文字、图像、键盘或坐标。默认构建关闭；仅在定位真实触控板事件时显式启用。

`bash scripts/verify-pin-gestures.sh --interactive` 显示蓝色普通图和橙色合成长图，供真实触控板捏合诊断，180 秒自动关闭；仅输出手势类型、窗口编号和缩放比例，不采集图像或文字。`--verify` 同时覆盖普通、6,000 与 24,000 像素高的合成图，但模拟事件不能替代硬件事件派发验收。
