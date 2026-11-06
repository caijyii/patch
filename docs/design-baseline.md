# Patch 视觉与文案基线

## 使用范围

本文记录现有可复用设计模式；它们是新增界面的默认参照，并非不可变的视觉宪法。依据为源码与仓库设计素材，未代替当前发行包的实际界面验收。功能行为见 [产品基线](product-baseline.md)，名称与标识的使用声明仍见 [BRANDING.md](../BRANDING.md)。

## 首页与功能窗口

首页用拱形窗框、玻璃层与四季自然景色组织功能入口；按钮文字和点击目标与玻璃动画分离，保持清晰、稳定。首页浅色光晕随窗景季节变化：春偏灰绿、夏偏青绿、秋保留暖色、冬季冷色雪景搭配少量雪花、淡暖阳和低饱和暖光；深色光晕保持原样。更多设置及其他使用光晕的功能窗口共享同一季节配色，保留不透明底色及各自的光晕范围；日期、时区变化或唤醒后同步刷新。窗景插画仅用于首页。

可复用来源：[Home.swift](../Sources/Patch/Home.swift) 的 `HomeFeatureTile`、`HomeWindowPalette`；[WindowAmbientBackground.swift](../Sources/Patch/WindowAmbientBackground.swift)；[HomeScenery.swift](../Sources/Patch/HomeScenery.swift) 与 [HomeSeason.swift](../Sources/Patch/HomeSeason.swift)。[四季素材](../design/home-seasons/) 是插画参考，不是完整窗口截图。

“安静、自然、轻量”可作为这些实现的审美归纳，尚不构成新页面必须使用插画、固定绿色或季节机制的要求。

## 配色、层级与控件

| 场景 | 现有模式与复用入口 |
| --- | --- |
| 首页与设置 | `HomeWindowPalette` 提供深浅外观下的正文、次要文字、边缘和玻璃颜色，见 [Home.swift](../Sources/Patch/Home.swift) |
| 截图与贴图操作栏 | `ToolbarPalette` 使用蓝灰语义色，区分普通、悬停、按下和选中状态；`ToolbarMetrics` 根据显示倍率选择尺寸，见 [AnnotationControls.swift](../Sources/Patch/AnnotationControls.swift) |
| 普通带标题窗口 | `PatchWindowTitle` 统一左侧标题，保留原生窗口标题供菜单和辅助功能使用，见 [WindowTitle.swift](../Sources/Patch/WindowTitle.swift) |
| 历史记录 | 原生系统文字和控件，卡片直接提供复制、删除等动作，见 [RecentContentWindow.swift](../Sources/Patch/RecentContentWindow.swift) |

复用对应场景的语义色和组件，不另抄一套色值或把不同场景强行合成同一种配色。这些来源按场景定义尺寸，本文不另建覆盖所有页面的字号、间距和圆角表；不能将一次出现的数值推断为全局 token。

## 内容表面与清晰度

[当前实现](../Sources/Patch/ImageTools.swift) 中，普通图文贴图采用小圆角、细边线和柔和阴影；透明主体贴图保留透明轮廓。文字贴图正文为 16 pt，OCR 结果正文为 14 pt，具体实现见 [ImageTools.swift](../Sources/Patch/ImageTools.swift)。这些是特定内容表面的设置，不是所有正文的统一字号。

工具栏在 1× 显示器使用较大的原生图标与点击区，2× 保持紧凑，空间不足时换行。复用 `ToolbarMetrics`，避免将紧凑位图整体放大来替代清晰度适配。

## 外观、动效与可访问性

外观支持系统、浅色、深色，使用已存在的主题路径；设置入口见 [AppOptionsView.swift](../Sources/Patch/AppOptionsView.swift)。新增控件应覆盖可读性、选中、悬停、按下和不可用状态，不能只检查浅色静态画面。

现有首页景色在减少动态效果、窗口不可见或不活跃等条件下停止动画，见 `HomeSceneryView` 所在的 [HomeScenery.swift](../Sources/Patch/HomeScenery.swift)。首页玻璃有减少透明度适配，见 [Home.swift](../Sources/Patch/Home.swift)。新装饰效果优先沿用这些退化方式；这不表示整个应用的可访问性已经完整验证。

## 文案与反馈

界面文案经 [Localization.swift](../Sources/Patch/Localization.swift) 的 `L` / `AppLocalization` 处理，支持简体中文与英文；捕获和剪贴板中的原始内容不翻译。新增文案同时核对中英文长度和真实点击区域。

现有文案倾向直接说明动作、结果和恢复路径，例如“重新框选”“已保留当前长图”“快捷键暂时不可用”。新增反馈优先说明用户还能做什么；保持“贴图”“剪贴记录”“提取文字”等既有术语。语气归纳来自当前文案，不将个别提示推广为所有错误都只能轻提示。

## 修改与验收

仅在设计模式或使用规则改变时更新相应章节；数值仍以对应代码为实现来源。相关 UI 检查按 [CONTRIBUTING.md](../CONTRIBUTING.md) 选取，不要求普通改动遍历全部工具。新增表面没有对应模式时说明新选择及理由，不因文档未覆盖而强行套用首页设计。
