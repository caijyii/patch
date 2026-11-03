import ImageIO
import Darwin

private struct InlineSubjectFailure: Error { let message: String }

extension SelectionView {
    fileprivate var probeSubjects: InlineSubjectSelection { subjects }
    fileprivate var probeCanvas: ImageToolsCanvas { canvas }
    fileprivate var probeSubjectCanvas: ImageToolsCanvas { subjectCanvas }
    fileprivate var probeMode: ScreenshotSelectionMode { screenshotMode }
    fileprivate var probeSelection: CGRect? { selection }
    fileprivate var probeToolbar: SelectionToolbar { toolbar }
    fileprivate var probeCommittedMode: ScreenshotSelectionMode? { committedMode }
    fileprivate var probePendingModeChange: Bool { pendingModeChange }
    fileprivate var probeSubjectSelectionTool: Bool { subjectSelectionTool }
    fileprivate func probeMode(_ mode: ScreenshotSelectionMode) { requestMode(mode) }
    fileprivate func probeExport(_ action: CaptureSelectionAction) { perform(action) }
    fileprivate func probeTool(_ tool: ImageToolsTool) { chooseTool(tool) }
}

extension InlineSubjectSelection {
    fileprivate var probeExtraction: SubjectExtractionResult? { extraction }
    fileprivate var probeHoverMask: CGImage? { hoverMask }
    fileprivate var probeSelectedOutline: CGImage? { selectedOutline }
    fileprivate var probeHistoryCount: Int { history.count }
}

extension RegionSelector {
    fileprivate func probeAttach(_ newViews: [SelectionView]) { views = newViews }
    fileprivate func probeShortcut(_ event: NSEvent, from view: SelectionView) -> Bool {
        routeShortcut(event, from: view)
    }
}

private final class InlineProbeWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

@main
private struct InlineSubjectProbe {
    @MainActor static func main() {
        do {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            guard CommandLine.arguments.count == 3,
                  let input = CGImageSourceCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(input, 0, nil) else {
                throw InlineSubjectFailure(message: "Expected a duck sample and output directory")
            }
            let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            // The source is tiny; keep the simulated screenshot viewport large enough for the real toolbar.
            let presentationScale = max(4, max(1000 / CGFloat(image.width), 800 / CGFloat(image.height)))
            let size = CGSize(width: CGFloat(image.width) * presentationScale, height: CGFloat(image.height) * presentationScale)
            try verifyFreshSubjectRange(image, size: size, directory: directory)
            let view = SelectionView(image: image, size: size, candidates: [], purpose: .screenshot,
                                     preferences: PreferencesStore(storage: MemoryPreferencesStorage()))
            let window = InlineProbeWindow(contentRect: CGRect(origin: .zero, size: size),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = view
            var actions: [(CaptureSelectionAction, CGImage)] = []
            view.onAction = { action, _, image in if let image { actions.append((action, image)) } }
            try require(view.probeMode == .window && !view.probeSubjects.isActive,
                        "Screenshot must start in automatic window mode without Vision analysis")
            let titles = view.probeToolbar.rows.flatMap { $0.compactMap { ($0 as? NSButton)?.title } }
            try require(Array(titles.prefix(4)) == ["框选", "主体", "窗口", "整屏"],
                        "The four peer modes must be available in a stable order before selecting a range")
            try drag(view, from: point(0.05, 0.95, in: view), to: point(0.95, 0.05, in: view))
            try require(view.probeSelection != nil, "Rectangle range selection stopped working")
            view.probeTool(.rectangle)
            let canvas = view.probeCanvas
            try drag(canvas, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 44, y: 42))
            try require(canvas.annotations.count == 1, "Rectangle mode annotation was not created")
            let rectangle = view.probeSelection
            view.probeMode(.subject)
            try require(view.probeMode == .subject && view.probeSubjects.isAnalyzing
                        && view.probePendingModeChange && view.probeCommittedMode == .rectangle
                        && view.probeSelection == rectangle && canvas.annotations.count == 1,
                        "Pending subject analysis must retain the prior rectangle and its annotation")
            view.probeExport(.copy)
            try require(actions.isEmpty, "Analyzing subject mode fell back to rectangular export")
            try wait { view.probeSubjects.isReady }
            try require(view.probeSubjects.selected.isEmpty && !view.probeSubjects.canExport,
                        "Automatic full-screen detection must start with no selected subjects")
            view.probeExport(.copy)
            try require(actions.isEmpty, "Empty subject selection fell back to rectangular export")
            let body = point(0.59, 0.65, in: view)
            view.mouseMoved(with: try event(.mouseMoved, at: body, in: view))
            try wait { view.probeSubjects.probeHoverMask != nil }
            try require(view.probeSubjects.hovered != nil, "Hover must preview the full detected instance")
            try click(view, at: body)
            try wait { view.probeSubjects.canExport }
            try require(view.probeSubjects.selected.count == 1, "Click must select the duck instance")
            try require(view.probeCommittedMode == .subject && !view.probePendingModeChange
                        && view.probeCanvas !== canvas && view.probeCanvas.annotations.isEmpty,
                        "A completed subject result must commit a separate transparent annotation canvas")
            for action in [CaptureSelectionAction.copy, .save, .pin] { view.probeExport(action) }
            try require(actions.count == 3 && actions.allSatisfy { ImageToolsUI.hasTransparentPixels($0.1) },
                        "Copy/save/pin must all use transparent subject images")
            try require(actions.allSatisfy { $0.1.width <= image.width && $0.1.height <= image.height },
                        "Export must trim transparent margins without enlarging the source")
            view.probeExport(.ocr)
            try require(actions.count == 3, "Visible disabled subject OCR bypassed the export action gate")
            try ImageToolsUI.png(actions[0].1).write(to: directory.appendingPathComponent("inline-duck-transparent.png"))
            try snapshot(view, to: directory.appendingPathComponent("inline-subject-preview.png"))
            print("PASS: four peer modes, pending rectangle preservation, subject commit, hover and transparent actions")
            try verifySubjectAnnotations(view, window: window, body: body, exports: { actions },
                                         output: directory.appendingPathComponent("inline-subject-annotated.png"))

            let historyOutput = actions.count
            try click(view, at: point(0.85, 0.15, in: view))
            try require(view.probeSubjects.selected.count == 1, "Background click changed the selected subject")
            try click(view, at: body)
            try require(view.probeSubjects.selected.isEmpty && !view.probeSubjects.canExport,
                        "Clicking the same instance must remove it immediately")
            view.probeExport(.copy)
            try require(actions.count == historyOutput, "Empty selection produced an image")
            let selectionUndo = try button("撤销", in: view)
            try require(selectionUndo.isEnabled, "Shared undo stays disabled after removing a subject")
            selectionUndo.performClick(nil)
            try wait { view.probeSubjects.canExport }
            try click(view, at: body)
            try require(view.probeSubjects.selected.isEmpty, "Cannot prepare contextual subject undo")
            _ = view.handleShortcut(try key("z", code: 6, flags: .command, window: window))
            try wait { view.probeSubjects.canExport }
            try require(view.probeSubjects.selected.count == 1 && view.probeCanvas.annotations.isEmpty,
                        "Selection-tool Command-Z did not undo membership independently of annotation history")
            for _ in 0..<4 { try click(view, at: body) }
            try wait { view.probeSubjects.canExport }
            try require(view.probeSubjects.selected.count == 1, "Rapid click render completed with stale selection")
            window.orderOut(nil)
            pump(0.05)
            try require(view.probeSubjects.canExport && view.probeSubjects.selected.count == 1,
                        "Hiding overlays while saving must retain the subject session")
            let committedSubject = view.probeCanvas
            view.probeMode(.rectangle)
            try require(view.probePendingModeChange && view.probeCommittedMode == .subject
                        && view.probeCanvas === committedSubject,
                        "Requesting a new rectangle lost the committed subject result")
            view.probeExport(.copy)
            try require(actions.count == historyOutput, "Pending rectangle mode exported the old subject result")
            view.probeMode(.subject)
            try require(!view.probePendingModeChange && view.probeCanvas === committedSubject
                        && view.probeSubjects.canExport && view.probeSubjects.selected.count == 1,
                        "Returning to the committed subject mode did not restore its ready result")
            view.probeExport(.copy)
            try require(actions.count == historyOutput + 1, "Restored subject export stopped working after changing modes")
            print("PASS: background no-op, membership undo, empty gate, rapid clicks, hidden state and pending-result restoration")

            try wait { view.probeSubjects.isReady }
            try drag(view, from: CGPoint(x: 0, y: 0), to: CGPoint(x: size.width, y: size.height))
            try wait { view.probeSubjects.canExport }
            try require(view.probeSubjects.selected.count == 1 && view.probeSubjects.analysisRect == view.bounds,
                        "Drag range must analyze the frozen crop and select detected subjects")
            try require(view.probeSubjects.output?.width == actions[0].1.width,
                        "Point-to-pixel ROI conversion changed the same subject's export size")
            print("PASS: drag ROI, automatic ROI selection and image/point scale conversion")

            let other = SelectionView(image: image, size: size, candidates: [], purpose: .screenshot,
                                      preferences: PreferencesStore(storage: MemoryPreferencesStorage()))
            let otherWindow = InlineProbeWindow(contentRect: CGRect(x: 700, y: 0, width: size.width, height: size.height),
                styleMask: .borderless, backing: .buffered, defer: false)
            otherWindow.contentView = other
            other.setScreenshotMode(.subject, startAnalysis: false)
            let selector = RegionSelector()
            selector.probeAttach([view, other])
            let beforeShortcut = actions.count
            _ = selector.probeShortcut(try key("c", code: 8, flags: .command, window: otherWindow), from: other)
            try require(actions.count == beforeShortcut + 1, "Shortcut on another screen did not target the selected subject owner")
            view.deactivate()
            try require(!view.hasSelection && !view.probeSubjects.canExport && !view.probeSubjects.isActive,
                        "Another screen's activation must invalidate the old subject session")
            view.setScreenshotMode(.subject, startAnalysis: true)
            selector.cancel()
            pump(0.9)
            try require(!view.probeSubjects.isActive && view.probeSubjects.probeExtraction == nil && view.probeSubjects.output == nil,
                        "Cancelled background analysis revived an old screenshot session")
            print("PASS: cross-screen shortcut owner, deactivate and stale completion cancellation")

            for purpose in [CaptureSelectionPurpose.text, .scroll, .record] {
                let plain = SelectionView(image: image, size: size, candidates: [], purpose: purpose)
                plain.setScreenshotMode(.subject, startAnalysis: true)
                try require(plain.probeMode == .rectangle && !plain.probeSubjects.isActive,
                            "Subject screenshot mode changed another capture purpose")
            }
            print("PASS: text, long screenshot and recording entry purposes remain unchanged")
            try verifyMultipleSubjects(image)
            window.close(); otherWindow.close()
            print("COMPLETE: inline subject verification")
        } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }

    @MainActor private static func button(_ title: String, in view: SelectionView) throws -> NSButton {
        let matches = view.probeToolbar.rows.flatMap({ $0 }).compactMap({ $0 as? NSButton }).filter { $0.title == title }
        guard let button = matches.first(where: { $0.imagePosition == .imageOnly }) ?? matches.first else {
            throw InlineSubjectFailure(message: "Missing subject toolbar button: \(title)")
        }
        return button
    }

    @MainActor private static func verifyFreshSubjectRange(_ image: CGImage, size: CGSize, directory: URL) throws {
        let view = SelectionView(image: image, size: size, candidates: [], purpose: .screenshot,
                                 initialMode: .subject, preferences: PreferencesStore(storage: MemoryPreferencesStorage()))
        let window = InlineProbeWindow(contentRect: CGRect(origin: .zero, size: size),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        defer { view.deactivate(); window.close() }
        try require(view.probeMode == .subject && !view.probeSubjects.isActive,
                    "Direct subject entry must show subject mode before starting analysis")
        view.setScreenshotMode(.subject, startAnalysis: true)
        let toolbarTitles = view.probeToolbar.rows.flatMap { $0.compactMap { ($0 as? NSButton)?.title } }
        try require(!toolbarTitles.contains(where: { ["清空", "选择", "选中", "撤销选择"].contains($0) })
                    && toolbarTitles.filter { $0 == "撤销" }.count == 1,
                    "Subject toolbar retains redundant selection controls or duplicate undo buttons")
        try verifyMergedMainBar(view)
        for tool in ImageToolsTool.allCases {
            let control = try button(tool.rawValue, in: view)
            try require(!control.isEnabled, "Subject annotation became available before a ready selection")
        }
        try snapshot(view, to: directory.appendingPathComponent("fresh-subject-analyzing.png"))
        try drag(view, from: .zero, to: CGPoint(x: size.width, y: size.height))
        try wait { view.probeSubjects.canExport }
        try require(view.probeCommittedMode == .subject && !view.probePendingModeChange,
                    "First drag result did not immediately commit the subject canvas")
        for tool in ImageToolsTool.allCases {
            let control = try button(tool.rawValue, in: view)
            try require(control.isEnabled,
                        "First drag result did not enable annotation tools without another click")
        }
        try require(view.probeToolbar.rows.flatMap { $0.compactMap { ($0 as? NSButton)?.title } } == toolbarTitles,
                    "Subject toolbar changed its action set after a drag selected a subject")
        guard let outline = view.probeSubjects.probeSelectedOutline else {
            throw InlineSubjectFailure(message: "Selected subject has no visible outline")
        }
        let outlineBitmap = NSBitmapImageRep(cgImage: outline)
        let bodyAlpha = outlineBitmap.colorAt(x: Int(CGFloat(outline.width) * 0.59),
                                             y: Int(CGFloat(outline.height) * 0.65))?.alphaComponent ?? 1
        try require(bodyAlpha < 0.1, "Selection outline obscures the subject interior")
        var hasVisibleEdge = false
        for y in 0..<outline.height where !hasVisibleEdge {
            for x in 0..<outline.width where (outlineBitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 {
                hasVisibleEdge = true; break
            }
        }
        try require(hasVisibleEdge, "Selected outline has no visible edge at this source resolution")
        try snapshot(view, to: directory.appendingPathComponent("fresh-subject-range.png"))
        view.probeSubjects.resetSelection()
        try require(view.probeSubjects.selected.isEmpty && !view.probeSubjects.canExport
                    && view.probeSubjectCanvas.isHidden,
                    "Clearing membership left the previous subject visibly selected on the annotation canvas")
        try require(view.probeToolbar.rows.flatMap { $0.compactMap { ($0 as? NSButton)?.title } } == toolbarTitles,
                    "Removing all subjects changed the stable subject toolbar")
        try snapshot(view, to: directory.appendingPathComponent("fresh-subject-empty.png"))
        print("PASS: direct subject mode, fixed toolbar without clear, first drag enables annotations, empty membership hides stale pixels")
        let historyCount = view.probeSubjects.probeHistoryCount
        try require(historyCount > 0, "Busy undo fixture must contain a previous selection")
        view.probeSubjects.begin(in: view.bounds, selectingAll: true)
        try require(view.probeSubjects.isAnalyzing && !view.probeSubjects.canUndo,
                    "Subject undo must be unavailable during analysis")
        _ = view.handleShortcut(try key("z", code: 6, flags: .command, window: window))
        try require(view.probeSubjects.probeHistoryCount == historyCount
                    && view.probeSubjects.selected.isEmpty,
                    "Disabled subject undo consumed history or changed membership through Command-Z")
        try wait { view.probeSubjects.canExport }
        print("PASS: Command-Z preserves subject selection history while analysis disables undo")
    }

    @MainActor private static func verifyMergedMainBar(_ view: SelectionView) throws {
        guard let main = view.probeToolbar.rows.first else {
            throw InlineSubjectFailure(message: "Subject main toolbar is missing")
        }
        let separators = main.indices.filter { main[$0] is ToolbarSeparator }
        try require(separators.count == 2, "Subject main bar does not separate mode, tool and action groups")
        let modes = Array(main[..<separators[0]]).compactMap { $0 as? NSButton }
        let tools = Array(main[(separators[0] + 1)..<separators[1]]).compactMap { $0 as? NSButton }
        let actions = Array(main[(separators[1] + 1)...]).compactMap { $0 as? NSButton }
        try require(modes.map(\.title) == ["框选", "主体", "窗口", "整屏"]
                    && modes.filter { $0.state == .on }.map(\.title) == ["主体"],
                    "Subject mode lost its ordered group or unique selected state")
        try require(tools.map(\.title) == ImageToolsTool.allCases.map(\.rawValue) + ["撤销"]
                    && tools.allSatisfy { $0.imagePosition == .imageOnly }, "Subject main bar lost its annotation group")
        try require(actions.map(\.title) == ["复制", "保存", "贴图", "文字", "取消"],
                    "Subject main bar lost a fixed completion action")
        try require(actions.allSatisfy {
            $0.imagePosition == (["复制", "保存", "取消"].contains($0.title) ? .imageOnly : .imageLeading)
        }, "Subject completion actions lost their compact icon and text presentation")
        guard let ocr = actions.first(where: { $0.title == "文字" }) else {
            throw InlineSubjectFailure(message: "Subject OCR action is hidden")
        }
        try require(!ocr.isEnabled && ocr.toolTip?.contains("主体模式") == true,
                    "Subject OCR must remain visible, disabled and explained")
        let ready = view.probeSubjects.canExport && !view.probePendingModeChange
        try require(actions.filter { $0.title != "文字" && $0.title != "取消" }.allSatisfy { $0.isEnabled == ready }
                    && actions.last?.isEnabled == true, "Subject completion actions do not follow readiness or disable cancel")
        try require(view.probeToolbar.rows.dropFirst().flatMap { $0 }.allSatisfy { item in
            !main.contains { $0 === item }
        }, "Subject main-bar controls leaked into a parameter row")
    }

    @MainActor private static func verifySubjectAnnotations(_ view: SelectionView, window: NSWindow, body: CGPoint,
        exports: () -> [(CaptureSelectionAction, CGImage)], output: URL) throws {
        let canvas = view.probeCanvas
        let membership = view.probeSubjects.selected
        try require(ImageToolsUI.hasTransparentPixels(canvas.source), "Subject annotation canvas has an opaque screenshot background")
        let modeTitles = Array((view.probeToolbar.rows.first?.compactMap { ($0 as? NSButton)?.title } ?? []).prefix(4))
        try require(modeTitles == ["框选", "主体", "窗口", "整屏"], "Subject result lost the fixed four-mode group")
        for tool in ImageToolsTool.allCases {
            let control = try button(tool.rawValue, in: view)
            try require(control.isEnabled, "Subject annotation tool is disabled: \(tool.rawValue)")
            view.probeTool(tool)
            try verifyMergedMainBar(view)
            try require(!view.probeSubjectSelectionTool && control.state == .on,
                        "Choosing an annotation did not leave subject selection mode")
            try require(!view.probeToolbar.frame.contains(body), "Subject fixture body is covered by the expanded toolbar")
            let hit = view.hitTest(view.convert(body, to: view.superview))
            try require(hit === canvas, "Active subject annotation does not route an unobscured image point to its canvas")
            let start = CGPoint(x: canvas.bounds.width * 0.12, y: canvas.bounds.height * 0.16)
            let end = CGPoint(x: canvas.bounds.width * 0.34, y: canvas.bounds.height * 0.38)
            if tool == .text {
                try click(canvas, at: start)
                guard let input = canvas.subviews.compactMap({ $0 as? NSTextField }).first else {
                    throw InlineSubjectFailure(message: "Subject text tool did not create an inline field")
                }
                input.stringValue = "主体标注"
                input.currentEditor()?.string = input.stringValue
                canvas.finishTextEditing()
            } else if tool == .number || tool == .sticker {
                try click(canvas, at: start)
            } else {
                try drag(canvas, from: start, to: end)
            }
            try require(canvas.annotations.count == 1 && canvas.annotations[0].tool == tool,
                        "Subject tool failed to create a real annotation: \(tool.rawValue)")
            try require(view.probeSubjects.selected == membership, "Drawing an annotation changed subject membership")
            let count = exports().count
            view.probeExport(.copy)
            try require(exports().count == count + 1 && ImageToolsUI.hasTransparentPixels(exports().last!.1),
                        "Annotated subject did not export with transparency: \(tool.rawValue)")
            window.makeFirstResponder(view)
            _ = view.handleShortcut(try key("z", code: 6, flags: .command, window: window))
            try require(canvas.annotations.isEmpty && view.probeSubjects.selected == membership,
                        "Annotation undo did not restore its canvas independently of subject selection")
        }

        view.probeTool(.rectangle)
        let beforeBlankDoubleClick = exports().count
        try routedDoubleClick(view, at: body)
        try require(exports().count == beforeBlankDoubleClick + 1 && canvas.annotations.isEmpty
                    && view.probeSubjects.selected == membership && ImageToolsUI.hasTransparentPixels(exports().last!.1),
                    "Blank subject-canvas double click failed to copy the transparent result without adding ink")
        try button("主体", in: view).performClick(nil)
        let empty = point(0.85, 0.15, in: view)
        try require(!view.probeSubjects.containsSubject(at: empty), "Subject double-click guard fixture is not empty")
        try routedDoubleClick(view, at: empty)
        try require(exports().count == beforeBlankDoubleClick + 1 && view.probeSubjects.selected == membership,
                    "Subject selection-tool double click unexpectedly exported or changed membership")

        // A real stroke outside the subject's alpha bounds must extend the exported crop.
        let baseBounds = try opaqueBounds(canvas.source)
        let margin: CGFloat = 3
        let start: CGPoint, end: CGPoint
        if baseBounds.minY >= 8 {
            start = CGPoint(x: 3, y: 3); end = CGPoint(x: max(12, canvas.bounds.width * 0.3), y: 3)
        } else if canvas.bounds.height - baseBounds.maxY >= 8 {
            start = CGPoint(x: 3, y: canvas.bounds.height - 4); end = CGPoint(x: max(12, canvas.bounds.width * 0.3), y: start.y)
        } else if baseBounds.minX >= 8 {
            start = CGPoint(x: 3, y: 3); end = CGPoint(x: 3, y: max(12, canvas.bounds.height * 0.3))
        } else if canvas.bounds.width - baseBounds.maxX >= 8 {
            start = CGPoint(x: canvas.bounds.width - 4, y: 3); end = CGPoint(x: start.x, y: max(12, canvas.bounds.height * 0.3))
        } else {
            throw InlineSubjectFailure(message: "Duck fixture needs at least eight transparent pixels beyond one subject edge")
        }
        view.probeTool(.pen)
        canvas.annotationColor = .systemRed; canvas.annotationWidth = margin
        try drag(canvas, from: start, to: end)
        let markedFull = try canvas.renderedImage()
        let markedBounds = try opaqueBounds(markedFull)
        try require(!baseBounds.contains(markedBounds), "Peripheral annotation did not extend beyond the original subject alpha bounds")
        let expected = SubjectImageUtilities.trimTransparentMargins(markedFull)
        let expectedPNG = try ImageToolsUI.png(expected)
        let first = exports().count
        for action in [CaptureSelectionAction.copy, .save, .pin] { view.probeExport(action) }
        let results = Array(exports().dropFirst(first))
        try require(results.count == 3, "Annotated subject lost a copy/save/pin action")
        for (_, result) in results {
            let actualPNG = try ImageToolsUI.png(result)
            try require(actualPNG == expectedPNG && ImageToolsUI.hasTransparentPixels(result),
                        "Subject export clipped the peripheral annotation, lost transparency or included overlay chrome")
        }
        try expectedPNG.write(to: output)
        view.probeTool(.pen)
        try require(view.probeSubjectSelectionTool && canvas.annotations.count == 1,
                    "Returning to subject selection discarded annotations")
        try require(view.hitTest(view.convert(body, to: view.superview)) === view,
                    "Subject selection tool still routes body clicks to the annotation canvas")
        view.probeMode(.rectangle)
        try require(view.probePendingModeChange && view.probeCanvas === canvas && canvas.annotations.count == 1,
                    "Leaving an annotated subject discarded its pending result")
        let pendingCount = exports().count
        view.probeExport(.copy)
        try require(exports().count == pendingCount, "Pending rectangle mode exported the old annotated subject")
        view.probeMode(.subject)
        try require(!view.probePendingModeChange && canvas.annotations.count == 1 && view.probeSubjects.canExport,
                    "Returning to an annotated subject did not restore the previous result")
        try click(view, at: body)
        try require(view.probeSubjects.selected.isEmpty && canvas.annotations.count == 1 && !view.probeSubjects.canExport,
                    "Removing a subject discarded its separate annotation history or allowed empty export")
        view.probeExport(.copy)
        try require(exports().count == pendingCount, "Peripheral annotations bypassed the empty-subject export gate")
        let membershipUndo = try button("撤销", in: view)
        try require(membershipUndo.isEnabled, "Shared undo is disabled while subject history exists")
        membershipUndo.performClick(nil)
        try wait { view.probeSubjects.canExport }
        try require(view.probeCanvas === canvas && canvas.annotations.count == 1 && view.probeSubjects.selected == membership,
                    "Restoring subject membership lost the existing annotation canvas")
        view.probeExport(.copy)
        guard let restoredImage = exports().last?.1 else { throw InlineSubjectFailure(message: "Missing restored annotated subject") }
        let restoredPNG = try ImageToolsUI.png(restoredImage)
        try require(restoredPNG == expectedPNG, "Subject membership undo changed the saved annotation pixels")
        view.probeTool(.pen)
        try button("撤销", in: view).performClick(nil)
        try require(canvas.annotations.isEmpty && view.probeSubjects.selected == membership,
                    "Toolbar annotation undo changed the subject selection")
        view.probeTool(.pen)
        try require(view.probeSubjectSelectionTool, "Toggling the active tool off did not restore subject picking")
        print("PASS: all eight subject annotation tools, hit routing, independent undo and transparent peripheral export")
    }

    private static func opaqueBounds(_ image: CGImage) throws -> CGRect {
        let bitmap = NSBitmapImageRep(cgImage: image)
        var minX = image.width, minY = image.height, maxX = -1, maxY = -1
        for y in 0..<image.height {
            for x in 0..<image.width {
                if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.001 {
                    minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
                }
            }
        }
        try require(maxX >= minX && maxY >= minY, "Image has no visible alpha extent")
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    @MainActor private static func verifyMultipleSubjects(_ source: CGImage) throws {
        let width = source.width * 3 + 40, height = source.height + 40
        guard let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw InlineSubjectFailure(message: "Cannot create two-subject fixture")
        }
        canvas.setFillColor(CGColor(red: 0.15, green: 0.09, blue: 0.29, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: width, height: height))
        canvas.draw(source, in: CGRect(x: 20, y: 20, width: source.width, height: source.height))
        canvas.draw(source, in: CGRect(x: source.width * 2 + 20, y: 20, width: source.width, height: source.height))
        guard let fixture = canvas.makeImage() else { throw InlineSubjectFailure(message: "Cannot draw fixture") }
        let size = CGSize(width: width * 3, height: height * 3)
        let view = SelectionView(image: fixture, size: size, candidates: [], purpose: .screenshot)
        let window = InlineProbeWindow(contentRect: CGRect(origin: .zero, size: size),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        defer { view.deactivate(); window.close() }
        view.probeMode(.subject)
        try wait { view.probeSubjects.isReady }
        let leftNormalized = CGPoint(x: (20 + CGFloat(source.width) * 0.59) / CGFloat(width),
                                     y: (20 + CGFloat(source.height) * 0.65) / CGFloat(height))
        let rightNormalized = CGPoint(x: (CGFloat(source.width) * 2 + 20 + CGFloat(source.width) * 0.59) / CGFloat(width),
                                      y: leftNormalized.y)
        guard let extraction = view.probeSubjects.probeExtraction,
              let leftID = extraction.instance(atNormalizedTopLeft: leftNormalized),
              let rightID = extraction.instance(atNormalizedTopLeft: rightNormalized), leftID != rightID else {
            print("NOTE: Vision did not separate both duck seed points; independent-subject UI assertions skipped")
            return
        }
        let left = point(leftNormalized.x, leftNormalized.y, in: view)
        let right = point(rightNormalized.x, rightNormalized.y, in: view)
        try click(view, at: left)
        try wait { view.probeSubjects.canExport }
        let singleWidth = view.probeSubjects.output!.width
        try click(view, at: right)
        try wait { view.probeSubjects.canExport }
        try require(view.probeSubjects.selected.count == 2 && view.probeSubjects.output!.width > singleWidth,
                    "Adding the second detected instance did not combine both subjects")
        try click(view, at: right)
        try wait { view.probeSubjects.canExport }
        try require(view.probeSubjects.selected == IndexSet(integer: leftID) && view.probeSubjects.output!.width == singleWidth,
                    "Removing the second instance changed the first selected subject")
        print("PASS: independently add and remove whole subjects in the same overlay")
    }

    private static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw InlineSubjectFailure(message: message) }
    }
    @MainActor private static func wait(_ ready: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(12)
        while !ready(), Date() < deadline { pump(0.02) }
        try require(ready(), "Timed out waiting for inline subject state")
    }
    @MainActor private static func pump(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
    private static func point(_ x: CGFloat, _ y: CGFloat, in view: NSView) -> CGPoint {
        CGPoint(x: view.bounds.minX + view.bounds.width * x, y: view.bounds.maxY - view.bounds.height * y)
    }
    @MainActor private static func event(_ type: NSEvent.EventType, at point: CGPoint, in view: NSView,
                                        clickCount: Int = 1) throws -> NSEvent {
        guard let window = view.window,
              let event = NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
                  timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1) else {
            throw InlineSubjectFailure(message: "Cannot create a local view event")
        }
        return event
    }
    @MainActor private static func click(_ view: NSView, at point: CGPoint) throws {
        view.mouseDown(with: try event(.leftMouseDown, at: point, in: view))
        view.mouseUp(with: try event(.leftMouseUp, at: point, in: view))
    }
    @MainActor private static func routedDoubleClick(_ view: SelectionView, at point: CGPoint) throws {
        for count in 1...2 {
            guard let receiver = view.hitTest(view.convert(point, to: view.superview)) else {
                throw InlineSubjectFailure(message: "No native receiver for subject double click")
            }
            receiver.mouseDown(with: try event(.leftMouseDown, at: point, in: view, clickCount: count))
            receiver.mouseUp(with: try event(.leftMouseUp, at: point, in: view, clickCount: count))
        }
    }
    @MainActor private static func drag(_ view: NSView, from start: CGPoint, to end: CGPoint) throws {
        view.mouseDown(with: try event(.leftMouseDown, at: start, in: view))
        view.mouseDragged(with: try event(.leftMouseDragged, at: end, in: view))
        view.mouseUp(with: try event(.leftMouseUp, at: end, in: view))
    }
    @MainActor private static func key(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags, window: NSWindow) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else {
            throw InlineSubjectFailure(message: "Cannot create a local shortcut event")
        }
        return event
    }
    @MainActor private static func snapshot(_ view: NSView, to url: URL) throws {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw InlineSubjectFailure(message: "Cannot draw inline preview")
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw InlineSubjectFailure(message: "Cannot encode inline preview")
        }
        try data.write(to: url)
    }
}
