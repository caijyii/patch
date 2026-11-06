# 资源与依赖说明

## 系统框架

应用使用 macOS 提供的 AppKit、ScreenCaptureKit、Vision、AVFoundation、CoreGraphics 等框架。Swift 包未声明第三方包依赖；这些系统框架不随应用打包。

## Patch 原创资源

署名：caijyii。Copyright (c) 2026 caijyii，MIT License。机器可读来源说明见 `Resources/ArtworkNotices.json`，构建时随应用及 MIT 许可文本一起打包；贴纸目录另附许可及 `sources.json`。这些信息不写入用户导出的截图或视频。

- 应用图标：`Sources/Patch/IconArtwork.swift`。
- 四季窗景：`HomeSceneryArtwork.swift`、`HomeSeason.swift`。
- 32 枚矢量贴纸：`Resources/PatchStickers/`；生成源码在 `scripts/sticker-artwork/`，来源和哈希记录在 `Resources/PatchStickers/sources.json`。

上述贴纸来源记录注明为本项目借助 Codex 编写的原创矢量路径。旧的 `fluent-*` 标识只用于兼容查找，不代表发行包使用 Fluent Emoji 图稿。首次公开前应由维护者复核素材权利及署名。

## 历史 Fluent Emoji 资源

源码树保留 `Resources/FluentEmoji/`，版权属于 Microsoft Corporation，按其中的 [MIT 许可证](Resources/FluentEmoji/LICENSE) 分发。当前构建脚本只复制 `PatchStickers`，不把该历史资源目录放入应用。若保留或再分发这些文件，必须一并保留原版权及许可文本。
