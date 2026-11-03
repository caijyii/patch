# 安装 Patch

适用于 **Apple Silicon（M 系列芯片）、macOS 15 或更新版本**。无需 Xcode 或 Command Line Tools；Intel 暂不提供安装包。

## 直接下载

1. 如果收到维护者直接提供的 DMG，可从第 2 步开始。GitHub 附件的访问取决于仓库权限。否则，从 [GitHub Releases](https://github.com/caijyii/patch/releases) 下载 DMG 或 ZIP。`Source code` 是源码，不是安装包。
2. **DMG**：双击打开，将 `Patch.app` 拖到旁边的「Applications」文件夹；安装后推出磁盘映像。**ZIP**：解压后将 `Patch.app` 拖入「应用程序」。先退出其他 Patch 版本；已有安装时先确认是否替换。
3. 从「应用程序」打开 Patch，按实际使用的功能授权。

当前预览包采用临时签名（ad-hoc），**尚无 Developer ID 签名，也未经过 Apple 公证**。若 macOS 提示无法验证开发者，在确认来源与文件完整性后，可按照 [Apple 官方说明](https://support.apple.com/102445)，到「系统设置 → 隐私与安全性」查看是否提供「仍要打开」。如果系统提示恶意软件或文件损坏，请停止安装并反馈，不要关闭 Gatekeeper 或绕过警告。

首次截图／录屏需要屏幕权限；麦克风录音和长截图控制权限按需申请。系统验证与授权由你本人完成。更新临时签名包后可能需要重新授权；请只保留一个正在使用的安装入口。

## 让 Agent 安装

可以把这段话交给自己的 Agent：

> 请从 https://github.com/caijyii/patch 的 GitHub Releases 下载适合我的 Mac 的 Patch 安装包并安装。

<details>
<summary>供 Agent 查阅的安装细节</summary>

Agent 应遵守以下顺序：

1. 通过 GitHub Releases 页面或 API `https://api.github.com/repos/caijyii/patch/releases` 读取发行信息。预览版可能不出现在 `/releases/latest` 中；检查 `draft`、`prerelease`、版本与发布时间。
2. 仅下载所选发行版的附件，检查清单中的系统、架构、文件名、签名状态与下载地址；本预览版要求 `arm64`、`macOS 15+`。
3. 比对所选 DMG 或 ZIP 的 SHA-256 与同版校验文件及清单。`v0.1.0-preview.1` 后补的 DMG 使用 `SHA256SUMS-DMG.txt` 和 `dmg-manifest.json`；原 ZIP 使用 `SHA256SUMS.txt` 和 `release-manifest.json`。校验值可检查文件一致性，不能替代 Developer ID 签名或证明来源可信。
4. ZIP 在临时目录解压；DMG 只读挂载，完成后推出。确认包内是预期的 `Patch.app`（DMG 另有指向 `/Applications` 的快捷入口）；验证包标识 `dev.screenleaf.app`、版本、arm64 架构，以及 `codesign --verify --deep --strict`。临时签名校验通过不等于公证通过。
5. 安装到 `/Applications` 或用户选择的 `~/Applications`。若已有 Patch 或同名应用正在运行，先确认替换范围，保留可恢复的旧包，不自动结束正在截图或录制的会话。
6. 保留下载隔离属性，首次启动遵循系统提示；不自动批准隐私权限，不要求用户向 Agent 提供密码。

</details>

## 手动校验

在下载目录运行（文件名以当前发行版为准）：

```sh
shasum -a 256 Patch-0.1.0-preview.2-macOS-arm64.zip
```

将输出与同一发行版的 `SHA256SUMS.txt` 比对。DMG 同样可用 `shasum -a 256 文件名.dmg` 校验；当前版本的 DMG 与 ZIP 均记录在 `SHA256SUMS.txt` 中。旧版 `v0.1.0-preview.1` 后补 DMG 的独立校验文件为 `SHA256SUMS-DMG.txt`。只需下载你选择的格式。

## 更新与卸载

预览版暂不自动更新。从 Releases 下载新版，退出旧版后替换即可。卸载时先退出 Patch，再把应用移至废纸篓；本操作不会删除你已保存的截图或录屏。
