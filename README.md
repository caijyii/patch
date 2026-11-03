# 小贴 · Patch

**截图、长截图、录屏、标注、贴图，一个 Patch 就够。**

一款原生 macOS 工具，把常用的屏幕记录与桌面参考功能放在一起，减少在多个应用之间切换。

## 功能

- **截图**：框选、窗口或整屏截取，复制或保存。
- **长截图**：自动或手动滚动拼接，完成后复制或标注。
- **录屏**：区域录制，可分别开启系统声音和麦克风，导出 MP4。
- **标注**：箭头、形状、文字、画笔、马赛克与原创贴纸，支持在长图和图片贴图上直接编辑。
- **贴图**：把图片或可编辑文字贴在桌面上，随时对照、隐藏或恢复。
- **文字识别**：提取截图中的中英文文字。
- **主体截图**：识别图像主体，导出透明 PNG。
- **自定义快捷键**：在主页修改快捷键，自动检查冲突。

内容在本机处理，无账户、广告或云上传。

## 安装

需要 **macOS 15+、Apple Silicon（M 系列芯片）**。

- **直接下载**：[GitHub 预览版](https://github.com/caijyii/patch/releases/tag/v0.1.0-preview.3)，提供 **DMG / ZIP**，打开 DMG 或解压 ZIP 后，将 `Patch.app` 拖入「应用程序」。无需开发工具。
- **让 Agent 安装**：把下面这句话交给自己的 Agent。

> 请从 https://github.com/caijyii/patch 的 GitHub Releases 下载适合我的 Mac 的 Patch 安装包并安装。

当前为临时签名、未公证的预览包，首次打开可能需要你在系统设置中确认。[安装与权限说明](docs/install.md)

### 从源码构建

开发者需安装支持 Swift 6 的 Xcode 或 Command Line Tools，在项目目录运行：

```sh
bash scripts/build-sandbox-app.sh
```

构建结果：`.build/distribution-check/Patch.app`（Patch Development）。这是临时签名的本地开发包，请避免与其他 Patch 版本同时运行。详见[构建与签名说明](Distribution/README.md)。

使用时请注意：

- 按需授予屏幕、麦克风和辅助功能／设备控制权限；授权未生效时重启应用。
- 长截图只框选滚动正文，避开固定标题栏。拼接暂停时，小幅回滚并稍停即可尝试接续。
- 关闭主页后仍驻留菜单栏；选择「退出」才会结束应用。贴图不会在下次启动时恢复。

## 默认快捷键

⌥ 为 Option，⌘ 为 Command。可在主页修改快捷键。

| 快捷键 | 功能 |
| --- | --- |
| ⌥1 | 截图 |
| ⌥2 | 长截图 |
| ⌥3 | 提取文字 |
| ⌥4 | 贴出剪贴板 |
| ⌥5 | 开始／停止录屏 |
| ⌥6 | 主体截图 |
| ⌥7 | 隐藏／显示全部贴图 |
| ⌘Q | 退出（Patch 位于前台时） |

## 反馈与贡献

欢迎通过 [Issues](https://github.com/caijyii/patch/issues) 反馈问题或建议，也可联系 [caijyii@163.com](mailto:caijyii@163.com)。

[开发与测试](CONTRIBUTING.md) · [隐私说明草稿](docs/privacy-policy.md) · [发布进度](docs/release-checklist.md)

## 许可证

[MIT](LICENSE) · Copyright © 2026 [caijyii](https://github.com/caijyii)。

[名称与 Logo 使用说明](BRANDING.md) · [第三方资源声明](THIRD_PARTY_NOTICES.md)
