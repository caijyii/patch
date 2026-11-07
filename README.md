# Patch

[![Version: 0.1.2](https://img.shields.io/badge/Version-0.1.2-6B8E6E?style=flat)](https://github.com/caijyii/patch/releases/tag/v0.1.2)
[![Platform: macOS 15+](https://img.shields.io/badge/Platform-macOS%2015%2B-607D8B?style=flat)](docs/install.md)
[![Architecture: Apple Silicon](https://img.shields.io/badge/Architecture-Apple%20Silicon-607D8B?style=flat)](docs/install.md)
[![License: MIT](https://img.shields.io/badge/License-MIT-6B8E6E?style=flat)](LICENSE)
[![Language: 中文 / English](https://img.shields.io/badge/Language-%E4%B8%AD%E6%96%87%20%2F%20English-6B8E6E?style=flat)](README.en.md)

[简体中文](README.md) · [English](README.en.md)

**截图、长截图、录屏、标注、贴图，一个 Patch 就够。**

## 功能

- **截图**：框选、窗口或整屏截取，复制或保存。
- **长截图**：自动或手动滚动拼接，支持复制、保存、贴图、提取文字和标注。
- **录屏**：区域录制，可分别开启系统声音和麦克风，导出 MP4。
- **标注**：支持箭头、形状、文字、画笔、马赛克与原创贴纸，可直接编辑长图和图片贴图。
- **桌面贴图**：在桌面上显示图片或可编辑文字，支持图片缩放及贴图隐藏、恢复。
- **文字识别**：识别并复制截图中的中英文文字。
- **主体截图**：识别图像主体，导出透明 PNG。
- **剪贴记录**：查看、筛选和复制最近的图片、文字与视频文件引用。
- **自定义快捷键**：每项功能最多两组快捷键。

内容在本机处理，无账户、广告或云上传。支持简体中文和英文，以及跟随系统、浅色和深色外观。

## 安装

需要 **macOS 15+、Apple Silicon（M 系列芯片）**。

- **直接下载**：[最新正式版 v0.1.2](https://github.com/caijyii/patch/releases/tag/v0.1.2)，推荐下载 **DMG**；ZIP 是另一种安装方式，二选一即可。打开 DMG 或解压 ZIP 后，将 `Patch.app` 拖入「应用程序」。`Source code` 是源码，不是普通用户的安装包；安装无需开发工具。
- **让 Agent 安装**：把下面这句话交给自己的 Agent。

> 请从 https://github.com/caijyii/patch 的 GitHub Releases 下载适合我的 Mac 的 Patch 安装包并安装。

当前安装包采用临时签名，尚未公证，首次打开可能需要你在系统设置中确认。[安装与权限说明](docs/install.md)

目前需手动更新：到 [最新正式 Release](https://github.com/caijyii/patch/releases/latest) 下载新版，按[更新步骤](docs/install.md#更新与卸载)保存所需贴图、退出并替换旧版；应用没有自动检查或安装更新。

### 从源码构建

开发者需安装支持 Swift 6 的 Xcode 或 Command Line Tools，在项目目录运行：

```sh
bash scripts/build-sandbox-app.sh
```

构建结果：`.build/distribution-check/Patch.app`（Patch Development）。这是临时签名的本地开发包，请避免与其他 Patch 版本同时运行。详见[构建与签名说明](Distribution/README.md)。

## 使用须知

- 权限按功能申请；授权未生效时重启应用。
- 启动时读取当前剪贴板，运行期间自动收录图片、文字与视频文件引用，没有收录开关，也不能识别所有敏感内容。记录仅存于本次进程内存，退出后清空；贴图也随退出关闭。关闭首页后仍在菜单栏运行并继续收录；需从 Patch 菜单选择「退出」。
- 长截图遇到动态布局或多个滚动区域时可能无法可靠拼接，固定栏与浮层可能保留或重复。

详细操作见[使用说明](docs/usage.md)，数据处理见[隐私说明](docs/privacy-policy.md)。

## 默认快捷键

⌥ 为 Option，⌘ 为 Command。可在主页修改，每项功能最多设置两组快捷键。

| 快捷键 | 功能 |
| --- | --- |
| ⌥1 | 截图 |
| ⌥2 | 长截图 |
| ⌥3 | 主体截图 |
| ⌥4 | 开始／停止录屏 |
| ⌥5 | 提取文字 |
| ⌥6 | 贴出剪贴板 |
| ⌥7 | 剪贴记录 |
| ⌥8 | 批量贴出最近记录（默认 5 条） |
| ⌥9 | 隐藏／显示全部贴图 |
| ⌘Q | 退出（Patch 位于前台时） |

## 近期更新

0.1.2 新增截图／录屏时隐藏桌面贴图的独立选项，默认开启；修复后台错误提示未获得焦点、导致操作看似卡住的问题。

详见[更新说明](docs/release-notes.md)。

## 反馈与贡献

欢迎通过 [Issues](https://github.com/caijyii/patch/issues) 反馈问题或建议，也可发送邮件至 [caijyii@163.com](mailto:caijyii@163.com)。

## 许可证

[MIT](LICENSE) · Copyright © 2026 [caijyii](https://github.com/caijyii)。

[名称与 Logo 使用说明](BRANDING.md) · [第三方资源声明](THIRD_PARTY_NOTICES.md)
