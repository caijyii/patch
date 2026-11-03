# Mac App Store 文案与审核说明草稿

此文件供首次提交前审核，不代表名称已注册、应用已上架或功能已获 Apple 批准。版权署名为 caijyii，支持邮箱为 caijyii@163.com；定价、Apple 账号发行主体及公开页面地址尚未决定。

## 商品页

应用名称候选：小贴 · Patch

副标题候选：截图、长截图、录屏、标注、贴图

简介：截图、长截图、录屏、标注、贴图，一个 Patch 就够。保存长篇正文、录下操作过程、标注截图重点，把参考资料贴在桌面上，减少来回切换应用。

说明草稿：

Patch 将截图、长截图、录屏、标注和贴图集合在一个原生 macOS 工具里。

需要留下一段长文，可以拼接长截图；需要说明操作过程，可以录制视频；需要边看边对照，可以把图片或文字贴在桌面上。加上日常截图和标注，常用的屏幕记录与参考功能，在同一个工具里就能找到。

- 自由框选、窗口与整屏截图，直接标注、复制或保存。
- 对静态滚动正文拼接长图，支持手动滚动与自动滚动，并可在长图上标注。
- 区域录屏，按需开启系统声音和麦克风，导出 MP4。
- 箭头、文字、画笔、马赛克和原创贴纸，让重点清楚可见。
- 图片与可编辑文字贴图，可同时保留多张，并统一隐藏或显示。

此外，Patch 还提供：

- 提取中英文文字，选择图片主体并导出透明 PNG。
- 自定义快捷键与四季窗景，让常用功能随手可用。

当前版本使用本机系统框架处理截图、文字识别和录音，不要求创建账户。

长截图适合静态正文。固定标题栏、动画、大段重复内容或快速跳跃可能影响拼接；使用时请框选正文并适当减小滚动幅度。

关键词候选：截图,标注,贴图,录屏,长截图,文字识别,OCR,透明背景,屏幕工具

系统要求：macOS 15 或更新版本。首发架构与商店可选设备范围仍需最终构建和测试确认。

## 截图制作清单

全部使用合成内容；不要把真实聊天、工作文档、个人照片或系统账户信息带进商店图片。

1. 功能总览：以“截图、长截图、录屏、标注、贴图，一个 Patch 就够”为标题，展示五项功能的合成示例，先传达集成价值；四季主页作为辅助画面。
2. 截图标注：箭头、文字、马赛克，展示清晰重点。
3. 图片和文字贴图：并排对照的合成资料。
4. 长截图与原位标注：合成文档，正文连续且可读。
5. OCR 与主体透明导出：自有或权利明确的示例。
6. 录屏控制：系统声音与麦克风选项。

以上只是制作内容清单，尚未生成符合最终商店规格的截图。

## App Review Notes 草稿

Patch combines screenshots, scrolling screenshots, screen recording, image annotation, and image/text pinning in one native macOS utility. No login is required.

The app runs from the menu bar. Closing the Home window keeps it running; choose Quit in the menu or Home to exit.

Screen capture permission is requested when starting a capture workflow. Microphone permission is requested only when the microphone option is enabled. Scrolling capture requests control/accessibility permission before selection to support automatic scrolling and horizontal scroll filtering. These permissions serve the user-initiated capture workflow.

To test scrolling capture, use a static document with varied text, select only the scrollable body, and exclude fixed headers. Scroll slowly or use the automatic controls. If overlap becomes unreliable, the app retains the existing result; a small reverse scroll can restore overlap. Finish copies the result; Annotate opens the inline annotation workspace.

Screen capture, OCR and recording content is processed locally. The current app has no account service, analytics SDK, advertising or app-managed content upload.

Before submission, attach a synthetic test document and add exact permission labels for the tested macOS version. Confirm all statements above against the final signed build. Successful local operation is not a claim of App Store policy compatibility.

## 尚需填写／确认

- GitHub 账号为 caijyii，版权署名为 caijyii；仓库名称和 Apple 账号发行主体尚待确认。
- 支持邮箱已确认：caijyii@163.com；仍需支持页面和隐私政策公开 URL。
- 定价、类别、年龄评级、发布地区及相应声明。
- 正式版本号、构建号、Bundle Identifier、签名团队。
- 最终权限说明及审核附件；不得上传临时证书或真实用户测试素材。
