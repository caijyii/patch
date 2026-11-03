# 小贴 · Patch

**截图、长截图、录屏、标注、贴图，一个 Patch 就够。**

Patch 是一款集这五项常用功能于一体的原生 macOS 工具。截取屏幕、保存长篇正文、录下操作过程、标注重点，再把参考图片或文字贴在桌面上，减少在多个应用之间来回切换。

做 Patch 的初衷很简单：希望长截图、录屏和贴图也能同时出现在一个顺手的工具里，配合日常截图与标注，满足自己记录、说明和对照资料的需要。

这是 Patch 的开源项目，目前尚未上架 Mac App Store。最低系统版本为 macOS 15；当前验收以 Apple Silicon 为主，Intel 支持尚未完成验证。

## 功能

- 截图：自由框选、窗口与整屏截取，直接复制或保存。
- 长截图：正文框选，自动上下滚动、手动反向与可靠重叠后的自动接续；完成后复制，或进入原位标注。
- 录屏：区域录制，系统声音和麦克风独立开关，导出 MP4。
- 标注：在截图、长截图和图片贴图上添加箭头、方框、圆形、文字、序号、画笔、马赛克和原创矢量贴纸。
- 贴图：图片与可编辑文字，多贴图显隐、缩放及图片原位标注。

此外还提供：

- 主体截图：本地识别、增减主体、透明 PNG 导出。
- OCR：使用系统 Vision 在本地识别中英文。
- 八窗格主页：四季窗景、快捷键编辑及冲突检查。

内容由本机系统框架处理，当前没有账户、广告、分析 SDK 或云上传服务。权限与本地数据行为见[隐私说明草稿](docs/privacy-policy.md)。

## 快捷键

| 默认组合 | 功能 |
| --- | --- |
| ⌥1 | 截图 |
| ⌥2 | 长截图 |
| ⌥3 | 提取文字 |
| ⌥4 | 贴出剪贴板 |
| ⌥5 | 录屏；录制中再次按下可停止 |
| ⌥6 | 主体截图 |
| ⌥7 | 隐藏／显示全部贴图 |
| ⌘Q | Patch 位于前台时退出 |

点击主页快捷键即可持续录入新组合。点击别处或「保存」提交，取消／Esc 放弃未保存草稿；冲突时保存禁用，修正后恢复。系统已占用的组合可能不可用，可以改为 ⌃⌥ 等组合。⌘Q 不是抢占其他应用的全局退出键。

关闭主页后应用继续驻留菜单栏；从主页或菜单选择「退出」才会退出。贴图不在下次启动时恢复。

## 本地构建

需要支持 Swift 6 的 Apple 工具链；可以使用完整 Xcode，或兼容的 Command Line Tools。无需安装第三方包。

```sh
bash scripts/build-sandbox-app.sh
```

结果在 `.build/distribution-check/Patch.app`，名称为 Patch Development，采用独立开发标识及临时签名。脚本不会自动启动；不要与试用包同时运行，避免争用快捷键。它是本地沙盒构建，**不是可以上传的 App Store 安装包**。

默认使用 `xcrun --show-sdk-path` 选中的 SDK；需要时设置 `SCREENLEAF_SDK`。原始本地诊断构建仍可运行 `bash scripts/build-app.sh`，输出到 `dist/`，但该路径没有启用沙盒。更多说明见 [Distribution](Distribution/README.md)。

## 权限与使用边界

首次截图／长截图／录屏需要屏幕权限。开启麦克风时需要录音权限；长截图自动滚动与横向过滤需要设备控制／辅助功能权限。授权后若未生效，可能需要重启应用。系统权限名称随 macOS 版本变化。

长截图请框选可滚动的正文，排除固定标题栏和浮层。大段空白、重复图案、动画和快速跳跃可能导致拼接暂停；小幅回滚、稍停，找到可靠重叠后会继续。通用应用兼容性仍在验证中。

临时签名开发包的权限不等于正式签名包的权限。系统中保留多个同名旧包可能使权限设置或重开应用指向错误版本，请只使用一个明确的试用入口。

## 开发与验证

```sh
bash scripts/test.sh
bash scripts/verify-preferences.sh --model-only
bash scripts/verify-reopen.sh
```

第一项检查基础模型与文件流程；原生窗口回归需要可用桌面。测试脚本、运行边界和贡献要求见 [CONTRIBUTING.md](CONTRIBUTING.md)。测试通过不代表 Apple 审核已通过。

导出供人工审查的源码快照：

```sh
python3 scripts/package-source.py .build/Patch-source-review.zip
```

它仅包含明确列出的源码、资源和文档，不包含构建产物、历史试用包或测试录屏；公开前仍须复核内容。发布准备状态见[清单](docs/release-checklist.md)。

## 许可证

项目使用 [MIT](LICENSE) 许可证，支持修改、商用和再分发。Copyright © 2026 caijyii。名称与 Logo 的来源使用说明见 [BRANDING.md](BRANDING.md)，第三方素材与来源见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。商店定价尚未决定，开源与商店发行可以并行。

## 作者与联系

作者：[caijyii](https://github.com/caijyii) · 支持邮箱：[caijyii@163.com](mailto:caijyii@163.com)。

源码：[caijyii/patch](https://github.com/caijyii/patch) · 问题反馈：[Issues](https://github.com/caijyii/patch/issues)。
