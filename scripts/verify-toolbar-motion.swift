import AppKit
import Darwin

// A small injected canvas isolates the shared controls from image/OCR/recording services.
// Document rendering and undo are exercised separately by verify-images.sh.
enum ImageToolsTool: String, CaseIterable {
    case arrow = "箭头", rectangle = "矩形", ellipse = "圆形", text = "文字"
    case number = "序号", pen = "画笔", mosaic = "马赛克", sticker = "贴纸"
}
struct ImageToolsAnnotation {
    var tool: ImageToolsTool
    var color: NSColor = .systemRed
    var width: CGFloat = 3
    var fontSize: CGFloat = 48
    var numberSize: CGFloat = 24
    var mosaicBlockSize: CGFloat = 12
    var text = "🌼"
}
@MainActor final class ImageToolsCanvas {
    var onAnnotationSelectionChange: ((ImageToolsAnnotation?) -> Void)?
    var selectedAnnotation: ImageToolsAnnotation?
    var tool = ImageToolsTool.arrow
    var isDrawingEnabled = false
    var canUndo = false
    var annotationColor: NSColor = .systemRed
    var annotationWidth: CGFloat = 3
    var annotationFontSize: CGFloat = 18
    var annotationNumberSize: CGFloat = 24
    var annotationSticker = "🌼"
    var mosaicBlockSize: CGFloat = 12
    func beginParameterEditing() {}
    func endParameterEditing() {}
    func finishTextEditing() {}
    func undoAnnotation() {}
    func deselectAnnotation() { selectedAnnotation = nil; onAnnotationSelectionChange?(nil) }
    func updateSelectedAnnotation(color: NSColor? = nil, width: CGFloat? = nil, fontSize: CGFloat? = nil,
                                  numberSize: CGFloat? = nil, mosaicBlockSize: CGFloat? = nil, sticker: String? = nil) {
        guard var selected = selectedAnnotation else { return }
        if let color { selected.color = color }
        if let width { selected.width = width }
        if let fontSize { selected.fontSize = fontSize }
        if let numberSize { selected.numberSize = numberSize }
        if let mosaicBlockSize { selected.mosaicBlockSize = mosaicBlockSize }
        if let sticker, selected.tool == .sticker { selected.text = sticker }
        selectedAnnotation = selected
        onAnnotationSelectionChange?(selected)
    }
}

private struct ToolbarFailure: Error, CustomStringConvertible { let description: String }
private final class QuietButton: SelectionButton { override var allowsMotion: Bool { false } }
private final class MotionButton: SelectionButton { override var allowsMotion: Bool { true } }
private final class OpaqueToolbarMaterial: ToolbarMaterialView {
    override var reducesTransparency: Bool { true }
}
private final class StandardToolbarMaterial: ToolbarMaterialView {
    override var reducesTransparency: Bool { false }
}
private final class SolidBackdrop: NSView {
    var color: NSColor = .white
    override func draw(_ dirtyRect: NSRect) { color.setFill(); bounds.fill() }
}
private final class AppearancePreview: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.96, alpha: 1).setFill(); bounds.fill()
        NSColor(calibratedWhite: 0.10, alpha: 1).setFill()
        CGRect(x: 0, y: bounds.height / 2, width: bounds.width, height: bounds.height / 2).fill()
    }
}
private final class PorcelainPreview: NSView {
    static let columnWidth: CGFloat = 720
    static let gutter: CGFloat = 18

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.87, alpha: 1).setFill(); bounds.fill()
        for column in 0..<3 {
            let rect = CGRect(x: Self.gutter + CGFloat(column) * (Self.columnWidth + Self.gutter),
                              y: Self.gutter, width: Self.columnWidth, height: bounds.height - Self.gutter * 2)
            if column == 2 {
                NSColor(srgbRed: 0.12, green: 0.36, blue: 0.68, alpha: 1).setFill(); rect.fill()
                NSColor(srgbRed: 0.88, green: 0.53, blue: 0.20, alpha: 1).setFill()
                CGRect(x: rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height).fill()
            } else {
                NSColor(calibratedWhite: column == 0 ? 0.95 : 0.12, alpha: 1).setFill(); rect.fill()
            }
            // Generated detail exposes any unwanted transparency without capturing a desktop.
            let detail = column == 0 ? NSColor(calibratedWhite: 0.78, alpha: 0.32) : NSColor.white.withAlphaComponent(0.10)
            detail.setFill()
            for row in 0..<12 {
                CGRect(x: rect.minX + 28, y: rect.minY + 28 + CGFloat(row) * 57,
                       width: row.isMultiple(of: 3) ? 280 : 620, height: 8).fill()
            }
        }
    }
}

@main private struct ToolbarMotionVerification {
    @MainActor static func main() {
        guard CommandLine.arguments.count == 2, CommandLine.arguments[1].hasPrefix("/") else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
            fputs("FAIL: toolbar verification timed out\n", stderr); exit(1)
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        var failures = 0
        let checks: [(String, @MainActor () throws -> Void)] = [
            ("sticker defaults are distinct from text and persist per-tool sizes", preferences),
            ("nature palette appears only for stickers and keeps explicit choices stable", palette),
            ("selected stickers update immediately without rewriting defaults on selection", selection),
            ("compact rows wrap without overlapping or leaving toolbar bounds", geometry),
            ("one shared panel groups the main strip and optional parameter row", rowSurfaces),
            ("the complete screenshot main strip fits a common narrow viewport without shrinking controls", compactMainGeometry),
            ("changing and closing tools removes obsolete parameters and surfaces", parameterLifecycle),
            ("button decoration preserves native action, disabled state and full hit targets", hitTargets),
            ("shared action captions and icons remain legible in light and dark windows", appearance),
            ("Chinese action captions retain their native text-cell size after wrapping", captionGeometry),
            ("selected light-theme captions, glyphs and parameter samples keep stronger contrast", toolbarAppearance),
            ("light toolbar surfaces stay opaque and uniform without backdrop dependence", reducedTransparency),
            ("color swatches remain visible under hover, press and selection", colorSwatchHover),
            ("hover and press retain visible feedback without resampling glyphs", motion),
            ("all four mode captions keep selection distinct from hover and refresh state immediately", modeFeedback),
            ("vector sticker library is complete and its compact picker remains usable", stickerLibrary),
            ("shared toolbar renders to an inspectable native preview", preview)
        ]
        for (name, body) in checks {
            do { try body(); print("PASS: \(name)") }
            catch { failures += 1; print("FAIL: \(name): \(error)") }
        }
        print("COMPLETE: toolbar motion verification: \(checks.count - failures) PASS, \(failures) FAIL")
        exit(failures == 0 ? 0 : 1)
    }

    @MainActor private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw ToolbarFailure(description: message) }
    }

    @MainActor private static func fixture() -> (ImageToolsCanvas, AnnotationControls, MemoryPreferencesStorage) {
        let memory = MemoryPreferencesStorage()
        let canvas = ImageToolsCanvas()
        return (canvas, AnnotationControls(canvas: canvas, preferences: PreferencesStore(storage: memory)), memory)
    }

    @MainActor private static func actions() -> [NSView] {
        let buttons = [SelectionButton("复制", symbol: "doc.on.doc") {},
                       SelectionButton("保存", symbol: "square.and.arrow.down") {},
                       SelectionButton("贴图", symbol: "pin") {}]
        buttons.forEach { $0.imagePosition = .imageOnly }
        return buttons
    }

    @MainActor private static func surfaces(in toolbar: SelectionToolbar) -> [ToolbarMaterialView] {
        toolbar.subviews.compactMap { $0 as? ToolbarMaterialView }.sorted { $0.frame.maxY > $1.frame.maxY }
    }

    @MainActor private static func arrange(_ toolbar: SelectionToolbar, width: CGFloat) {
        toolbar.frame.size = toolbar.arrange(maxWidth: width)
        toolbar.layoutSubtreeIfNeeded()
    }

    @MainActor private static func render(_ view: NSView) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw ToolbarFailure(description: "Cannot create native preview bitmap")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let normalized = bitmap.converting(to: .sRGB, renderingIntent: .default) else {
            throw ToolbarFailure(description: "Cannot normalize native preview color space")
        }
        return normalized
    }

    @MainActor private static func writePreview(_ view: NSView, name: String) throws {
        let bitmap = try render(view)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw ToolbarFailure(description: "Cannot encode native preview")
        }
        try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).appendingPathComponent(name))
    }

    private static func whiteComposite(_ color: NSColor) -> [CGFloat] {
        // render() converts the entire bitmap. colorAt returns its RGB components
        // in a generic wrapper, so converting the NSColor again misreads the pixels.
        return [color.redComponent, color.greenComponent, color.blueComponent].map {
            $0 * color.alphaComponent + 1 - color.alphaComponent
        }
    }

    private static func luminance(_ color: NSColor) -> CGFloat {
        let values = whiteComposite(color).map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return values[0] * 0.2126 + values[1] * 0.7152 + values[2] * 0.0722
    }

    private static func distance(_ first: NSColor, _ second: NSColor) -> CGFloat {
        zip(whiteComposite(first), whiteComposite(second)).map { abs($0 - $1) }.max()!
    }

    private static func sample(_ bitmap: NSBitmapImageRep, u: CGFloat = 0.5, v: CGFloat = 0.12) -> NSColor {
        bitmap.colorAt(x: min(bitmap.pixelsWide - 1, max(0, Int(CGFloat(bitmap.pixelsWide) * u))),
                       y: min(bitmap.pixelsHigh - 1, max(0, Int(CGFloat(bitmap.pixelsHigh) * v))))!
    }

    @MainActor private static func contentLuminance(_ view: NSView) throws -> CGFloat {
        let bitmap = try render(view)
        var ink: [CGFloat] = []
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let value = luminance(bitmap.colorAt(x: x, y: y)!)
                if value < 0.35 { ink.append(value) }
            }
        }
        try require(ink.count >= 3, "Rendered content contains no readable dark glyph strokes")
        // Average the darkest strokes, avoiding a single antialiased edge pixel.
        let core = ink.sorted().prefix(min(8, ink.count))
        return core.reduce(0, +) / CGFloat(core.count)
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    @MainActor private static func preferences() throws {
        let memory = MemoryPreferencesStorage()
        let store = PreferencesStore(storage: memory)
        try require(store.annotation(for: "贴纸").fontSize == 36 && store.annotation(for: "文字").fontSize == 18,
                    "Sticker and text share the wrong initial size")
        var value = store.annotation(for: "贴纸"); value.fontSize = 96
        store.setAnnotation(value, for: "贴纸")
        try require(PreferencesStore(storage: memory).annotation(for: "贴纸").fontSize == 96, "Sticker size was lost")
        try require(store.annotation(for: "文字").fontSize == 18, "Sticker setting changed text")
        let (canvas, controls, backing) = fixture()
        let ranges: [(ImageToolsTool, Double, Double)] = [(.arrow, 0.5, 12), (.text, 8, 72),
            (.number, 8, 64), (.sticker, 8, 96), (.mosaic, 1, 32)]
        for (tool, lower, upper) in ranges {
            controls.choose(tool: tool)
            try require(controls.sizeControl.slider.minValue == lower && controls.sizeControl.slider.maxValue == upper,
                        "\(tool) does not use the common fine-adjustment range")
        }
        let writes = backing.writeCount
        canvas.selectedAnnotation = ImageToolsAnnotation(tool: .text, fontSize: 180)
        canvas.onAnnotationSelectionChange?(canvas.selectedAnnotation)
        try require(controls.sizeControl.valueLabel.stringValue == "180" && canvas.selectedAnnotation?.fontSize == 180
                    && backing.writeCount == writes && !controls.sizeControl.plus.isEnabled,
                    "Selecting an older large annotation silently clamps it or rewrites defaults")
        controls.sizeControl.minus.performClick(nil)
        try require(canvas.selectedAnnotation?.fontSize == 179 && controls.sizeControl.valueLabel.stringValue == "179",
                    "Minus cannot gradually reduce an older large size")
        controls.sizeControl.slider.doubleValue = 24
        controls.sizeControl.slider.sendAction(controls.sizeControl.slider.action, to: controls.sizeControl.slider.target)
        try require(canvas.selectedAnnotation?.fontSize == 24 && controls.sizeControl.valueLabel.stringValue == "24",
                    "Slider did not explicitly apply a common size")

    }

    @MainActor private static func palette() throws {
        let (canvas, controls, _) = fixture()
        try require(controls.rows.count == 1, "Inactive tool displays settings")
        controls.choose(tool: .sticker)
        try require(controls.rows.count == 2 && (30...40).contains(controls.stickerButtons.count) && controls.sizeControl.category == "贴纸大小",
                    "Sticker palette is missing curated choices or flat sizes")
        try require(canvas.annotationFontSize == 36 && canvas.annotationSticker == StickerCatalog.defaultIdentifier, "Initial sticker is wrong")
        controls.stickerButtons.first { $0.identifier?.rawValue == StickerCatalog.canonicalIdentifier("🐥") }!.performClick(nil)
        for _ in 0..<8 { controls.refresh(); _ = controls.rows }
        try require(canvas.annotationSticker == StickerCatalog.canonicalIdentifier("🐥"), "Explicit sticker changed during redraw")
        controls.choose(tool: .sticker)
        try require(controls.rows.count == 1 && !canvas.isDrawingEnabled, "Second click did not exit sticker placement")
        controls.choose(tool: .text)
        let visible: [NSView] = controls.rows.flatMap { $0 }
        let hasSticker = visible.contains { view in controls.stickerButtons.contains { $0 === view } }
        try require(!hasSticker,
                    "Sticker choices leaked into text controls")
        controls.choose(tool: .sticker)
        try require(canvas.annotationSticker == StickerCatalog.canonicalIdentifier("🐥"), "Tool switch reset the explicit sticker")
    }

    @MainActor private static func selection() throws {
        let (canvas, controls, memory) = fixture()
        try require(controls.stickerButtons.count >= 10, "Sticker resources are not available")
        canvas.selectedAnnotation = ImageToolsAnnotation(tool: .sticker, fontSize: 64, text: "🦋")
        canvas.onAnnotationSelectionChange?(canvas.selectedAnnotation)
        try require(memory.writeCount == 0 && controls.activeTool == .sticker
                    && controls.stickerButtons.first { $0.identifier?.rawValue == StickerCatalog.canonicalIdentifier("🦋") }?.state == .on,
                    "Selecting a sticker rewrote preferences or failed to select its palette item")
        controls.stickerButtons.first { $0.identifier?.rawValue == StickerCatalog.canonicalIdentifier("☀️") }!.performClick(nil)
        try require(canvas.selectedAnnotation?.text == StickerCatalog.canonicalIdentifier("☀️") && canvas.annotationSticker == StickerCatalog.canonicalIdentifier("☀️"), "Palette did not edit selected sticker")
        controls.sizeControl.slider.doubleValue = 96
        controls.sizeControl.slider.sendAction(controls.sizeControl.slider.action, to: controls.sizeControl.slider.target)
        try require(canvas.selectedAnnotation?.fontSize == 96 && canvas.annotationFontSize == 96, "Size did not edit current/default sticker")
        canvas.deselectAnnotation()
        try require(canvas.annotationSticker == StickerCatalog.canonicalIdentifier("☀️"), "Deselecting lost the chosen sticker")
    }

    @MainActor private static func geometry() throws {
        let (_, controls, _) = fixture()
        controls.choose(tool: .sticker)
        let toolbar = SelectionToolbar()
        toolbar.rows = controls.rows(appendingActions: actions())
        arrange(toolbar, width: 1000)
        let views = toolbar.rows.flatMap { $0 }
        let originalSizes = views.map { $0.bounds.size }
        let originalHeight = toolbar.bounds.height
        for width: CGFloat in [720, 480, 320, 180] {
            arrange(toolbar, width: width)
            try require(toolbar.bounds.width <= width, "Toolbar exceeds available width")
            for (index, view) in views.enumerated() {
                if view.isHidden { continue }
                try require(toolbar.bounds.contains(view.frame), "Control escapes toolbar bounds: \(view.frame)")
                if let size = view as? AnnotationSizeControl {
                    try require(size.minus.frame.width == 28 && size.plus.frame.width == 28
                                && size.bounds.contains(size.slider.frame) && size.bounds.contains(size.plus.frame),
                                "Adaptive size control shrank buttons or clipped the slider")
                } else {
                    try require(view.bounds.size == originalSizes[index], "Wrapping shrinks a control instead of moving it: \(view)")
                }
                for other in views.dropFirst(index + 1) where !other.isHidden {
                    try require(!view.frame.intersects(other.frame), "Controls overlap after wrapping")
                }
                if view is NSButton {
                    for point in [CGPoint(x: view.frame.minX + 1, y: view.frame.minY + 1),
                                  CGPoint(x: view.frame.midX, y: view.frame.midY),
                                  CGPoint(x: view.frame.maxX - 1, y: view.frame.maxY - 1)] {
                        try require(toolbar.hitTest(point) === view, "Wrapping or decoration intercepts a button hit target")
                    }
                }
            }
        }
        try require(toolbar.bounds.height > originalHeight, "Narrow toolbar does not wrap into additional lines")
        try adaptiveStickerGeometry()
    }

    @MainActor private static func adaptiveStickerGeometry() throws {
        let oldLanguage = AppLocalization.language
        defer { AppLocalization.language = oldLanguage }
        for language in [AppLanguagePreference.simplifiedChinese, .english] {
            AppLocalization.language = language
            let (canvas, controls, memory) = fixture()
            controls.choose(tool: .sticker)
            controls.stickerButtons.last!.performClick(nil)
            let selected = canvas.annotationSticker, writes = memory.writeCount
            let toolbar = SelectionToolbar()
            var previousCount = 0
            for width: CGFloat in [480, 560, 640, 740, 900, 1120] {
                toolbar.rows = controls.rows(appendingActions: actions(), maxWidth: width)
                arrange(toolbar, width: width)
                let row = toolbar.rows[1].filter { !$0.isHidden }
                let inline = controls.stickerButtons.filter { button in row.contains { $0 === button } }
                try require(!inline.isEmpty && inline.count >= previousCount,
                            "Wider hosts did not make more sticker choices available")
                try require(row.allSatisfy { abs($0.frame.midY - controls.sizeControl.frame.midY) < 0.5 }
                            && row.contains { $0 === controls.moreStickerButton },
                            "Sticker choices wrapped More or size controls on a supported host width")
                let rightEdge = row.map(\.frame.maxX).max() ?? 0
                if inline.count < controls.stickerButtons.count {
                    try require(width - 8 - rightEdge < 32,
                                "The sticker row leaves enough unused space for another full choice")
                }
                try require(inline.map { $0.identifier!.rawValue } == Array(controls.orderedStickerIdentifiers.prefix(inline.count)),
                            "Adaptive capacity changed the saved sticker order")
                if width == 480 { try require(inline.count < 10, "Narrow host still forces ten stickers") }
                if width == 1120 { try require(inline.count > 10, "Wide host is still limited to ten stickers") }
                previousCount = inline.count
            }
            toolbar.rows = controls.rows(maxWidth: 180)
            arrange(toolbar, width: 180)
            try require(toolbar.rows[1].contains { $0 === controls.moreStickerButton }
                        && controls.sizeControl.frame.width >= 122,
                        "Extremely narrow fallback hides More or crushes the size control")
            try require(canvas.annotationSticker == selected && memory.writeCount == writes,
                        "Width changes altered selected sticker or saved preferences")
        }
    }

    @MainActor private static func rowSurfaces() throws {
        let (_, controls, _) = fixture()
        controls.choose(tool: .mosaic)
        let actionButtons = actions()
        let toolbar = SelectionToolbar()
        toolbar.rows = controls.rows(appendingActions: actionButtons)
        arrange(toolbar, width: 900)
        try require(toolbar.rows.count == 2, "Mosaic must have one main strip and one parameter row")
        let toolItems = AnnotationControls.displayOrder.compactMap { controls.toolButtons[$0] } + [controls.undoButton]
        try require(zip(toolbar.rows[0].prefix(toolItems.count), toolItems).allSatisfy { $0 === $1 },
                    "The main strip lost annotation tools or undo")
        try require(zip(toolbar.rows[0].suffix(actionButtons.count), actionButtons).allSatisfy { $0 === $1 }
                    && toolbar.rows[0].filter { $0 is ToolbarSeparator }.count == 1,
                    "Actions are not separated from tools within the main strip")
        try require(toolbar.rows[1].contains { $0 === controls.sizeControl },
                    "Mosaic parameters left their optional second row")
        let materialRows = surfaces(in: toolbar)
        try require(materialRows.count == 1 && materialRows[0].frame == toolbar.bounds,
                    "The toolbar still uses separate floating row surfaces")
        try require(toolbar.bounds.height <= 84, "Two compact rows occupy excessive height")
        try require(toolbar.rows.flatMap { $0 }.filter { !$0.isHidden }.allSatisfy { materialRows[0].frame.contains($0.frame) },
                    "A toolbar control escaped the shared panel")
        let divider = toolbar.rows[0].first { $0 is ToolbarSeparator }!
        try require(divider.hitTest(CGPoint(x: divider.bounds.midX, y: divider.bounds.midY)) == nil,
                    "A group divider intercepts mouse input")
    }

    @MainActor private static func parameterLifecycle() throws {
        let (_, controls, _) = fixture()
        let toolbar = SelectionToolbar()
        let actionButtons = actions()
        controls.choose(tool: .sticker)
        toolbar.rows = controls.rows(appendingActions: actionButtons)
        arrange(toolbar, width: 900)
        let stickerParameters = toolbar.rows.dropFirst().flatMap { $0 }
        let stickerHeight = toolbar.bounds.height
        try require(surfaces(in: toolbar).count == 1 && toolbar.rows.count == 2,
                    "Sticker settings must share a single optional parameter row")

        controls.choose(tool: .mosaic)
        toolbar.rows = controls.rows(appendingActions: actionButtons)
        arrange(toolbar, width: 900)
        try require(stickerParameters.filter { $0 !== controls.sizeControl }.allSatisfy { $0.superview == nil } && controls.sizeControl.category == "马赛克大小", "Old sticker controls remain after switching tools")
        try require(surfaces(in: toolbar).count == 1 && toolbar.rows.count == 2 && toolbar.bounds.height <= stickerHeight,
                    "Obsolete sticker surface or space remains after switching tools")
        let mosaicParameters = toolbar.rows.dropFirst().flatMap { $0 }

        controls.choose(tool: .mosaic)
        toolbar.rows = controls.rows(appendingActions: actionButtons)
        arrange(toolbar, width: 900)
        try require(mosaicParameters.allSatisfy { $0.superview == nil }, "Parameter controls remain after closing the active tool")
        try require(surfaces(in: toolbar).count == 1 && toolbar.rows.count == 1, "An empty parameter row remains visible")
        try require(zip(toolbar.rows[0].suffix(actionButtons.count), actionButtons).allSatisfy { $0 === $1 }
                    && actionButtons.allSatisfy { $0.superview === toolbar },
                    "Changing or closing tools removed the main strip's actions")
        let currentItems = toolbar.rows.flatMap { $0 }
        try require(toolbar.subviews.allSatisfy { view in
            view is ToolbarMaterialView || currentItems.contains { $0 === view }
        }, "An obsolete control remains installed in the toolbar")
    }

    @MainActor private static func compactMainGeometry() throws {
        let (_, controls, _) = fixture()
        let modes = ["框选", "主体", "窗口", "整屏"].map { SelectionButton($0) {} }
        let actions = [("复制", "doc.on.doc"), ("保存", "square.and.arrow.down"),
                       ("贴图", "pin"), ("文字", "text.viewfinder"), ("取消", "xmark")]
            .map { SelectionButton($0.0, symbol: $0.1) {} }
        for button in actions {
            button.imagePosition = .imageOnly
        }
        actions[0].toolTip = "复制当前选区和标注（⌘C / Enter）"
        actions[1].toolTip = "保存 PNG（⌘S）"
        actions[3].toolTip = "提取当前选区中的文字"
        actions[4].toolTip = "取消（Esc）"
        let toolbar = SelectionToolbar()
        let rows = controls.rows(appendingActions: actions)
        toolbar.rows = [modes + [ToolbarSeparator()] + rows[0]]
        arrange(toolbar, width: 1200)
        try require(toolbar.bounds.width <= 700, "The icon-action screenshot main strip is still excessively wide: \(toolbar.bounds.width)")
        print("INFO: icon-action screenshot main strip width=\(toolbar.bounds.width)pt")
        try require(toolbar.bounds.height <= 40, "The cancel button wraps into an otherwise empty extra line")
        modes[2].state = .on
        try writePreview(toolbar, name: "compact-screenshot-main.png")
        for width: CGFloat in [700, 640, 480, 296] {
            arrange(toolbar, width: width)
            if width == 700 {
                try require(toolbar.bounds.height <= 40, "The compact main strip wraps at its intended desktop width")
            }
            for control in toolbar.rows[0] where !control.isHidden {
                try require(toolbar.bounds.contains(control.frame), "A fixed main-strip control escapes after wrapping")
                try require(control.frame.height == 28, "Compact layout shrinks the main-strip hit targets")
                guard let button = control as? NSButton else { continue }
                if button.imagePosition == .imageOnly {
                    // Native symbol fitting can add a half point; compaction must never reduce the 32-point target.
                    try require(button.frame.width >= 32, "\(button.title): compact icon action shrank below its 32-point hit width")
                }
                try require(button.accessibilityLabel()?.isEmpty == false && button.toolTip?.isEmpty == false,
                            "\(button.title): compact action lost its accessible name or hover explanation")
                for point in [CGPoint(x: button.frame.minX + 1, y: button.frame.minY + 1),
                              CGPoint(x: button.frame.midX, y: button.frame.midY),
                              CGPoint(x: button.frame.maxX - 1, y: button.frame.maxY - 1)] {
                    try require(toolbar.hitTest(point) === button, "\(button.title): compact decoration intercepts its hit target")
                }
                guard let caption = button.subviews.compactMap({ $0 as? NSTextField }).first else {
                    throw ToolbarFailure(description: "\(button.title): compact action caption is missing")
                }
                try require(caption.isHidden == (button.imagePosition == .imageOnly),
                            "\(button.title): compact caption visibility does not match the action")
                if !caption.isHidden {
                    let required = caption.fittingSize
                    try require(caption.frame.width >= ceil(required.width) && caption.frame.height >= ceil(required.height)
                                && button.bounds.contains(caption.frame),
                                "\(button.title): reduced spacing clips a retained Chinese caption")
                }
            }
        }
        try require(modes.allSatisfy { $0.imagePosition == .noImage }, "The four selection modes lost their visible text labels")
    }

    @MainActor private static func hitTargets() throws {
        var fired = 0
        let button = SelectionButton("复制", symbol: "doc.on.doc") { fired += 1 }
        button.imagePosition = .imageOnly
        button.frame = CGRect(origin: .zero, size: button.intrinsicContentSize)
        button.layoutSubtreeIfNeeded()
        for point in [CGPoint(x: 1, y: 1), CGPoint(x: button.bounds.midX, y: button.bounds.midY),
                      CGPoint(x: button.bounds.maxX - 1, y: button.bounds.maxY - 1)] {
            try require(button.hitTest(point) === button, "Glyph or label intercepts the action hit target")
        }
        button.performClick(nil)
        try require(fired == 1, "Native button action did not fire once")
        button.isEnabled = false; button.performClick(nil)
        try require(fired == 1, "Disabled button still invokes action")
        try require(button.accessibilityLabel() == "复制", "Accessible action label was lost")
    }

    @MainActor private static func colorSwatchHover() throws {
        let event = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        for appearance in ["aqua", "darkAqua"] {
            for color in [NSColor.systemRed, .systemOrange, .systemGreen, .systemBlue] {
                for selected in [false, true] {
                    let button = SelectionOptionButton(sample: .color(color), label: "颜色") {}
                    button.appearance = NSAppearance(named: NSAppearance.Name(appearance))
                    button.frame = CGRect(origin: .zero, size: button.intrinsicContentSize)
                    button.state = selected ? .on : .off
                    let expected = color.usingColorSpace(.sRGB)!
                    func coloredPixels(_ bitmap: NSBitmapImageRep) -> Int {
                        var count = 0
                        for y in 0..<bitmap.pixelsHigh {
                            for x in 0..<bitmap.pixelsWide {
                                if distance(bitmap.colorAt(x: x, y: y)!, expected) < 0.12 { count += 1 }
                            }
                        }
                        return count
                    }
                    let idle = coloredPixels(try render(button))
                    try require(idle > 20, "Idle swatch has no visible color")
                    button.mouseEntered(with: event)
                    RunLoop.current.run(until: Date().addingTimeInterval(0.40))
                    let hovered = coloredPixels(try render(button))
                    try require(hovered >= idle * 4 / 5, "Hover erased the color swatch: idle=\(idle), hover=\(hovered), selected=\(selected), appearance=\(appearance)")
                    button.highlight(true)
                    let pressed = coloredPixels(try render(button))
                    try require(pressed >= idle * 4 / 5, "Press erased the color swatch")
                    button.highlight(false); button.mouseExited(with: event)
                }
            }
        }
    }

    @MainActor private static func motion() throws {
        let event = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        for button in [MotionButton("贴图", symbol: "pin") {}, QuietButton("贴图", symbol: "pin") {}] as [SelectionButton] {
            // Match ToolbarMaterialView: standalone fixtures otherwise inherit the system theme.
            button.appearance = NSAppearance(named: .aqua)
            button.frame = CGRect(origin: .zero, size: button.intrinsicContentSize)
            button.layoutSubtreeIfNeeded()
            let before = button.frame
            let glyph = button.subviews.compactMap { $0 as? NSImageView }.first!
            let glyphFrame = glyph.frame
            for _ in 0..<16 {
                button.mouseEntered(with: event)
                try require(button.isPointerInside, "Hover feedback was lost")
                try require(glyph.layer?.animationKeys()?.isEmpty ?? true, "Entering a button starts a distracting glyph animation")
                button.mouseExited(with: event)
                try require(!button.isPointerInside, "Hover persists after leaving")
                try require(button.frame == before && glyph.frame == glyphFrame, "Hover changes visible geometry or hit targets")
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.23))
            try require(abs(glyph.layer!.transform.m11 - 1) < 0.001, "Cancelled hover activates after leaving")
            let idle = try render(button)
            button.mouseEntered(with: event)
            try require(abs(glyph.layer!.transform.m11 - 1) < 0.001, "Hover scales before the dwell delay")
            RunLoop.current.run(until: Date().addingTimeInterval(0.23))
            let hovered = try render(button)
            try require(distance(sample(hovered), sample(idle)) > 0.018,
                        "Settled hover has no visible background feedback")
            let scale = glyph.layer!.transform.m11
            try require(abs(scale - 1) < 0.001 && (glyph.layer?.animationKeys()?.isEmpty ?? true),
                        "Settled hover resamples a small icon instead of preserving native pixels")
            try require(abs(glyph.layer!.transform.m12) < 0.001 && abs(glyph.layer!.transform.m21) < 0.001,
                        "Hover rotates the icon")
            button.mouseExited(with: event)
            try require(abs(glyph.layer!.transform.m11 - 1) < 0.001, "Exit leaves a hover scale behind")
            RunLoop.current.run(until: Date().addingTimeInterval(0.20))
            button.state = .on
            let resting = try render(button)
            button.highlight(true)
            let pressed = try render(button)
            try require(distance(sample(pressed), sample(resting)) > 0.018,
                        "An already-selected button has no pressed background feedback")
            try require(glyph.layer?.animationKeys()?.isEmpty ?? true, "Press animates the glyph geometry")
            try require(abs(glyph.layer!.transform.m11 - 1) < 0.001, "Press scales the glyph")
            button.highlight(false)
            try require(abs(glyph.layer!.transform.m11 - 1) < 0.001, "Release leaves the glyph compressed")
            try require(button.frame == before, "Press changes the action hit target")
        }
    }

    @MainActor private static func modeFeedback() throws {
        try primaryFeedback()
        let event = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        for title in ["框选", "主体", "窗口", "整屏"] {
            let button = MotionButton(title) {}
            // The pixel comparison composites on white, as the actual toolbar does.
            button.appearance = NSAppearance(named: .aqua)
            button.setButtonType(.pushOnPushOff)
            button.frame = CGRect(origin: .zero, size: button.intrinsicContentSize)
            button.layoutSubtreeIfNeeded()
            let idle = try render(button)
            button.mouseEntered(with: event)
            RunLoop.current.run(until: Date().addingTimeInterval(0.23))
            let hovered = try render(button)
            try require(button.isPointerInside && distance(sample(hovered), sample(idle)) > 0.018,
                        "\(title) has no visible unselected hover feedback")
            button.state = .on
            let selectedHovered = try render(button)
            try require(distance(sample(selectedHovered), sample(hovered)) > 0.018,
                        "\(title) kept the unselected hover appearance after selection")
            button.mouseExited(with: event)
            try require(button.state == .on && !button.isPointerInside, "\(title) lost selection when hover ended")
            RunLoop.current.run(until: Date().addingTimeInterval(0.20))
            let selected = try render(button)
            try require(distance(sample(selected), sample(selectedHovered)) > 0.006,
                        "\(title) retains its hovered fill after the pointer leaves")
            try require(luminance(sample(selected)) < luminance(sample(idle)) - 0.04,
                        "\(title) has no persistent selected background")
            button.isEnabled = false
            let disabled = try render(button)
            button.mouseEntered(with: event)
            RunLoop.current.run(until: Date().addingTimeInterval(0.23))
            let disabledHovered = try render(button)
            try require(button.state == .on && distance(sample(disabled), sample(disabledHovered)) < 0.006,
                        "\(title) changes selected state or shows hover feedback while disabled")
        }
    }

    @MainActor private static func primaryFeedback() throws {
        let event = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        let button = MotionButton("完成", symbol: "checkmark") {}
        button.appearance = NSAppearance(named: .aqua)
        button.isPrimaryAction = true
        button.imagePosition = .imageOnly
        button.frame = CGRect(origin: .zero, size: button.intrinsicContentSize)
        let idle = try render(button)
        try writePreview(button, name: "complete-idle.png")
        button.mouseEntered(with: event)
        RunLoop.current.run(until: Date().addingTimeInterval(0.23))
        let hover = try render(button)
        try writePreview(button, name: "complete-hover.png")
        button.highlight(true)
        let pressed = try render(button)
        try writePreview(button, name: "complete-pressed.png")
        try require(luminance(sample(hover)) < luminance(sample(idle)) - 0.006,
                    "Complete becomes lighter on hover instead of preserving emphasis")
        try require(luminance(sample(pressed)) < luminance(sample(hover)) - 0.006,
                    "Complete loses consistent pressed emphasis")
        button.highlight(false); button.mouseExited(with: event)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let restored = try render(button)
        try require(distance(sample(restored), sample(idle)) < 0.006 && button.state == .off,
                    "Complete retains hover or toggles into a selected state")
    }

    @MainActor private static func stickerLibrary() throws {
        let items = StickerCatalog.items
        try require((30...40).contains(items.count) && Set(items.map(\.id)).count == items.count,
                    "Sticker manifest is missing entries or contains duplicate identifiers")
        try require(items.allSatisfy { StickerCatalog.hasVector($0.id) }, "A bundled sticker PDF cannot be read")
        let (_, controls, _) = fixture()
        controls.choose(tool: .sticker)
        let visible = controls.rows(maxWidth: 720).flatMap { $0 }
        let inline = controls.stickerButtons.filter { button in visible.contains { $0 === button } }
        try require(!inline.isEmpty && inline.count < items.count && visible.contains { $0 === controls.moreStickerButton },
                    "Expanded library crowds the persistent toolbar or lacks More")
        var picked: String?
        let picker = StickerPickerController(items: items, selected: "🌼") { picked = $0 }
        let root = picker.view
        let buttons = root.subviews.compactMap { $0 as? NSButton }
        try require(buttons.count == items.count, "More picker does not show the whole library")
        try require(root.bounds.size == CGSize(width: 328, height: 222)
                    && Set(buttons.map { $0.frame.minX }).count == 8 && Set(buttons.map { $0.frame.minY }).count == 4,
                    "The 32-pattern picker must occupy eight complete columns and four rows")
        for (index, button) in buttons.enumerated() {
            try require(root.bounds.contains(button.frame), "Picker clips a sticker hit target")
            try require(button.frame.width >= 30 && button.frame.height >= 28, "Picker hit target is too small")
            try require(button.accessibilityLabel()?.isEmpty == false, "Sticker has no accessible name")
            try require(buttons.dropFirst(index + 1).allSatisfy { !$0.frame.intersects(button.frame) }, "Picker targets overlap")
        }
        let window = NSWindow(contentRect: root.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = root
        defer { window.close() }
        try writePreview(root, name: "sticker-library-preview.png")
        buttons.last!.performClick(nil)
        try require(picked == items.last?.id, "Picker returns a transient position instead of a stable identifier")
    }

    @MainActor private static func appearance() throws {
        let root = AppearancePreview(frame: CGRect(x: 0, y: 0, width: 440, height: 100))
        for (row, name) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
            let appearance = NSAppearance(named: name)!
            var x: CGFloat = 12
            for (title, symbol) in [("复制", "doc.on.doc"), ("保存", "square.and.arrow.down"), ("贴到桌面", "pin")] {
                let button = SelectionButton(title, symbol: symbol) {}
                button.appearance = appearance
                button.frame = CGRect(x: x, y: CGFloat(row) * 50 + 11, width: button.intrinsicContentSize.width, height: 28)
                root.addSubview(button); button.layoutSubtreeIfNeeded()
                guard let caption = button.subviews.compactMap({ $0 as? NSTextField }).first else {
                    throw ToolbarFailure(description: "Action caption is missing")
                }
                var brightness: CGFloat = 0
                appearance.performAsCurrentDrawingAppearance {
                    brightness = caption.textColor!.usingColorSpace(.deviceRGB)!.redComponent
                }
                try require(name == .aqua ? brightness < 0.35 : brightness > 0.65,
                            "Action caption has insufficient contrast in \(name.rawValue)")
                x += button.frame.width + 8
            }
        }
        guard let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { throw ToolbarFailure(description: "Cannot create appearance preview") }
        root.cacheDisplay(in: root.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw ToolbarFailure(description: "Cannot encode appearance preview") }
        try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).appendingPathComponent("button-appearance-preview.png"))
    }

    @MainActor private static func captionGeometry() throws {
        let titles = ["矩形", "主体", "整屏", "复制", "保存", "贴图", "文字", "取消", "确认",
                      "自由框选", "窗口框选", "贴到桌面", "暂停自动"]
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let toolbar = SelectionToolbar()
            let buttons = titles.map { SelectionButton($0, symbol: "square") {} }
            toolbar.rows = [buttons]
            for width: CGFloat in [620, 320, 180] {
                arrange(toolbar, width: width)
                for button in buttons {
                    button.appearance = NSAppearance(named: name)
                    button.needsLayout = true
                    button.layoutSubtreeIfNeeded()
                    guard let caption = button.subviews.compactMap({ $0 as? NSTextField }).first else {
                        throw ToolbarFailure(description: "Missing action caption")
                    }
                    let required = caption.fittingSize
                    try require(caption.frame.width >= ceil(required.width) && caption.frame.height >= ceil(required.height),
                        "\(button.title): label frame \(caption.frame.size) clips native text cell \(required)")
                    try require(button.bounds.contains(caption.frame), "\(button.title): text escapes its button")
                    if let glyph = button.subviews.compactMap({ $0 as? NSImageView }).first {
                        try require(glyph.frame.maxX <= caption.frame.minX, "Icon overlaps Chinese caption")
                    }
                }
            }
            // The full-screen action is relabeled while the toolbar is already visible.
            buttons[2].title = "自由框选"
            arrange(toolbar, width: 180)
            let caption = buttons[2].subviews.compactMap { $0 as? NSTextField }.first!
            try require(caption.frame.width >= ceil(caption.fittingSize.width) && buttons[2].bounds.contains(caption.frame),
                        "A relabeled full-screen action clips its longer caption")
        }
    }

    @MainActor private static func toolbarAppearance() throws {
        let ordinary = SelectionButton("窗口", symbol: "macwindow") {}
        let selected = SelectionButton("窗口", symbol: "macwindow") {}
        selected.setButtonType(.pushOnPushOff)
        selected.state = .on
        // Explicit caller tint must not make selected content lighter than ordinary ink.
        selected.contentTintColor = ToolbarPalette.accent
        let ordinaryFont = SelectionOptionButton(sample: .font(18), label: "普通字号") {}
        let selectedFont = SelectionOptionButton(sample: .font(18), label: "选中字号") {}
        let ordinaryLine = SelectionOptionButton(sample: .line(3), label: "普通线宽") {}
        let selectedLine = SelectionOptionButton(sample: .line(3), label: "选中线宽") {}
        selectedFont.state = .on
        selectedLine.state = .on
        let toolbar = SelectionToolbar()
        toolbar.rows = [[ordinary, selected, ToolbarSeparator()] + actions(),
                        [ordinaryFont, selectedFont, ordinaryLine, selectedLine]]
        let host = SolidBackdrop(frame: CGRect(x: 0, y: 0, width: 600, height: 130))
        host.color = NSColor(srgbRed: 0.10, green: 0.13, blue: 0.18, alpha: 1)
        host.appearance = NSAppearance(named: .aqua)
        host.addSubview(toolbar)
        arrange(toolbar, width: 560)
        toolbar.frame.origin = CGPoint(x: 20, y: 24)
        let window = NSWindow(contentRect: host.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        _ = try render(toolbar)
        guard let normalCaption = ordinary.subviews.compactMap({ $0 as? NSTextField }).first,
              let selectedCaption = selected.subviews.compactMap({ $0 as? NSTextField }).first,
              let normalGlyph = ordinary.subviews.compactMap({ $0 as? NSImageView }).first,
              let selectedGlyph = selected.subviews.compactMap({ $0 as? NSImageView }).first else {
            throw ToolbarFailure(description: "Action caption or glyph is missing")
        }
        let selectedBackground = luminance(sample(try render(selected)))
        for (normal, chosen, name) in [(normalCaption as NSView, selectedCaption as NSView, "caption"),
                                       (normalGlyph as NSView, selectedGlyph as NSView, "glyph"),
                                       (ordinaryFont as NSView, selectedFont as NSView, "font sample"),
                                       (ordinaryLine as NSView, selectedLine as NSView, "line sample")] {
            let normalInk = try contentLuminance(normal)
            let chosenInk = try contentLuminance(chosen)
            try require(chosenInk < normalInk - 0.006, "Selected \(name) is not darker than ordinary content")
            try require(1.05 / (normalInk + 0.05) >= 7 && (selectedBackground + 0.05) / (chosenInk + 0.05) >= 7,
                        "Rendered \(name) has insufficient contrast on its actual white/selected surface")
        }
        try require(toolbar.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua,
                    "Toolbar did not inherit the light host appearance")
        try writePreview(host, name: "toolbar-content-contrast.png")
    }

    @MainActor private static func reducedTransparency() throws {
        for reduced in [false, true] {
            for role: ToolbarMaterialView.Role in [.primary, .parameter] {
                for mode: NSVisualEffectView.BlendingMode in [.withinWindow, .behindWindow] {
                    let root = SolidBackdrop(frame: CGRect(x: 0, y: 0, width: 240, height: 90))
                    let material: ToolbarMaterialView = reduced
                        ? OpaqueToolbarMaterial(role: role, blendingMode: mode)
                        : StandardToolbarMaterial(role: role, blendingMode: mode)
                    material.frame = CGRect(x: 16, y: 16, width: 208, height: 58)
                    root.appearance = NSAppearance(named: .aqua)
                    root.addSubview(material)
                    let window = NSWindow(contentRect: root.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.contentView = root
                    defer { window.close() }
                    material.refreshMaterial()
                    try require(!descendants(material).contains { $0 is NSVisualEffectView },
                                "A toolbar panel still contains a backdrop blur view")
                    let surface = try render(material)
                    let center = sample(surface, v: 0.5)
                    for u: CGFloat in [0.2, 0.5, 0.8] {
                        for v: CGFloat in [0.25, 0.5, 0.75] {
                            let color = sample(surface, u: u, v: v)
                            try require(color.alphaComponent >= 0.995 && whiteComposite(color).min()! >= 0.99,
                                        "A toolbar interior is tinted or translucent")
                            try require(distance(center, color) < 0.006,
                                        "A toolbar interior contains a gradient instead of one flat white surface")
                        }
                    }
                    let backgrounds: [NSColor] = [.white, .black,
                        NSColor(srgbRed: 0.12, green: 0.32, blue: 0.88, alpha: 1),
                        NSColor(srgbRed: 0.90, green: 0.15, blue: 0.13, alpha: 1)]
                    var reference: NSBitmapImageRep?
                    for background in backgrounds {
                        root.color = background
                        root.needsDisplay = true
                        let bitmap = try render(root)
                        for u: CGFloat in [0.3, 0.5, 0.7] {
                            for v: CGFloat in [0.35, 0.5, 0.65] {
                                let color = sample(bitmap, u: u, v: v)
                                try require(color.alphaComponent >= 0.995 && whiteComposite(color).min()! >= 0.99,
                                            "Opaque toolbar picks up its dark or colored backdrop")
                                if let reference {
                                    try require(distance(color, sample(reference, u: u, v: v)) < 0.006,
                                                "Toolbar pixels change when only the backdrop changes")
                                }
                            }
                        }
                        if reference == nil { reference = bitmap }
                    }
                }
            }
        }
    }

    @MainActor private static func preview() throws {
        let (_, controls, _) = fixture()
        controls.choose(tool: .sticker)
        try require(controls.stickerButtons.count >= 10, "Sticker resources are not available for preview")
        controls.stickerButtons[5].performClick(nil)
        let toolbar = SelectionToolbar()
        toolbar.rows = controls.rows(appendingActions: actions(), maxWidth: 600)
        arrange(toolbar, width: 600)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: toolbar.frame.size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = toolbar
        defer { window.close() }
        try writePreview(toolbar, name: "toolbar-sticker-preview.png")

        let root = PorcelainPreview(frame: CGRect(x: 0, y: 0,
            width: PorcelainPreview.columnWidth * 3 + PorcelainPreview.gutter * 4, height: 920))
        let samples: [[(String, ImageToolsTool)]] = [
            [("画笔 · 颜色与粗细", .pen), ("文字 · 颜色与字号", .text), ("贴纸 · 图案与大小", .sticker)],
            [("序号 · 颜色与大小", .number), ("马赛克 · 块大小", .mosaic), ("贴纸 · 图案与大小", .sticker)],
            [("箭头 · 颜色与粗细", .arrow), ("文字 · 颜色与字号", .text), ("贴纸 · 图案与大小", .sticker)]
        ]
        let names = ["浅色背景", "深色背景", "彩色背景"]
        for column in 0..<3 {
            let x = PorcelainPreview.gutter + CGFloat(column) * (PorcelainPreview.columnWidth + PorcelainPreview.gutter) + 24
            let heading = NSTextField(labelWithString: names[column])
            heading.font = .systemFont(ofSize: 20, weight: .semibold)
            heading.textColor = column == 0 ? .black : .white
            heading.frame = CGRect(x: x, y: root.bounds.height - 64, width: 500, height: 28)
            root.addSubview(heading)
            var top = root.bounds.height - 106
            for (title, tool) in samples[column] {
                let label = NSTextField(labelWithString: title)
                label.font = .systemFont(ofSize: 13, weight: .medium)
                label.textColor = column == 0 ? NSColor(calibratedWhite: 0.28, alpha: 1) : NSColor.white.withAlphaComponent(0.88)
                label.frame = CGRect(x: x, y: top - 20, width: 500, height: 20)
                root.addSubview(label)
                let (_, sampleControls, _) = fixture()
                sampleControls.choose(tool: tool)
                if tool == .sticker { sampleControls.stickerButtons[5].performClick(nil) }
                let sampleToolbar = SelectionToolbar(blendingMode: .withinWindow)
                sampleToolbar.rows = sampleControls.rows(appendingActions: actions(), maxWidth: PorcelainPreview.columnWidth - 48)
                arrange(sampleToolbar, width: PorcelainPreview.columnWidth - 48)
                sampleToolbar.frame.origin = CGPoint(x: x, y: top - 30 - sampleToolbar.frame.height)
                root.addSubview(sampleToolbar)
                top = sampleToolbar.frame.minY - 32
            }
        }
        let previewWindow = NSWindow(contentRect: root.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        previewWindow.isReleasedWhenClosed = false
        previewWindow.contentView = root
        defer { previewWindow.close() }
        try writePreview(root, name: "toolbar-porcelain-preview.png")
    }
}
