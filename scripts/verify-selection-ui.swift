
// Concatenated after RegionSelector.swift to exercise its actual private views.
import Darwin

private struct SelectionUISkip: Error, CustomStringConvertible {
    let description: String
}

private struct SelectionUIFailure: Error, CustomStringConvertible {
    let description: String
}

extension SelectionView {
    fileprivate var verificationSelection: CGRect? { selection }
    fileprivate func verificationFullScreen() { selectScreen() }
    fileprivate var verificationCanvas: ImageToolsCanvas { canvas }
    fileprivate var verificationAnnotationControls: AnnotationControls { controls }
    fileprivate var verificationToolbar: SelectionToolbar { toolbar }
    fileprivate var verificationMode: ScreenshotSelectionMode { screenshotMode }
    fileprivate var verificationCommittedMode: ScreenshotSelectionMode? { committedMode }
    fileprivate var verificationPendingModeChange: Bool { pendingModeChange }
    fileprivate var verificationHover: CGRect? { hover }
    fileprivate var verificationVisibleSelection: CGRect? { chrome.selection }
    fileprivate var verificationEmptyHint: String? { chrome.emptyHint }
    fileprivate func verificationSelect(_ rect: CGRect) {
        screenshotMode = .rectangle
        selectionMode = .free
        committedMode = .rectangle
        pendingModeChange = false
        selection = rect
        hover = nil
        activeTool = nil
        updateSelection()
    }
}

extension RegionSelector {
    fileprivate func verificationSetCancellation(_ handler: @escaping () -> Void) { cancellation = handler }
    fileprivate func verificationUserCancel() { cancelAndRestoreTarget() }
    fileprivate var verificationWindows: [NSWindow] { windows }
    fileprivate func verificationShowFrozenScreens(_ image: CGImage) {
        show(NSScreen.screens.map { ($0, image) }, candidates: [], primaryTop: NSScreen.screens.first?.frame.maxY ?? 0,
             purpose: .screenshot, initialMode: .rectangle)
    }
    fileprivate func verificationAttachProductionAction(_ view: SelectionView,
        completion: @escaping (CaptureSelectionAction, CaptureRegion, CGImage?) -> Void = { _, _, _ in }) {
        views = [view]
        callback = completion
        configureAction(for: view, displayID: 17, screenFrame: CGRect(x: 1200, y: -200, width: 800, height: 600),
                        scale: 2, candidates: [], primaryTop: 1000)
    }

    fileprivate func verificationAttachViews(_ connected: [SelectionView]) {
        views = connected
        for view in connected {
            view.onActivate = { [weak self, weak view] in
                guard let self, let view else { return }
                self.views.filter { $0 !== view }.forEach { $0.deactivate() }
            }
            view.onShortcut = { [weak self, weak view] event in
                guard let self, let view else { return false }
                return self.routeShortcut(event, from: view)
            }
            view.onHasSelection = { [weak self] in self?.views.contains(where: { $0.hasSelection }) ?? false }
            view.onBackgroundDoubleClick = { [weak self] in
                guard let selected = self?.views.first(where: { $0.hasSelection }) else { return false }
                return selected.confirmSelection()
            }
            (view.window as? SelectionWindow)?.onKeyEquivalent = view.onShortcut
        }
    }
}

@MainActor
private final class SelectionUIFixture {
    let window: SelectionWindow
    let root: SelectionView
    let source: CGImage
    var actions: [(CaptureSelectionAction, CGRect, CGImage?)] = []
    var cancelCount = 0
    var errors: [Error] = []

    init(source: CGImage, size: CGSize = CGSize(width: 800, height: 600),
         candidates: [CGRect] = [], purpose: CaptureSelectionPurpose = .screenshot,
         preferences: PreferencesStore? = nil, toolbarArea: CGRect? = nil) {
        self.source = source
        root = SelectionView(image: source, size: size, candidates: candidates, purpose: purpose, preferences: preferences ?? PreferencesStore(storage: MemoryPreferencesStorage()), toolbarArea: toolbarArea)
        window = SelectionWindow(contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        root.onAction = { [weak self] action, rect, image in self?.actions.append((action, rect, image)) }
        root.onCancel = { [weak self] in self?.cancelCount += 1 }
        root.onError = { [weak self] in self?.errors.append($0) }
        window.onKeyEquivalent = { [weak root] in root?.handleShortcut($0) ?? false }
        root.layoutSubtreeIfNeeded()
    }

    func mouse(_ type: NSEvent.EventType, at point: CGPoint, clickCount: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: root.convert(point, to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1)!
    }

    func gesture(from start: CGPoint, to end: CGPoint) {
        root.mouseDown(with: mouse(.leftMouseDown, at: start))
        if start != end { root.mouseDragged(with: mouse(.leftMouseDragged, at: end)) }
        root.mouseUp(with: mouse(.leftMouseUp, at: end))
    }

    func routedGesture(from start: CGPoint, to end: CGPoint, clickCount: Int = 1) throws {
        guard let receiver = hit(at: start) else { throw SelectionUIFailure(description: "No view receives gesture at \(start)") }
        receiver.mouseDown(with: mouse(.leftMouseDown, at: start, clickCount: clickCount))
        if start != end { receiver.mouseDragged(with: mouse(.leftMouseDragged, at: end, clickCount: clickCount)) }
        receiver.mouseUp(with: mouse(.leftMouseUp, at: end, clickCount: clickCount))
    }

    func button(_ title: String) throws -> NSButton {
        let matches = visibleButtons.filter { $0.title == title }
        guard let button = matches.first(where: { $0.imagePosition == .imageOnly }) ?? matches.first else {
            throw SelectionUIFailure(description: "Missing toolbar button: \(title)")
        }
        return button
    }

    var toolbarItems: [NSView] { root.verificationToolbar.rows.flatMap { $0 }.filter { !$0.isHidden } }
    var visibleButtons: [NSButton] {
        toolbarItems.flatMap { item -> [NSButton] in
            if let size = item as? AnnotationSizeControl { return [size.minus, size.plus] }
            return (item as? NSButton).map { [$0] } ?? []
        }.filter { !($0 is NSPopUpButton) }
    }
    var menus: [NSPopUpButton] { toolbarItems.compactMap { $0 as? NSPopUpButton } }
    var configurations: [NSButton] {
        visibleButtons.filter { ($0.accessibilityLabel() ?? "").contains(":") }
    }
    var actionButtons: [NSButton] { visibleButtons.filter { !configurations.contains($0) } }

    var sizeControl: AnnotationSizeControl? { toolbarItems.compactMap { $0 as? AnnotationSizeControl }.first }
    func setParameter(_ label: String) throws {
        let parts = label.split(separator: ":", maxSplits: 1).map(String.init)
        if let size = sizeControl, size.category == parts[0], let value = Double(parts[1]) {
            size.slider.doubleValue = value
            size.slider.sendAction(size.slider.action, to: size.slider.target)
        } else if parts[0] == "贴纸图案", let button = root.verificationAnnotationControls.stickerButtons.first(where: { $0.accessibilityLabel() == label }) {
            button.performClick(nil)
        } else { try sample(label).performClick(nil) }
    }
    func sample(_ label: String) throws -> NSButton {
        guard let button = configurations.first(where: { $0.accessibilityLabel() == label }) else {
            throw SelectionUIFailure(description: "Missing configuration sample: \(label); visible=\(configurations.map { $0.accessibilityLabel() ?? "" })")
        }
        return button
    }

    func selectedSample(_ category: String) throws -> String {
        if let size = sizeControl, size.category == category { return category + ":" + size.valueLabel.stringValue }
        if category == "贴纸图案", let item = StickerCatalog.item(for: root.verificationCanvas.selectedAnnotation?.text ?? root.verificationCanvas.annotationSticker) {
            return category + ":" + item.title
        }
        let selected = configurations.filter { ($0.accessibilityLabel() ?? "").hasPrefix(category + ":") && $0.state == .on }
        guard selected.count == 1, let label = selected.first?.accessibilityLabel() else {
            throw SelectionUIFailure(description: "Expected one selected \(category) sample, found \(selected.count)")
        }
        return label
    }

    func doubleClick(at point: CGPoint) throws {
        try routedGesture(from: point, to: point)
        try routedGesture(from: point, to: point, clickCount: 2)
    }

    func center(of view: NSView) -> CGPoint {
        root.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), from: view)
    }

    func hit(at point: CGPoint) -> NSView? {
        // NSView.hitTest takes coordinates in its superview, including the root view.
        root.hitTest(root.convert(point, to: root.superview))
    }

    func key(_ code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }
}

@main
private struct SelectionUIVerification {
    @MainActor static func main() {
        guard (2...3).contains(CommandLine.arguments.count), CommandLine.arguments[1].hasPrefix("/"),
              CommandLine.arguments.count == 2 || ["", "--scroll-only", "--overlay-only"].contains(CommandLine.arguments[2]) else {
            print("Run scripts/verify-selection-ui.sh from Terminal."); return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
            fputs("FAIL: selection UI verification timed out\n", stderr); exit(1)
        }
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/private/tmp")
        var failures = 0
        func run(_ title: String, _ check: () throws -> Void) {
            do { try check(); print("PASS: \(title)") }
            catch { failures += 1; print("FAIL: \(title): \(error)") }
            fflush(stdout)
        }
        do {
            let image = try fixtureImage()
            if CommandLine.arguments.contains("--overlay-only") {
                run("nonactivating overlays retain current application and route input on every display") { try verifyOverlayInputOwnership(image) }
                run("cross-screen completion and undo target the selected display") { try verifyCrossScreenShortcuts(image) }
                run("cross-screen Delete and Esc prioritize the selected annotation") { try verifyCrossScreenEditingKeys(image) }
                print(failures == 0 ? "PASS: overlay checks completed; native fullscreen Spaces require manual verification" : "FAIL: overlay checks")
                exit(failures == 0 ? 0 : 1)
            }
            if CommandLine.arguments.contains("--scroll-only") {
                run("scroll selection keeps body dragging and explicit W window selection") { try verifyScrollBodySelection(image) }
                run("reselection cancellation fires once and does not run on completion or shutdown") { try verifyReselectionCancellation(image) }
                print(failures == 0 ? "PASS: scrolling selection checks completed" : "FAIL: scrolling selection checks")
                exit(failures == 0 ? 0 : 1)
            }
            run("preview feedback: subject exit, labeled actions and persistent recording modes") { try verifyPreviewFeedback(image) }
            run("production selection callbacks release views after repeated cancellation") { try verifySelectionLifetime(image) }
            run("production selection callbacks survive deactivation and release after completion") { try verifySelectionCallbackReuse(image) }
            run("each entry exposes only its authorized toolbar actions") { try verifyEntryToolbars(image) }
            run("native full-screen recording buttons remain on the physical display") { try verifyNativeFullScreenButtons(image) }
            run("frozen overlays cover every display and end when input ownership is lost") { try verifyOverlayInputOwnership(image) }
            run("full-screen selection returns to free or window selection") { try verifyFullScreenModes(image) }
            run("leaving full-screen clears stale hover and uses a selection cursor") { try verifyFullScreenInteraction(image) }
            run("full-screen completion stays visible with Dock insets and narrow displays") { try verifyFullScreenCompletion(image) }
            run("toolbar buttons remain clickable after repositioning") { try verifyToolbar(image) }
            run("four screenshot modes retain a grouped main bar and unique native selected state") { try verifyFourModes(image) }
            run("mode changes preserve the old result until a valid new result commits") { try verifyModePreservation(image) }
            run("window and full-screen resize become free rectangle selections") { try verifyModeResize(image) }
            run("default window hover and clicks coexist with direct rectangle dragging") { try verifyCandidate(image) }
            run("scroll defaults to body dragging, retains explicit window selection and leaves OCR/record defaults unchanged") { try verifyScrollBodySelection(image) }
            run("invalid automatic drags restore mode and retain the last annotated result") { try verifyAutomaticDragPreservation(image) }
            run("drag selection persists and supports movement and all eight handles") { try verifyGestures(image) }
            run("active annotation tool routes hit testing to the canvas") { try verifyCanvasHit(image) }
            run("annotation buttons toggle off and restore movement without a move button") { try verifyToolToggle(image) }
            run("tool-specific configuration is shown only while its tool is active") { try verifyToolConfiguration(image) }
            run("each annotation tool retains independent configuration") { try verifyIndependentConfiguration(image) }
            run("object picking synchronizes tools, changes parameters and undoes without moving the screenshot") { try verifyObjectEditing(image) }
            run("existing annotation strokes near screenshot edges retain canvas hit routing") { try verifyEdgeAnnotationHit(image) }
            run("Delete and Esc prioritize annotation editing over screenshot cancellation") { try verifyEditingKeys(image) }
            run("export excludes annotation selection controls") { try verifySelectionControlsExport(image) }
            run("single and double background clicks retain and export the original selection") { try verifyBackgroundClicks(image) }
            run("inside blank double clicks complete through native hit routing; annotations retain editing priority") { try verifyInsideDoubleClicks(image) }
            run("background dragging replaces selection only after the movement threshold") { try verifyBackgroundDrag(image) }
            run("cross-screen background confirmation exports the selected screen") { try verifyCrossScreenBackground(image) }
            run("inline text input receives hit tests and commits or cancels locally") { try verifyInlineText(image) }
            run("Retina events and cropped export share pixel coordinates; toolbar is excluded") { try verifyRetinaExport(image) }
            run("persistent defaults survive new screenshots; selecting old objects preserves defaults") { try verifyPersistentDefaults(image) }
            run("entry selection controls and completion buttons share consistent styles") { try verifyButtonStyles(image) }
            run("F, Enter and Esc invoke the expected selection actions") { try verifyShortcuts(image) }
            run("cross-screen completion and undo target the selected display") { try verifyCrossScreenShortcuts(image) }
            run("cross-screen Delete and Esc prioritize the selected annotation") { try verifyCrossScreenEditingKeys(image) }
            print("SKIP: save-panel cancellation requires manual modal interaction")
            run("generated arrow, text, mosaic and selected-object previews") { try previews(output: output) }
        } catch { failures += 1; print("FAIL: fixture setup: \(error)") }
        print(failures == 0 ? "PASS: all selection UI checks completed" : "FAIL: \(failures) selection UI check(s)")
        exit(failures == 0 ? 0 : 1)
    }

    fileprivate static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw SelectionUIFailure(description: message) }
    }

    private static func describes(_ view: NSView?) -> String {
        guard let view else { return "nil" }
        return "\(type(of: view)) frame=\(view.frame)"
    }

    private static func isHit(_ hit: NSView?, inside expected: NSView) -> Bool {
        guard let hit else { return false }
        return hit === expected || hit.isDescendant(of: expected)
    }

    private static func fixtureImage() throws -> CGImage {
        guard let context = CGContext(data: nil, width: 1600, height: 1200, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw SelectionUIFailure(description: "Cannot allocate synthetic image")
        }
        for y in stride(from: 0, to: 1200, by: 40) {
            for x in stride(from: 0, to: 1600, by: 40) {
                context.setFillColor(CGColor(red: CGFloat(x) / 2000 + 0.1,
                    green: CGFloat(y) / 1800 + 0.1, blue: 0.45, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 40, height: 40))
            }
        }
        guard let image = context.makeImage() else { throw SelectionUIFailure(description: "Cannot make synthetic image") }
        return image
    }

    @MainActor private static func verifySelectionLifetime(_ image: CGImage) throws {
        let selector = RegionSelector()
        for iteration in 1...3 {
            weak var retained: SelectionView?
            autoreleasepool {
                let view = SelectionView(image: image, size: CGSize(width: 800, height: 600),
                    candidates: [], purpose: .screenshot,
                    preferences: PreferencesStore(storage: MemoryPreferencesStorage()))
                retained = view
                selector.verificationAttachProductionAction(view)
                selector.cancel()
            }
            try require(retained == nil, "Cancelled screenshot still retains its view on iteration \(iteration)")
        }
    }

    @MainActor private static func verifyReselectionCancellation(_ image: CGImage) throws {
        let selector = RegionSelector()
        var cancellations = 0
        selector.verificationSetCancellation { cancellations += 1 }
        selector.verificationUserCancel()
        selector.verificationUserCancel()
        try require(cancellations == 1, "User cancellation was omitted or delivered more than once")
        selector.verificationSetCancellation { cancellations += 1 }
        selector.cancel()
        selector.verificationUserCancel()
        try require(cancellations == 1, "Shutdown or replacement restored a cancelled session")
        var completed = false
        let view = SelectionView(image: image, size: CGSize(width: 800, height: 600), candidates: [], purpose: .scroll,
                                 preferences: PreferencesStore(storage: MemoryPreferencesStorage()))
        selector.verificationAttachProductionAction(view) { _, _, _ in completed = true }
        selector.verificationSetCancellation { cancellations += 1 }
        view.onAction?(.scroll, CGRect(x: 30, y: 40, width: 200, height: 100), image)
        let deadline = Date().addingTimeInterval(0.6)
        while !completed && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        try require(completed && cancellations == 1, "Confirming a replacement selection also invoked cancellation")
        selector.verificationUserCancel()
        try require(cancellations == 1, "Completion retained the old cancellation handler")
    }

    @MainActor private static func verifySelectionCallbackReuse(_ image: CGImage) throws {
        let selector = RegionSelector()
        let rect = CGRect(x: 30, y: 40, width: 200, height: 100)
        var result: (CaptureSelectionAction, CaptureRegion, CGImage?)?
        weak var retained: SelectionView?
        autoreleasepool {
            let view = SelectionView(image: image, size: CGSize(width: 800, height: 600),
                candidates: [], purpose: .text,
                preferences: PreferencesStore(storage: MemoryPreferencesStorage()))
            retained = view
            selector.verificationAttachProductionAction(view) { result = ($0, $1, $2) }
            view.deactivate()
            // Only routes a synthetic image to the local callback; no OCR or clipboard operation runs.
            view.onAction?(.ocr, rect, image)
        }
        try require(retained == nil, "Completed screenshot still retains its view")
        let deadline = Date().addingTimeInterval(0.5)
        while result == nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        guard let result else { throw SelectionUIFailure(description: "Deactivation removed the production completion callback") }
        try require(result.0 == .ocr && result.2 === image,
                    "Reused selection callback changed the requested action or frozen image")
        try require(result.1.rect == rect.offsetBy(dx: 1200, dy: -200)
                    && result.1.displayID == 17 && result.1.scale == 2,
                    "Reused selection callback changed screen coordinate conversion")
    }

    @MainActor private static func verifyPreviewFeedback(_ image: CGImage) throws {
        let subject = SelectionUIFixture(source: image)
        // No Vision request: simulate an active subject mode with no detected result.
        subject.root.setScreenshotMode(.subject, startAnalysis: false)
        let point = CGPoint(x: 100, y: 100)
        try subject.routedGesture(from: point, to: point, clickCount: 2)
        try require(subject.cancelCount == 1 && subject.actions.isEmpty,
                    "Double clicking a subject background without a result must cancel")
        let subjectActions = subject.actionButtons.filter { ["取消", "完成"].contains($0.title) }
        try require(subjectActions.map(\.title) == ["取消", "完成"]
                    && subjectActions.allSatisfy { $0.imagePosition == .imageOnly }, "Subject actions must remain compact icons ordered cancel then finish")
        for purpose in [CaptureSelectionPurpose.screenshot, .text, .scroll, .record] {
            let fixture = SelectionUIFixture(source: image, purpose: purpose)
            fixture.root.verificationSelect(CGRect(x: 140, y: 200, width: 440, height: 280))
            let title = purpose == .screenshot ? "完成" : "确认"
            let button = try fixture.button(title) as! SelectionButton
            var clicks = 0
            button.actionBlock = { clicks += 1 }
            for _ in 0..<3 {
                button.performClick(nil)
                try require(button.state == .off, "\(purpose) completion retained selected state")
            }
            try require(clicks == 3, "\(purpose) completion did not fire on every click")
        }
        let text = SelectionUIFixture(source: image, purpose: .text)
        text.gesture(from: CGPoint(x: 100, y: 120), to: CGPoint(x: 500, y: 400))
        try require(text.actionButtons.map(\.title) == ["取消", "确认"]
                    && text.actionButtons.allSatisfy { $0.imagePosition == .imageLeading }, "OCR actions must be labeled cancel then confirm")
        let record = SelectionUIFixture(source: image, purpose: .record)
        try require(record.actionButtons.map(\.title) == ["框选", "窗口", "整屏", "取消"], "Recording modes must remain explicit before selection")
        try record.button("整屏").performClick(nil)
        try require(record.actionButtons.map(\.title) == ["框选", "窗口", "整屏", "取消", "确认"], "Recording modes must remain available after selection")
    }

    @MainActor private static func verifyEntryToolbars(_ image: CGImage) throws {
        let selected = CGRect(x: 140, y: 200, width: 440, height: 280)
        for purpose in [CaptureSelectionPurpose.screenshot, .text, .scroll, .record] {
            let f = SelectionUIFixture(source: image, purpose: purpose)
            let initial = purpose == .screenshot
                ? ["框选", "主体", "窗口", "整屏"] + AnnotationControls.displayOrder.map(\.rawValue) + ["撤销", "保存", "贴图", "文字", "取消", "完成"]
                : (purpose == .record ? ["框选", "窗口", "整屏", "取消"] : [])
            try require(f.actionButtons.map(\.title) == initial && f.configurations.isEmpty && f.menus.isEmpty,
                        "\(purpose) has incorrect initial toolbar actions")
            if purpose == .screenshot {
                try verifyMergedToolbar(f)
                try require(f.visibleButtons.filter { !["框选", "主体", "窗口", "整屏", "取消"].contains($0.title) }
                    .allSatisfy { !$0.isEnabled }, "Unselected screenshot tools or exports are not disabled")
                let cancel = try f.button("取消")
                try require(cancel.isEnabled, "Unselected screenshot cannot be cancelled")
            }
            f.root.verificationSelect(selected)
            let expected = purpose == .screenshot
                ? AnnotationControls.displayOrder.map(\.rawValue) + ["撤销", "框选", "主体", "窗口", "整屏", "保存", "贴图", "文字", "取消", "完成"]
                : (purpose == .record ? ["框选", "窗口", "整屏", "取消", "确认"] : ["取消", "确认"])
            try require(f.actionButtons.map(\.title).sorted() == expected.sorted(),
                        "\(purpose) has incorrect buttons: \(f.actionButtons.map(\.title))")
            try require(f.configurations.isEmpty && f.menus.isEmpty, "\(purpose) exposes configuration without an active annotation tool")
            for removed in ["自由框选", "窗口框选", "矩形", "移动", "编辑器", "长截图", "录屏"] {
                try require(!f.visibleButtons.contains(where: { $0.title == removed }), "Removed action \(removed) remains visible")
            }
            if purpose != .screenshot {
                for (code, characters) in [(UInt16(8), "c"), (UInt16(1), "s"), (UInt16(6), "z")] {
                    _ = f.root.handleShortcut(f.key(code, characters: characters, modifiers: .command))
                    try require(f.actions.isEmpty, "\(purpose) retains a hidden Command-\(characters) action")
                }
                try f.button("确认").performClick(nil)
                try require(f.actions.count == 1 && f.actions[0].0 == purpose.primaryAction,
                            "Dedicated \(purpose) confirm button invokes another entry's action")
            }
        }
    }

    @MainActor private static func verifyMergedToolbar(_ fixture: SelectionUIFixture) throws {
        guard let main = fixture.root.verificationToolbar.rows.first else {
            throw SelectionUIFailure(description: "Screenshot main toolbar is missing")
        }
        let separators = main.indices.filter { main[$0] is ToolbarSeparator }
        try require(separators.count == 2, "Screenshot main bar does not separate mode, tool and action groups")
        let modes = Array(main[..<separators[0]]).compactMap { $0 as? NSButton }
        let tools = Array(main[(separators[0] + 1)..<separators[1]]).compactMap { $0 as? NSButton }
        let actions = Array(main[(separators[1] + 1)...]).compactMap { $0 as? NSButton }
        try require(modes.map(\.title) == ["框选", "主体", "窗口", "整屏"]
                    && modes.allSatisfy { $0.imagePosition == .noImage }, "Screenshot modes lost their first compact group")
        try require(tools.map(\.title) == AnnotationControls.displayOrder.map(\.rawValue) + ["撤销"]
                    && tools.allSatisfy { $0.imagePosition == .imageOnly }, "Screenshot tools lost their independent group")
        try require(actions.map(\.title) == ["保存", "贴图", "文字", "取消", "完成"]
                    && actions.allSatisfy { $0.imagePosition == .imageOnly },
                    "Screenshot completion actions lost their icon presentation or accessible titles")
        for button in actions {
            try require(button.toolTip?.isEmpty == false && button.accessibilityLabel()?.isEmpty == false,
                        "A compact completion action has no tooltip or accessible name")
            try require(isHit(fixture.hit(at: fixture.center(of: button)), inside: button),
                        "A compact completion action cannot receive clicks")
        }
        try require(fixture.root.verificationToolbar.rows.dropFirst().flatMap { $0 }.allSatisfy { item in
            !main.contains { $0 === item }
        }, "Main-bar controls leaked into a parameter row")
    }

    @MainActor private static func verifyPersistentDefaults(_ image: CGImage) throws {
        let storage = MemoryPreferencesStorage()
        let store = PreferencesStore(storage: storage)
        let rect = CGRect(x: 140, y: 200, width: 440, height: 280)
        let first = SelectionUIFixture(source: image, preferences: store)
        first.root.verificationSelect(rect)
        try first.button("方框").performClick(nil)
        try first.setParameter("标注颜色:蓝色")
        try first.setParameter("标注粗细:8")
        let rebuilt = PreferencesStore(storage: storage)
        let second = SelectionUIFixture(source: image, preferences: rebuilt)
        second.root.verificationSelect(rect)
        try second.button("方框").performClick(nil)
        try require(second.root.verificationCanvas.annotationWidth == 16, "New screenshot lost saved point width at Retina scale")
        try require(second.root.verificationCanvas.annotationColor.isEqual(NSColor.systemBlue), "New screenshot lost saved color")
        try second.button("箭头").performClick(nil)
        try require(second.root.verificationCanvas.annotationWidth == 6, "Rectangle preference leaked into another tool")
        // Construct a different old object without a user configuration change.
        let canvas = second.root.verificationCanvas
        canvas.tool = .rectangle; canvas.annotationColor = .systemYellow; canvas.annotationWidth = 3
        try second.routedGesture(from: CGPoint(x: 200, y: 260), to: CGPoint(x: 380, y: 400))
        let saved = rebuilt.annotation(for: ImageToolsTool.rectangle.rawValue)
        let writes = storage.writeCount
        canvas.deselectAnnotation()
        try second.routedGesture(from: CGPoint(x: 280, y: 260), to: CGPoint(x: 280, y: 260))
        try require(storage.writeCount == writes && rebuilt.annotation(for: ImageToolsTool.rectangle.rawValue) == saved,
                    "Picking old annotation polluted persisted defaults")
        try second.setParameter("标注粗细:5")
        let changed = rebuilt.annotation(for: ImageToolsTool.rectangle.rawValue)
        try require(changed.width == 5 && changed.colorID == saved.colorID,
                    "Editing one field copied unrelated old-object parameters into defaults")
        canvas.deselectAnnotation()
        try require(canvas.annotationColor.isEqual(NSColor.systemBlue) && canvas.annotationWidth == 10,
                    "Deselecting object did not restore drawing defaults")
    }

    @MainActor private static func verifyButtonStyles(_ image: CGImage) throws {
        for purpose in [CaptureSelectionPurpose.screenshot, .text, .scroll, .record] {
            let f = SelectionUIFixture(source: image, purpose: purpose)
            if !purpose.supportsFullScreen {
                try require(!f.root.handleShortcut(f.key(3, characters: "f")) && f.root.verificationSelection == nil,
                            "A hidden full-screen shortcut remains in a dedicated entry")
            }
            f.root.verificationSelect(CGRect(x: 140, y: 200, width: 440, height: 280))
            for button in f.actionButtons {
                let annotation = ImageToolsTool.allCases.contains(where: { $0.rawValue == button.title }) && button.imagePosition == .imageOnly
                let mode = (purpose == .screenshot || purpose == .record) && ["框选", "主体", "窗口", "整屏"].contains(button.title)
                let compactAction = (purpose == .screenshot && ["取消", "确认", "完成"].contains(button.title))
                    || (purpose == .screenshot && ["保存", "贴图", "文字"].contains(button.title))
                if annotation || button.title == "撤销" { try require(button.imagePosition == .imageOnly, "Annotation operations mix text and icon styles") }
                else if mode { try require(button.imagePosition == .noImage, "Mode selection does not use the compact text group") }
                else if compactAction { try require(button.imagePosition == .imageOnly, "Compact screenshot actions retain redundant captions") }
                else { try require(button.imagePosition == .imageLeading, "Completion operation has no visible label") }
                try require(button.bezelColor == nil, "A completion button unexpectedly turns green")
            }
            if purpose.supportsAnnotations {
                try verifyMergedToolbar(f)
            }
        }
    }

    @MainActor private static func verifyNativeFullScreenButtons(_ image: CGImage) throws {
        if NSScreen.screens.isEmpty {
            throw SelectionUISkip(description: "native full-screen frame check needs a GUI screen")
        }
        for screen in NSScreen.screens {
            let window = SelectionWindow(covering: screen)
            window.isReleasedWhenClosed = false
            let root = SelectionView(image: image, size: screen.frame.size, candidates: [], purpose: .record,
                                     preferences: PreferencesStore(storage: MemoryPreferencesStorage()),
                                     toolbarArea: screen.visibleFrame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY))
            window.contentView = root
            root.verificationFullScreen()
            defer { window.close() }
            print("INFO: own selection frame=\(window.frame), display=\(screen.frame), visible=\(screen.visibleFrame)")
            for title in ["框选", "窗口", "整屏", "取消", "确认"] {
                guard let button = root.verificationToolbar.rows.flatMap({ $0 }).compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) else {
                    throw SelectionUIFailure(description: "Missing full-screen recording button \(title)")
                }
                let global = window.convertToScreen(button.convert(button.bounds, to: nil))
                print("INFO: own recording action=\(title), screen rect=\(global)")
                try require(screen.visibleFrame.contains(global), "\(title) is outside the physical display after full-screen selection")
                let local = root.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), from: button)
                try require(isHit(root.hitTest(local), inside: button), "\(title) is not hit-testable after full-screen selection")
            }
        }
    }

    @MainActor private static func verifyFullScreenCompletion(_ image: CGImage) throws {
        for size in [CGSize(width: 1280, height: 832), CGSize(width: 320, height: 280)] {
            let safe = CGRect(x: 0, y: 60, width: size.width, height: size.height - 89)
            for purpose in [CaptureSelectionPurpose.screenshot, .record] {
                let f = SelectionUIFixture(source: image, size: size, purpose: purpose, toolbarArea: safe)
                try f.button("整屏").performClick(nil)
                let title = purpose == .record ? "确认" : "完成"
                let actions = purpose == .screenshot
                    ? ["框选", "主体", "窗口", "整屏", title, "取消"]
                    : ["框选", "窗口", "整屏", "取消", title]
                try require(safe.contains(f.root.verificationToolbar.frame), "Full-screen toolbar crosses Dock/menu occupied area")
                let grouped = f.root.verificationToolbar.rows.contains { row in
                    let titles = row.compactMap { ($0 as? NSButton)?.title }
                    return actions.allSatisfy { titles.contains($0) }
                }
                if purpose == .screenshot {
                    let modes = Array((f.root.verificationToolbar.rows.first?.compactMap { ($0 as? NSButton)?.title } ?? []).prefix(4))
                    try require(modes == ["框选", "主体", "窗口", "整屏"], "Four screenshot modes changed after full-screen selection")
                } else {
                    try require(grouped, "Recording selection modes and completion have separate groups")
                }
                for button in f.visibleButtons {
                    let rect = f.root.convert(button.bounds, from: button)
                    try require(safe.contains(rect), "Full-screen toolbar clips \(button.title)")
                }
                for name in actions {
                    let button = try f.button(name)
                    let rect = f.root.convert(button.bounds, from: button)
                    try require(safe.contains(rect) && isHit(f.hit(at: f.center(of: button)), inside: button),
                                "\(purpose) full-screen \(name) is hidden, clipped or not hit-testable")
                }
                try f.button(title).performClick(nil)
                try require(f.actions.count == 1 && f.actions[0].0 == purpose.primaryAction && f.actions[0].1 == f.root.bounds,
                            "Full-screen completion no longer uses the full crop")
                let cancel = SelectionUIFixture(source: image, size: size, purpose: purpose, toolbarArea: safe)
                try cancel.button("整屏").performClick(nil)
                try cancel.button("取消").performClick(nil)
                try require(cancel.cancelCount == 1 && cancel.actions.isEmpty, "Full-screen cancel cannot exit")
            }
        }
    }

    @MainActor private static func verifyFullScreenModes(_ image: CGImage) throws {
        let candidate = CGRect(x: 140, y: 200, width: 440, height: 280)
        for purpose in [CaptureSelectionPurpose.screenshot, .record] {
            let choices = ["框选", "窗口"]
            for mode in choices {
                let f = SelectionUIFixture(source: image, candidates: [candidate], purpose: purpose)
                try f.button("整屏").performClick(nil)
                try require(f.root.verificationSelection == f.root.bounds, "Full-screen did not select the entire current display")
                if purpose == .screenshot {
                    try require(f.actionButtons.contains(where: { $0.title == "整屏" && $0.state == .on }),
                                "Screenshot full-screen mode disappeared instead of staying selected")
                } else {
                    try require(f.actionButtons.contains(where: { $0.title == "整屏" && $0.state == .on }), "Recording full-screen mode must stay visible and selected")
                }
                let button = try f.button(mode)
                try require(isHit(f.hit(at: f.center(of: button)), inside: button), "\(mode) cannot receive hit testing")
                button.performClick(nil)
                if purpose == .screenshot {
                    try require(f.root.verificationSelection == f.root.bounds && f.root.verificationPendingModeChange,
                                "Changing screenshot mode discarded the previous full-screen result")
                } else {
                    try require(f.root.verificationSelection == nil, "Recording mode did not return to selection")
                }
                let center = CGPoint(x: candidate.midX, y: candidate.midY)
                f.gesture(from: center, to: center)
                if mode == "窗口" || mode == "窗口框选" {
                    try require(f.root.verificationSelection == candidate, "Window mode cannot lock a candidate after full-screen selection")
                } else {
                    try require(f.root.verificationSelection == (purpose == .screenshot ? f.root.bounds : nil),
                                "Free mode unexpectedly selected a window by clicking")
                    f.gesture(from: CGPoint(x: 180, y: 250), to: CGPoint(x: 450, y: 430))
                    try require(f.root.verificationSelection == CGRect(x: 180, y: 250, width: 270, height: 180),
                                "Free mode cannot drag a selection after full-screen selection")
                }
                try require(f.actions.isEmpty, "Changing selection mode completed an export")
            }
            let interrupted = SelectionUIFixture(source: image, purpose: purpose)
            interrupted.root.mouseDown(with: interrupted.mouse(.leftMouseDown, at: CGPoint(x: 150, y: 200)))
            interrupted.root.mouseDragged(with: interrupted.mouse(.leftMouseDragged, at: CGPoint(x: 300, y: 350)))
            _ = interrupted.root.handleShortcut(interrupted.key(3, characters: "f"))
            interrupted.root.mouseUp(with: interrupted.mouse(.leftMouseUp, at: CGPoint(x: 300, y: 350)))
            try require(interrupted.root.verificationSelection == interrupted.root.bounds
                && interrupted.root.verificationVisibleSelection == interrupted.root.bounds,
                "F during a drag left a stale rectangle preview over the full-screen result")
        }
    }

    @MainActor private static func verifyFullScreenInteraction(_ image: CGImage) throws {
        let f = SelectionUIFixture(source: image)
        let screen = try f.button("整屏") as! SelectionButton
        screen.performClick(nil)
        let entered = NSEvent.enterExitEvent(with: .mouseEntered, location: f.center(of: screen), modifierFlags: [],
            timestamp: 0, windowNumber: f.window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        screen.mouseEntered(with: entered)
        RunLoop.main.run(until: Date().addingTimeInterval(0.22))
        try f.button("框选").performClick(nil)
        try require(screen.state == .off && !screen.isPointerInside && !screen.isHighlighted,
                    "Full-screen retains hover/press decoration after switching to rectangle")
        NSCursor.openHand.set()
        f.root.mouseMoved(with: f.mouse(.mouseMoved, at: CGPoint(x: 200, y: 200)))
        try require(NSCursor.current == NSCursor.crosshair, "Pending rectangle selection still shows a move hand")
        f.gesture(from: CGPoint(x: 200, y: 200), to: CGPoint(x: 450, y: 400))
        f.root.mouseMoved(with: f.mouse(.mouseMoved, at: CGPoint(x: 200, y: 300)))
        try require(NSCursor.current == NSCursor.resizeLeftRight, "Committed rectangle edge lacks resize cursor")
        f.root.mouseMoved(with: f.mouse(.mouseMoved, at: CGPoint(x: 300, y: 300)))
        try require(NSCursor.current == NSCursor.openHand, "Committed rectangle interior lost move cursor")
    }

    @MainActor private static func verifyOverlayInputOwnership(_ image: CGImage) throws {
        try require(!NSScreen.screens.isEmpty, "No native displays available for overlay coverage check")
        NSApp.setActivationPolicy(.accessory)
        let initialApplication = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let initiallyActive = NSApp.isActive
        let initiallyRunningActive = NSRunningApplication.current.isActive
        let selector = RegionSelector()
        defer { selector.cancel() }
        selector.verificationShowFrozenScreens(image)
        let windows = selector.verificationWindows
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        print("INFO: overlay focus before frontmost=\(String(describing: initialApplication)) AppKit=\(initiallyActive) runningApplication=\(initiallyRunningActive); after frontmost=\(String(describing: NSWorkspace.shared.frontmostApplication?.processIdentifier)) AppKit=\(NSApp.isActive) runningApplication=\(NSRunningApplication.current.isActive)")
        // AppKit may report the nonactivating panel's local focus as active.
        // The system's frontmost owner and running-application state must stay unchanged.
        try require(NSWorkspace.shared.frontmostApplication?.processIdentifier == initialApplication
                    && NSRunningApplication.current.isActive == initiallyRunningActive,
                    "Presenting screenshot overlays activated their application")
        try require(windows.count == NSScreen.screens.count, "Some displays have no frozen overlay")
        for screen in NSScreen.screens {
            guard let window = windows.first(where: { $0.frame == screen.frame }), let root = window.contentView else {
                throw SelectionUIFailure(description: "Overlay does not cover display \(screen.frame)")
            }
            try require(!window.ignoresMouseEvents && window.isVisible && window.level == .screenSaver,
                        "Frozen overlay does not intercept input above the desktop")
            guard let panel = window as? NSPanel else {
                throw SelectionUIFailure(description: "Screenshot overlay is not a nonactivating panel")
            }
            try require(panel.styleMask.contains(.nonactivatingPanel) && !panel.hidesOnDeactivate
                        && !panel.becomesKeyOnlyIfNeeded && panel.canBecomeKey && !panel.canBecomeMain,
                        "Screenshot panel cannot accept keys while another application remains active")
            try require(panel.collectionBehavior.contains([.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]),
                        "Screenshot overlay cannot join other applications' fullscreen Spaces")
            for point in [CGPoint(x: 2, y: 2), CGPoint(x: root.bounds.maxX - 2, y: root.bounds.maxY - 2),
                          CGPoint(x: root.bounds.midX, y: root.bounds.midY)] {
                try require(root.hitTest(root.convert(point, to: root.superview)) != nil, "Frozen overlay has an input hole")
            }
            window.makeKey(); window.makeFirstResponder(root)
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            try require(selector.verificationWindows.count == windows.count, "Changing the key display cancelled selection")
            try require(window.firstResponder === root, "Screenshot does not own its window's keyboard responder")
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: CGPoint(x: 20, y: 100), modifierFlags: [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                    clickCount: 1, pressure: 1) else { throw SelectionUIFailure(description: "Cannot construct overlay click") }
                window.sendEvent(event)
            }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        try require(NSWorkspace.shared.frontmostApplication?.processIdentifier == initialApplication
                    && NSRunningApplication.current.isActive == initiallyRunningActive,
                    "Clicking a screenshot overlay activated its application")
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        try require(selector.verificationWindows.count == windows.count,
                    "Application inactivity cancelled a panel that still owns keyboard focus")

        guard let parent = windows.last else { throw SelectionUIFailure(description: "Missing overlay for child-focus check") }
        let child = SelectionWindow(contentRect: CGRect(x: parent.frame.minX + 20, y: parent.frame.minY + 100, width: 120, height: 90),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        child.isReleasedWhenClosed = false
        child.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]
        child.hidesOnDeactivate = false
        parent.addChildWindow(child, ordered: .above)
        defer { parent.removeChildWindow(child); child.orderOut(nil) }
        child.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        try require(child.isKeyWindow, "Child-focus fixture did not obtain keyboard focus")
        try require(selector.verificationWindows.count == windows.count, "A child picker taking focus cancelled selection")
        parent.makeKey()
        parent.removeChildWindow(child)
        child.orderOut(nil)
        windows.forEach { $0.resignKey() }
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: parent)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        try require(selector.verificationWindows.isEmpty && windows.allSatisfy { !$0.isVisible },
                    "Frozen screens remain while another app receives keyboard input")
        selector.verificationShowFrozenScreens(image)
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        try require(selector.verificationWindows.isEmpty, "Display change leaves stale input coverage")
        selector.verificationShowFrozenScreens(image)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        try require(selector.verificationWindows.isEmpty, "Space change leaves the previous desktop frozen over the new one")
    }

    @MainActor private static func verifyFourModes(_ image: CGImage) throws {
        for size in [CGSize(width: 800, height: 600), CGSize(width: 320, height: 400)] {
            let f = SelectionUIFixture(source: image, size: size)
            for title in ["框选", "框选", "窗口", "窗口", "整屏", "整屏", "主体", "主体", "框选"] {
                try f.button(title).performClick(nil)
                try verifyMergedToolbar(f)
                let row = Array((f.root.verificationToolbar.rows.first?.compactMap { $0 as? NSButton } ?? []).prefix(4))
                try require(row.map(\.title) == ["框选", "主体", "窗口", "整屏"],
                            "Four screenshot modes changed order within the main bar")
                try require(row.filter { $0.state == .on }.map(\.title) == [title],
                            "The requested screenshot mode does not have a unique selected state")
                try require(Set(row.map { $0.frame.midY }).count == 1,
                            "A screenshot mode wrapped onto a separate visual line")
                for button in row {
                    let rect = f.root.convert(button.bounds, from: button)
                    try require(f.root.bounds.contains(rect) && isHit(f.hit(at: f.center(of: button)), inside: button),
                                "A fixed mode button is clipped or cannot receive clicks")
                }
            }
            f.root.deactivate()
        }
    }

    @MainActor private static func verifyModePreservation(_ image: CGImage) throws {
        let candidate = CGRect(x: 90, y: 160, width: 550, height: 350)
        let f = SelectionUIFixture(source: image, candidates: [candidate])
        let old = CGRect(x: 140, y: 200, width: 440, height: 280)
        f.root.verificationSelect(old)
        try f.button("方框").performClick(nil)
        try f.routedGesture(from: CGPoint(x: 220, y: 400), to: CGPoint(x: 280, y: 350))
        let canvas = f.root.verificationCanvas
        try require(canvas.annotations.count == 1, "Cannot prepare a result with an annotation")
        try f.button("完成").performClick(nil)
        guard let originalImage = f.actions.last?.2 else { throw SelectionUIFailure(description: "Missing original annotated export") }
        let original = try ImageToolsUI.png(originalImage)
        try f.button("窗口").performClick(nil)
        try require(f.root.verificationPendingModeChange && f.root.verificationCommittedMode == .rectangle
            && f.root.verificationSelection == old && canvas.annotations.count == 1,
            "Entering window mode destroyed the committed rectangle result")
        for title in ["完成", "保存", "贴图"] {
            let button = try f.button(title)
            try require(!button.isEnabled, "Pending mode leaves an old result action enabled: \(title)")
            button.performClick(nil)
        }
        try require(f.visibleButtons.filter { AnnotationControls.displayOrder.map(\.rawValue).contains($0.title)
            && $0.imagePosition == .imageOnly }.allSatisfy { !$0.isEnabled },
            "Pending mode leaves an annotation tool enabled")
        try require(f.actions.count == 1 && canvas.annotations.count == 1,
                    "A pending mode exported or changed the retained old result")
        try f.button("框选").performClick(nil)
        try require(!f.root.verificationPendingModeChange && f.root.verificationSelection == old,
                    "Returning to the committed mode did not restore the original result")
        try f.button("完成").performClick(nil)
        guard let restoredImage = f.actions.last?.2 else { throw SelectionUIFailure(description: "Missing restored export") }
        let restored = try ImageToolsUI.png(restoredImage)
        try require(restored == original, "Returning to the old mode changed the retained image or annotations")
        try f.button("窗口").performClick(nil)
        f.gesture(from: CGPoint(x: candidate.midX, y: candidate.midY), to: CGPoint(x: candidate.midX, y: candidate.midY))
        try require(!f.root.verificationPendingModeChange && f.root.verificationCommittedMode == .window
            && f.root.verificationSelection == candidate && f.root.verificationCanvas.annotations.isEmpty,
            "A successful new window selection did not replace the old rectangle and annotations")
        try f.button("框选").performClick(nil)
        f.gesture(from: CGPoint(x: 20, y: 550), to: CGPoint(x: 30, y: 545))
        try require(f.root.verificationPendingModeChange && f.root.verificationSelection == candidate,
                    "An invalid tiny selection replaced the retained window result")
        f.gesture(from: CGPoint(x: 20, y: 550), to: CGPoint(x: 110, y: 510))
        try require(!f.root.verificationPendingModeChange && f.root.verificationCommittedMode == .rectangle
            && f.root.verificationSelection == CGRect(x: 20, y: 510, width: 90, height: 40),
            "A valid free selection did not commit the requested mode")
    }

    @MainActor private static func verifyModeResize(_ image: CGImage) throws {
        let candidate = CGRect(x: 140, y: 200, width: 440, height: 280)
        for mode in ["窗口", "整屏"] {
            let f = SelectionUIFixture(source: image, candidates: [candidate])
            try f.button(mode).performClick(nil)
            if mode == "窗口" {
                let center = CGPoint(x: candidate.midX, y: candidate.midY)
                f.gesture(from: center, to: center)
            }
            guard let selected = f.root.verificationSelection else { throw SelectionUIFailure(description: "No result for resize") }
            let start = SelectionHandle.topRight.point(in: selected)
            let end = CGPoint(x: start.x - 50, y: start.y - 40)
            f.gesture(from: start, to: end)
            let expected = SelectionGeometry.resize(selected, handle: .topRight, to: end, within: f.root.bounds).integral
            try require(f.root.verificationSelection == expected && f.root.verificationMode == .rectangle
                && f.root.verificationCommittedMode == .rectangle && !f.root.verificationPendingModeChange,
                "Resizing a window or screen did not produce an editable rectangle result")
            let freeButton = try f.button("框选"), oldModeButton = try f.button(mode)
            try require(freeButton.state == .on && oldModeButton.state == .off,
                        "Mode buttons did not follow the adjusted result")
        }
    }

    @MainActor private static func verifyToolToggle(_ image: CGImage) throws {
        let f = try preparedAnnotationFixture(image, tool: "箭头")
        let arrow = try f.button("箭头")
        try require(arrow.state == .on && !f.configurations.isEmpty, "First tool click did not activate its configuration")
        try require((arrow.layer?.borderWidth ?? 0) == 0, "Active tool retains a custom layer border")
        arrow.performClick(nil)
        try require(arrow.state == .off && f.configurations.isEmpty, "Second tool click did not return to movement")
        let selected = f.root.verificationSelection!
        let start = CGPoint(x: selected.midX, y: selected.midY)
        try require(f.hit(at: start) === f.root, "Inactive annotation tool still routes interior events to canvas")
        f.gesture(from: start, to: CGPoint(x: start.x + 30, y: start.y + 20))
        try require(f.root.verificationSelection == selected.offsetBy(dx: 30, dy: 20),
                    "Selection cannot move after toggling off without a move button")
    }

    private static let configurationLabels: [ImageToolsTool: Set<String>] = [
        .arrow: ["标注颜色", "标注粗细"], .rectangle: ["标注颜色", "标注粗细"],
        .ellipse: ["标注颜色", "标注粗细"], .pen: ["标注颜色", "标注粗细"],
        .text: ["标注颜色", "文字大小"], .number: ["标注颜色", "序号大小"],
        .mosaic: ["马赛克大小"], .sticker: ["贴纸图案", "贴纸大小"]
    ]

    private static let configurationValues: [String: [String]] = [
        "标注颜色": ["红色", "黄色", "绿色", "蓝色", "白色"],
        "标注粗细": ["1.5", "3", "5", "8"], "文字大小": ["14", "18", "24", "32", "48"],
        "序号大小": ["18", "24", "32", "40"], "马赛克大小": ["4", "8", "12", "20", "32"],
        "贴纸图案": StickerCatalog.items.map(\.title),
        "贴纸大小": ["16", "24", "32", "48", "64", "96"]
    ]

    private static func defaultValue(_ category: String) -> String {
        switch category {
        case "标注颜色": return "红色"
        case "标注粗细": return "3"
        case "文字大小": return "18"
        case "序号大小": return "24"
        case "贴纸图案": return "小花"
        case "贴纸大小": return "16"
        default: return "12"
        }
    }

    @MainActor private static func verifyToolConfiguration(_ image: CGImage) throws {
        let f = SelectionUIFixture(source: image)
        f.root.verificationSelect(CGRect(x: 140, y: 200, width: 440, height: 280))
        for tool in ImageToolsTool.allCases {
            let button = try f.button(tool.rawValue)
            button.performClick(nil)
            var labels = Set(f.configurations.compactMap { $0.accessibilityLabel()?.components(separatedBy: ":").first })
            if let size = f.sizeControl { labels.insert(size.category) }
            try require(labels == configurationLabels[tool], "\(tool) shows incorrect configuration groups: \(labels)")
            try require(f.menus.isEmpty, "\(tool) still uses popup menus")
            try require(button.state == .on && f.configurations.allSatisfy(\.isEnabled)
                        && f.sizeControl?.isEnabled == true, "\(tool) configuration is not active")
            try require((button.layer?.borderWidth ?? 0) == 0, "\(tool) retains a custom active-tool border")
            for category in labels {
                let actual = f.configurations.compactMap { $0.accessibilityLabel() }.filter { $0.hasPrefix(category + ":") }.sorted()
                let values = configurationValues[category] ?? []
                let expected = (category == "贴纸图案" ? Array(values.prefix(actual.count)) : values).map { category + ":" + $0 }.sorted()
                try require(f.sizeControl?.category == category || actual == expected, "\(tool)'s \(category) samples are incomplete")
                if category == "贴纸图案" {
                    let row = f.root.verificationToolbar.rows.last!.filter { !$0.isHidden }
                    let patterns = f.configurations.filter { ($0.accessibilityLabel() ?? "").hasPrefix("贴纸图案:") }
                    try require(patterns.map { $0.identifier!.rawValue } == Array(StickerCatalog.items.prefix(patterns.count).map(\.id)),
                                "Floating picker changed the default prefix order")
                    try require(row.allSatisfy { abs($0.frame.midY - f.sizeControl!.frame.midY) < 0.5 }
                                && f.root.verificationToolbar.bounds.width - 8 - (row.map(\.frame.maxX).max() ?? 0) < 32,
                                "Floating sticker row wraps or leaves room for another sticker")
                }
                let selected = try f.selectedSample(category)
                try require(selected == category + ":" + defaultValue(category), "\(tool)'s \(category) default sample is incorrect")
            }
            for sample in f.configurations {
                try require(isHit(f.hit(at: f.center(of: sample)), inside: sample), "\(tool) configuration sample \(sample.accessibilityLabel() ?? "") frame=\(sample.frame) cannot receive hit testing: \(describes(f.hit(at: f.center(of: sample))))")
            }
            button.performClick(nil)
            try require(f.configurations.isEmpty && f.sizeControl == nil && button.state == .off, "\(tool) configuration remains visible after toggling off")
        }
    }

    @MainActor private static func verifyIndependentConfiguration(_ image: CGImage) throws {
        let f = SelectionUIFixture(source: image)
        f.root.verificationSelect(CGRect(x: 140, y: 200, width: 440, height: 280))
        var choices: [ImageToolsTool: [String: String]] = [:]
        for tool in ImageToolsTool.allCases {
            try f.button(tool.rawValue).performClick(nil)
            var selected: [String: String] = [:]
            for category in configurationLabels[tool] ?? [] {
                let label = try f.selectedSample(category)
                try require(label == category + ":" + defaultValue(category),
                            "\(tool)'s \(category) inherited configuration from another tool")
                let values = configurationValues[category]!
                let defaultIndex = values.firstIndex(of: defaultValue(category))!
                let chosen = category + ":" + values[(defaultIndex + 1) % values.count]
                try f.setParameter(chosen)
                selected[category] = chosen
            }
            choices[tool] = selected
        }
        for tool in ImageToolsTool.allCases {
            try f.button(tool.rawValue).performClick(nil)
            for (category, choice) in choices[tool] ?? [:] {
                let selected = try f.selectedSample(category)
                try require(selected == choice, "\(tool)'s \(category) was not remembered independently")
            }
        }
        try f.button("箭头").performClick(nil)
        // The final pass ends on mosaic; arrow becomes active here and uses 5 screen points = 10 pixels.
        let canvas = f.root.verificationCanvas
        canvas.mouseDown(with: f.mouse(.leftMouseDown, at: CGPoint(x: 220, y: 400)))
        canvas.mouseDragged(with: f.mouse(.leftMouseDragged, at: CGPoint(x: 280, y: 350)))
        canvas.mouseUp(with: f.mouse(.leftMouseUp, at: CGPoint(x: 280, y: 350)))
        try require(canvas.annotations.last?.width == 10, "Configured line width was not scaled from screen points to Retina pixels")
    }

    @MainActor private static func rectangleFixture(_ image: CGImage) throws -> SelectionUIFixture {
        let f = try preparedAnnotationFixture(image, tool: "方框")
        try f.routedGesture(from: CGPoint(x: 220, y: 400), to: CGPoint(x: 340, y: 300))
        try require(f.root.verificationCanvas.annotations.count == 1, "Cannot prepare editable rectangle")
        return f
    }

    @MainActor private static func verifyObjectEditing(_ image: CGImage) throws {
        let f = try rectangleFixture(image)
        let canvas = f.root.verificationCanvas
        let selected = f.root.verificationSelection!
        let original = canvas.annotations[0]
        let size = f.sizeControl!
        size.minus.performClick(nil)
        try require(canvas.annotations[0].width == original.width - 1,
                    "Minus must adjust line width by half a screen point at Retina scale")
        size.plus.performClick(nil)
        try require(canvas.annotations[0].width == original.width, "Plus did not restore line width")
        size.onBegin?()
        for value in [3.5, 4, 4.5] {
            size.slider.doubleValue = value
            size.slider.sendAction(size.slider.action, to: size.slider.target)
        }
        size.onEnd?()
        canvas.undoAnnotation()
        try require(canvas.annotations[0].width == original.width,
                    "One slider drag must undo all intermediate values in one step")
        try f.button("方框").performClick(nil)
        let edge = CGPoint(x: 220, y: 350)
        try require(f.hit(at: edge) === canvas, "Existing object is not editable when its drawing tool is inactive")
        f.root.mouseMoved(with: f.mouse(.mouseMoved, at: edge))
        try require(NSCursor.current == .openHand, "Annotation body must use the move cursor")
        canvas.mouseDown(with: f.mouse(.leftMouseDown, at: edge))
        try require(NSCursor.current == .closedHand, "Dragging annotation body must use the grabbing cursor")
        canvas.mouseUp(with: f.mouse(.leftMouseUp, at: edge))
        try f.routedGesture(from: edge, to: edge)
        let rectangleButton = try f.button("方框")
        try require(canvas.selectedAnnotation?.tool == .rectangle && rectangleButton.state == .on,
                    "Object picking did not synchronize the annotation tool")
        let selectedWidth = try f.selectedSample("标注粗细")
        try require(selectedWidth == "标注粗细:3", "Object picking did not synchronize its width")
        try f.setParameter("标注颜色:蓝色")
        try f.setParameter("标注粗细:8")
        try require(canvas.annotations.count == 1 && canvas.selectedAnnotation?.width == 16
                    && canvas.selectedAnnotation?.color.isEqual(NSColor.systemBlue) == true,
                    "Flat configuration did not update the selected object in place")
        let undoButton = try f.button("撤销")
        try require(canvas.canUndo && undoButton.isEnabled, "Object edits do not enable undo")
        try f.button("撤销").performClick(nil)
        try require(canvas.selectedAnnotation?.width == original.width
                    && canvas.selectedAnnotation?.color.isEqual(NSColor.systemBlue) == true,
                    "Undo did not restore the object's previous width")
        try f.button("撤销").performClick(nil)
        try require(canvas.selectedAnnotation?.color.isEqual(original.color) == true,
                    "Undo did not restore the object's previous color")
        try f.routedGesture(from: edge, to: CGPoint(x: edge.x + 25, y: edge.y + 15))
        let expected = original.points.map { CGPoint(x: $0.x + 50, y: $0.y - 30) }
        try require(canvas.annotations[0].points == expected && f.root.verificationSelection == selected,
                    "Dragging the object moved the screenshot frame or used incorrect Retina coordinates")
        try f.button("撤销").performClick(nil)
        try require(canvas.annotations[0].points == original.points, "Undo did not restore moved object geometry")
        let corner = f.root.convert(original.points[0], from: canvas)
        try require(f.hit(at: corner) === canvas, "Selected annotation control point is not routed to canvas")
        f.root.mouseMoved(with: f.mouse(.mouseMoved, at: corner))
        try require(NSCursor.current == NSCursor.frameResize(position: .topLeft, directions: .all),
                    "Annotation corner must use directional resize cursor")
        try f.routedGesture(from: corner, to: CGPoint(x: corner.x - 20, y: corner.y + 20))
        try require(canvas.annotations[0].rect != original.rect && f.root.verificationSelection == selected,
                    "Annotation control-point drag did not resize the object independently")
        try require(f.errors.isEmpty, "Object editing reported an error")
    }

    @MainActor private static func verifyEditingKeys(_ image: CGImage) throws {
        let f = try rectangleFixture(image)
        let canvas = f.root.verificationCanvas
        let selected = f.root.verificationSelection
        try require(canvas.selectedAnnotation != nil, "New annotation was not selected for editing")
        try require(f.root.handleShortcut(f.key(53, characters: "\u{1b}")), "Esc editing cancellation was not handled")
        try require(canvas.selectedAnnotation == nil && canvas.annotations.count == 1 && f.cancelCount == 0
                    && f.root.verificationSelection == selected,
                    "First Esc cancelled the screenshot instead of annotation editing")
        let edge = CGPoint(x: 220, y: 350)
        try f.routedGesture(from: edge, to: edge)
        try require(f.root.handleShortcut(f.key(51, characters: "\u{7f}")), "Delete was not handled")
        try require(canvas.annotations.isEmpty && f.cancelCount == 0 && f.root.verificationSelection == selected,
                    "Delete failed to remove the selected object or cancelled screenshot selection")
        try f.button("撤销").performClick(nil)
        try require(canvas.annotations.count == 1, "Deleting an annotation cannot be undone")
        try require(f.root.handleShortcut(f.key(117, characters: "\u{f728}")), "Forward Delete was not handled")
        try require(canvas.annotations.isEmpty, "Forward Delete failed to remove the restored object")
        try require(f.root.handleShortcut(f.key(53, characters: "\u{1b}")) && f.cancelCount == 1,
                    "Esc did not cancel screenshot selection after annotation editing ended")
    }

    @MainActor private static func verifyEdgeAnnotationHit(_ image: CGImage) throws {
        let f = try preparedAnnotationFixture(image, tool: "方框")
        let canvas = f.root.verificationCanvas
        let selected = f.root.verificationSelection!
        // Existing ink lies within the screenshot border's hit band, away from all eight frame handles.
        canvas.mouseDown(with: f.mouse(.leftMouseDown, at: CGPoint(x: 142, y: 420)))
        canvas.mouseDragged(with: f.mouse(.leftMouseDragged, at: CGPoint(x: 240, y: 270)))
        canvas.mouseUp(with: f.mouse(.leftMouseUp, at: CGPoint(x: 240, y: 270)))
        try require(canvas.annotations.count == 1, "Cannot prepare annotation at the screenshot edge")
        let original = canvas.annotations[0].points
        try f.button("方框").performClick(nil)
        let edge = CGPoint(x: 142, y: 360)
        try require(f.hit(at: edge) === canvas, "Existing edge annotation hit the screenshot frame instead of canvas")
        try f.routedGesture(from: edge, to: edge)
        try require(canvas.selectedAnnotation?.tool == .rectangle && f.root.verificationSelection == selected,
                    "Clicking edge ink did not select its annotation independently")
        try f.routedGesture(from: edge, to: CGPoint(x: edge.x + 12, y: edge.y + 8))
        let expected = original.map { CGPoint(x: $0.x + 24, y: $0.y - 16) }
        try require(canvas.annotations[0].points == expected && f.root.verificationSelection == selected,
                    "Dragging edge ink moved the screenshot frame instead of the annotation")
    }

    @MainActor private static func verifySelectionControlsExport(_ image: CGImage) throws {
        let f = try rectangleFixture(image)
        let canvas = f.root.verificationCanvas
        try require(canvas.selectedAnnotation != nil, "Cannot prepare selected-object export")
        let withSelection = try canvas.renderedImage()
        try f.button("完成").performClick(nil)
        guard let selectedCrop = f.actions.last?.2 else { throw SelectionUIFailure(description: "Selected object export is missing") }
        canvas.deselectAnnotation()
        let withoutSelection = try canvas.renderedImage()
        try f.button("完成").performClick(nil)
        guard let plainCrop = f.actions.last?.2 else { throw SelectionUIFailure(description: "Deselected object export is missing") }
        try require((withSelection.dataProvider?.data as Data?) == (withoutSelection.dataProvider?.data as Data?),
                    "Rendered image includes selected-object handles or outline")
        try require((selectedCrop.dataProvider?.data as Data?) == (plainCrop.dataProvider?.data as Data?),
                    "Copied crop includes selected-object UI controls")
    }

    @MainActor private static func verifyBackgroundClicks(_ image: CGImage) throws {
        let selected = CGRect(x: 140, y: 200, width: 440, height: 280)
        let outside = CGPoint(x: 60, y: 540)
        for purpose in [CaptureSelectionPurpose.screenshot, .text, .scroll, .record] {
            let f = SelectionUIFixture(source: image, purpose: purpose)
            f.root.verificationSelect(selected)
            if purpose == .screenshot {
                try f.button("方框").performClick(nil)
                let canvas = f.root.verificationCanvas
                canvas.mouseDown(with: f.mouse(.leftMouseDown, at: CGPoint(x: 220, y: 400)))
                canvas.mouseDragged(with: f.mouse(.leftMouseDragged, at: CGPoint(x: 280, y: 350)))
                canvas.mouseUp(with: f.mouse(.leftMouseUp, at: CGPoint(x: 280, y: 350)))
                try require(canvas.annotations.count == 1, "Cannot prepare background-click annotation")
            }
            f.gesture(from: outside, to: outside)
            try require(f.root.verificationSelection == selected && f.actions.isEmpty,
                        "\(purpose) single background click discarded or confirmed selection")
            if purpose == .screenshot {
                try require(f.root.verificationCanvas.annotations.count == 1, "Single background click discarded annotations")
            }
            try f.doubleClick(at: outside)
            try require(f.actions.count == 1 && f.actions[0].0 == purpose.primaryAction && f.actions[0].1 == selected,
                        "\(purpose) background double click did not confirm the original selection")
            if purpose == .record {
                try require(f.actions[0].2 == nil, "Live confirmation exported frozen pixels")
            } else {
                let crop = SelectionGeometry.pixelRect(selected, in: f.root.bounds, imageSize: CGSize(width: image.width, height: image.height))
                try require(f.actions[0].2?.width == Int(crop.width) && f.actions[0].2?.height == Int(crop.height),
                            "Background confirmation exported a different crop")
                if purpose == .screenshot, let exported = f.actions[0].2 {
                    let mark = try rgba(exported, x: 440 - Int(crop.minX), y: 420 - Int(crop.minY))
                    try require(mark[0] > 0.8 && mark[1] < 0.35, "Background confirmation discarded the original annotations")
                }
            }
        }
    }

    @MainActor private static func verifyBackgroundDrag(_ image: CGImage) throws {
        let f = try preparedAnnotationFixture(image, tool: "序号")
        let selected = CGRect(x: 140, y: 200, width: 440, height: 280)
        f.root.verificationCanvas.mouseDown(with: f.mouse(.leftMouseDown, at: CGPoint(x: 250, y: 340)))
        try require(f.root.verificationCanvas.annotations.count == 1, "Cannot prepare outside-drag annotation")
        let start = CGPoint(x: 40, y: 550), tiny = CGPoint(x: 42, y: 550), end = CGPoint(x: 110, y: 510)
        f.root.mouseDown(with: f.mouse(.leftMouseDown, at: start))
        try require(f.root.verificationSelection == selected, "Background mouse down discarded selection before dragging")
        f.root.mouseDragged(with: f.mouse(.leftMouseDragged, at: tiny))
        try require(f.root.verificationSelection == selected, "Less-than-four-point movement replaced selection")
        try require(f.root.verificationCanvas.annotations.count == 1, "Less-than-four-point movement discarded annotations")
        f.root.mouseDragged(with: f.mouse(.leftMouseDragged, at: end))
        f.root.mouseUp(with: f.mouse(.leftMouseUp, at: end))
        try require(f.root.verificationSelection == CGRect(x: 40, y: 510, width: 70, height: 40),
                    "Background drag did not create a fresh selection after the threshold")
        try require(f.root.verificationCanvas.annotations.isEmpty, "Fresh background-drag selection retained old annotations")
        try require(f.actions.isEmpty, "Background drag unexpectedly completed selection")
    }

    @MainActor private static func verifyCrossScreenBackground(_ image: CGImage) throws {
        let selected = CGRect(x: 140, y: 200, width: 440, height: 280)
        let outside = CGPoint(x: 60, y: 540)
        for purpose in [CaptureSelectionPurpose.screenshot, .text, .scroll, .record] {
            let a = SelectionUIFixture(source: image, purpose: purpose)
            let b = SelectionUIFixture(source: image, candidates: [CGRect(x: 40, y: 100, width: 700, height: 420)], purpose: purpose)
            let coordinator = RegionSelector()
            coordinator.verificationAttachViews([a.root, b.root])
            a.root.verificationSelect(selected)
            b.gesture(from: outside, to: outside)
            try require(a.root.verificationSelection == selected && b.root.verificationSelection == nil,
                        "\(purpose) clicking another display discarded the existing selection")
            try b.doubleClick(at: outside)
            try require(a.actions.count == 1 && a.actions[0].0 == purpose.primaryAction && a.actions[0].1 == selected && b.actions.isEmpty,
                        "\(purpose) double clicking another display did not confirm the selected display")
            if purpose == .record {
                try require(a.actions[0].2 == nil, "Live cross-screen confirmation returned frozen pixels")
            } else {
                try require(a.actions[0].2?.width == 880 && a.actions[0].2?.height == 560,
                            "Cross-screen confirmation exported another display's pixels")
            }
            a.root.verificationSelect(selected)
            b.gesture(from: outside, to: CGPoint(x: 120, y: 500))
            try require(a.root.verificationSelection == nil && b.root.verificationSelection == CGRect(x: 60, y: 500, width: 60, height: 40),
                        "\(purpose) dragging another display did not transfer selection after the threshold")
        }
    }

    @MainActor private static func verifyToolbar(_ image: CGImage) throws {
        let f = SelectionUIFixture(source: image)
        f.gesture(from: CGPoint(x: 140, y: 240), to: CGPoint(x: 480, y: 470))
        let before = f.root.verificationToolbar.frame
        f.gesture(from: CGPoint(x: 310, y: 355), to: CGPoint(x: 450, y: 420))
        try require(before != f.root.verificationToolbar.frame, "Toolbar did not follow moved selection")
        for title in ["整屏", "完成"] {
            let button = try f.button(title)
            let point = f.center(of: button)
            let hit = f.hit(at: point)
            try require(isHit(hit, inside: button), "\(title) at root point \(point) hit \(describes(hit)); expected actual button")
        }
    }

    @MainActor private static func verifyCandidate(_ image: CGImage) throws {
        let candidate = CGRect(x: 120, y: 200, width: 440, height: 280)
        let f = SelectionUIFixture(source: image, candidates: [candidate])
        let point = CGPoint(x: candidate.midX, y: candidate.midY)
        let initialWindowButton = try f.button("窗口")
        try require(f.root.verificationMode == .window && initialWindowButton.state == .on,
                    "Screenshot does not start with the window mode selected")
        f.root.mouseMoved(with: f.mouse(.mouseMoved, at: point))
        try require(f.root.verificationHover == candidate && f.root.verificationSelection == nil,
                    "Default pointer movement did not highlight the window without committing it")
        try f.routedGesture(from: point, to: point)
        try require(f.root.verificationSelection == candidate && f.root.verificationCommittedMode == .window,
                    "Default click did not lock candidate window bounds")
        try require(f.actions.isEmpty, "Candidate selection immediately completed an action")
        for explicitWindow in [false, true] {
            let drag = SelectionUIFixture(source: image, candidates: [candidate])
            if explicitWindow { try drag.button("窗口").performClick(nil) }
            let end = CGPoint(x: point.x + 100, y: point.y + 80)
            try drag.routedGesture(from: point, to: end)
            try require(drag.root.verificationSelection == CGRect(x: point.x, y: point.y, width: 100, height: 80)
                && drag.root.verificationMode == .rectangle && drag.root.verificationCommittedMode == .rectangle,
                "Default or explicit window mode required another mode click before rectangle dragging")
            try require(drag.actions.isEmpty, "Direct rectangle drag unexpectedly exported")
        }
        let free = SelectionUIFixture(source: image, candidates: [candidate])
        try free.button("框选").performClick(nil)
        free.root.mouseMoved(with: free.mouse(.mouseMoved, at: point))
        try free.routedGesture(from: point, to: point)
        try require(free.root.verificationSelection == nil && free.root.verificationHover == nil,
                    "Explicit rectangle mode still snaps to candidate windows")
    }

    @MainActor private static func verifyScrollBodySelection(_ image: CGImage) throws {
        let candidate = CGRect(x: 120, y: 200, width: 440, height: 280)
        let point = CGPoint(x: candidate.midX, y: candidate.midY)
        let body = CGRect(x: 150, y: 230, width: 360, height: 180)
        let scroll = SelectionUIFixture(source: image, candidates: [candidate], purpose: .scroll)
        scroll.root.mouseMoved(with: scroll.mouse(.mouseMoved, at: point))
        try scroll.routedGesture(from: point, to: point)
        try require(scroll.root.verificationHover == nil && scroll.root.verificationSelection == nil
            && scroll.actions.isEmpty, "Default scroll click still selects or starts the whole window")
        try require(scroll.root.verificationEmptyHint == "拖动框选范围 · W 选择窗口 · Esc 取消",
            "Default scroll guidance omits free selection or the explicit window entry")
        try scroll.routedGesture(from: body.origin, to: CGPoint(x: body.maxX, y: body.maxY))
        try require(scroll.root.verificationSelection == body && scroll.actions.isEmpty,
                    "Scroll drag did not preserve the exact body rectangle for confirmation")
        try scroll.button("确认").performClick(nil)
        try require(scroll.actions.count == 1 && scroll.actions[0].0 == .scroll
            && scroll.actions[0].1 == body && scroll.actions[0].2?.width == 720
            && scroll.actions[0].2?.height == 360,
            "Body confirmation changed the rectangle or invoked another capture purpose")

        let explicit = SelectionUIFixture(source: image, candidates: [candidate], purpose: .scroll)
        try require(explicit.root.handleShortcut(explicit.key(13, characters: "w")),
                    "Explicit scroll window shortcut was removed")
        try require(explicit.root.verificationEmptyHint == "单击选择窗口 · R 自由框选 · Esc 取消",
                    "Explicit window guidance omits the route back to free selection")
        explicit.root.mouseMoved(with: explicit.mouse(.mouseMoved, at: point))
        try require(explicit.root.verificationHover == candidate,
                    "Explicit scroll window selection no longer highlights its candidate")
        try explicit.routedGesture(from: point, to: point)
        try require(explicit.root.verificationSelection == candidate && explicit.actions.isEmpty,
                    "Explicit scroll window click no longer selects the window for confirmation")
        try require(explicit.root.handleShortcut(explicit.key(15, characters: "r")),
                    "Scroll window mode cannot return to body selection")
        explicit.root.mouseMoved(with: explicit.mouse(.mouseMoved, at: point))
        try explicit.routedGesture(from: point, to: point)
        try require(explicit.root.verificationHover == nil && explicit.root.verificationSelection == nil,
                    "Returning to body selection still snaps to a window")

        for purpose in [CaptureSelectionPurpose.text, .record] {
            let other = SelectionUIFixture(source: image, candidates: [candidate], purpose: purpose)
            other.root.mouseMoved(with: other.mouse(.mouseMoved, at: point))
            try require(other.root.verificationHover == candidate,
                        "\(purpose) initial automatic window hover changed")
            try other.routedGesture(from: point, to: point)
            try require(other.root.verificationSelection == candidate && other.actions.isEmpty,
                        "\(purpose) initial click no longer selects the whole window")
        }
    }

    @MainActor private static func verifyAutomaticDragPreservation(_ image: CGImage) throws {
        let candidate = CGRect(x: 140, y: 200, width: 440, height: 280)
        let start = CGPoint(x: 40, y: 540), tiny = CGPoint(x: 50, y: 535)
        let fresh = SelectionUIFixture(source: image, candidates: [candidate])
        try fresh.routedGesture(from: start, to: tiny)
        try require(fresh.root.verificationMode == .window && !fresh.root.verificationPendingModeChange
            && fresh.root.verificationSelection == nil, "Tiny initial drag changed the default mode or committed a range")
        let f = SelectionUIFixture(source: image, candidates: [candidate])
        try f.routedGesture(from: CGPoint(x: 300, y: 330), to: CGPoint(x: 300, y: 330))
        try f.button("方框").performClick(nil)
        try f.routedGesture(from: CGPoint(x: 220, y: 400), to: CGPoint(x: 280, y: 350))
        let canvas = f.root.verificationCanvas
        try require(canvas.annotations.count == 1, "Cannot prepare annotated window selection")
        try f.routedGesture(from: start, to: tiny)
        try require(f.root.verificationSelection == candidate && f.root.verificationMode == .window
            && f.root.verificationCommittedMode == .window && !f.root.verificationPendingModeChange
            && canvas.annotations.count == 1, "Tiny automatic drag lost the committed window, mode or annotation")
        try f.button("框选").performClick(nil)
        try f.routedGesture(from: start, to: tiny)
        try require(f.root.verificationSelection == candidate && f.root.verificationMode == .rectangle
            && f.root.verificationPendingModeChange && canvas.annotations.count == 1,
            "Tiny pending drag failed to restore pending mode and the old result")
        try f.button("窗口").performClick(nil)
        guard let receiver = f.hit(at: start) else { throw SelectionUIFailure(description: "No drag receiver") }
        receiver.mouseDown(with: f.mouse(.leftMouseDown, at: start))
        let end = CGPoint(x: 110, y: 500)
        receiver.mouseDragged(with: f.mouse(.leftMouseDragged, at: end))
        try require(f.root.verificationSelection == candidate && canvas.annotations.count == 1
            && f.root.verificationMode == .rectangle && f.root.verificationPendingModeChange,
            "Rectangle preview replaced the old range/annotation before a valid mouse release")
        receiver.mouseUp(with: f.mouse(.leftMouseUp, at: end))
        try require(f.root.verificationSelection == CGRect(x: 40, y: 500, width: 70, height: 40)
            && f.root.verificationCommittedMode == .rectangle && !f.root.verificationPendingModeChange
            && canvas.annotations.isEmpty && f.actions.isEmpty, "Valid direct drag failed to commit a clean rectangle")
    }

    @MainActor private static func verifyInsideDoubleClicks(_ image: CGImage) throws {
        let selected = CGRect(x: 140, y: 200, width: 440, height: 280)
        let blank = CGPoint(x: 430, y: 310)
        for purpose in [CaptureSelectionPurpose.screenshot, .text, .scroll, .record] {
            let f = SelectionUIFixture(source: image, purpose: purpose)
            f.root.verificationSelect(selected)
            try f.doubleClick(at: blank)
            try require(f.actions.count == 1 && f.actions[0].0 == purpose.primaryAction && f.actions[0].1 == selected,
                        "Inside blank double click did not complete the unchanged range for \(purpose)")
        }
        let drawing = try preparedAnnotationFixture(image, tool: "方框")
        try require(drawing.hit(at: blank) === drawing.root.verificationCanvas, "Active-tool blank does not route to canvas")
        try drawing.doubleClick(at: blank)
        try require(drawing.actions.count == 1 && drawing.root.verificationCanvas.annotations.isEmpty,
                    "Canvas blank double click failed to export or added a spurious annotation")

        let object = try rectangleFixture(image)
        let original = object.root.verificationCanvas.annotations[0].points
        try object.doubleClick(at: CGPoint(x: 220, y: 350))
        try require(object.actions.isEmpty && object.root.verificationCanvas.selectedAnnotation?.tool == .rectangle,
                    "Double clicking existing ink exported instead of selecting it")
        let control = object.root.convert(original[0], from: object.root.verificationCanvas)
        try object.doubleClick(at: control)
        try require(object.actions.isEmpty && object.root.verificationCanvas.annotations[0].points == original,
                    "Double clicking annotation control exported or changed geometry")
        try object.doubleClick(at: SelectionHandle.topRight.point(in: selected))
        try require(object.actions.isEmpty && object.root.verificationSelection == selected,
                    "Double clicking a screenshot resize handle completed the screenshot")

        let text = try preparedAnnotationFixture(image, tool: "文字")
        let canvas = text.root.verificationCanvas
        try text.routedGesture(from: CGPoint(x: 220, y: 400), to: CGPoint(x: 220, y: 400))
        guard let input = canvas.subviews.compactMap({ $0 as? NSTextField }).first else {
            throw SelectionUIFailure(description: "Cannot prepare text for double-click editing")
        }
        input.stringValue = "双击编辑文字"; input.currentEditor()?.string = input.stringValue
        canvas.finishTextEditing()
        guard let annotation = canvas.annotations.first else { throw SelectionUIFailure(description: "Text was not committed") }
        let size = (annotation.text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: annotation.fontSize, weight: .medium)])
        let middle = CGPoint(x: annotation.points[0].x + size.width / 2, y: annotation.points[0].y + size.height / 2)
        try text.doubleClick(at: text.root.convert(middle, from: canvas))
        try require(text.actions.isEmpty && canvas.subviews.contains { $0 is NSTextField },
                    "Double clicking existing text exported instead of opening its editor")
        canvas.finishTextEditing()
    }

    @MainActor private static func verifyGestures(_ image: CGImage) throws {
        let f = SelectionUIFixture(source: image)
        let selected = CGRect(x: 170, y: 230, width: 300, height: 220)
        f.gesture(from: selected.origin, to: CGPoint(x: selected.maxX, y: selected.maxY))
        try require(f.root.verificationSelection == selected, "Mouse release removed or changed dragged selection")
        f.gesture(from: CGPoint(x: selected.midX, y: selected.midY),
                  to: CGPoint(x: selected.midX + 65, y: selected.midY + 40))
        try require(f.root.verificationSelection == selected.offsetBy(dx: 65, dy: 40), "Dragging inside did not move selection")
        for handle in SelectionHandle.allCases {
            f.root.verificationSelect(selected)
            let start = handle.point(in: selected)
            let end = CGPoint(x: start.x + 12, y: start.y + 17)
            f.gesture(from: start, to: end)
            let expected = SelectionGeometry.resize(selected, handle: handle, to: end, within: f.root.bounds).integral
            try require(f.root.verificationSelection == expected, "\(handle) resize mismatch: \(String(describing: f.root.verificationSelection))")
        }
        try require(f.actions.isEmpty && f.errors.isEmpty, "Selection editing completed an action or raised an error")
    }

    @MainActor private static func preparedAnnotationFixture(_ image: CGImage, tool: String) throws -> SelectionUIFixture {
        let f = SelectionUIFixture(source: image)
        f.root.verificationSelect(CGRect(x: 140, y: 200, width: 440, height: 280))
        try f.button(tool).performClick(nil)
        return f
    }

    @MainActor private static func verifyCanvasHit(_ image: CGImage) throws {
        let f = try preparedAnnotationFixture(image, tool: "方框")
        let hit = f.hit(at: CGPoint(x: 240, y: 380))
        try require(hit === f.root.verificationCanvas, "Annotation interior hit \(describes(hit)); expected ImageToolsCanvas")
    }

    @MainActor private static func verifyInlineText(_ image: CGImage) throws {
        let f = try preparedAnnotationFixture(image, tool: "文字")
        let canvas = f.root.verificationCanvas
        canvas.mouseDown(with: f.mouse(.leftMouseDown, at: CGPoint(x: 220, y: 400)))
        guard let input = canvas.subviews.compactMap({ $0 as? NSTextField }).first else {
            throw SelectionUIFailure(description: "Text tool did not create an inline input")
        }
        let hit = f.hit(at: f.center(of: input))
        try require(isHit(hit, inside: input), "Inline text center hit \(describes(hit)); expected NSTextField")
        try require(input.placeholderString == nil, "Text annotation must not show placeholder instructions")
        input.stringValue = "保留输入 Patch"
        input.currentEditor()?.string = input.stringValue
        canvas.finishTextEditing()
        try require(canvas.annotations.last?.text == "保留输入 Patch", "Finishing editing discarded typed text")
        canvas.mouseDown(with: f.mouse(.leftMouseDown, at: CGPoint(x: 250, y: 340)))
        guard let pending = canvas.subviews.compactMap({ $0 as? NSTextField }).first,
              let editor = pending.currentEditor() as? NSTextView else {
            throw SelectionUIFailure(description: "Inline input has no field editor")
        }
        try require(!f.root.handleShortcut(f.key(53, characters: "\u{1b}")), "Selection captured Esc while editing text")
        try require(canvas.control(pending, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))), "Text Esc was not handled")
        try require(canvas.annotations.count == 1 && canvas.subviews.isEmpty && f.cancelCount == 0,
                    "Text Esc cancelled the entire selection or added unwanted text")

        // Marked text is an IME composition, not yet a controlTextDidChange event.
        // Reproduce at both middle and lower edges of the screenshot selection.
        for y: CGFloat in [440, 240, 205] {
            let probe = try preparedAnnotationFixture(image, tool: "文字")
            let c = probe.root.verificationCanvas
            c.mouseDown(with: probe.mouse(.leftMouseDown, at: CGPoint(x: 220, y: y)))
            let field = c.subviews.compactMap { $0 as? NSTextField }.first!
            let editor = field.currentEditor() as! NSTextView
            for character in "这是已确认的文字" {
                editor.insertText(String(character), replacementRange: editor.selectedRange())
            }
            editor.setMarkedText("正在输入拼音文字", selectedRange: NSRange(location: 8, length: 0), replacementRange: editor.selectedRange())
            editor.layoutManager?.ensureLayout(for: editor.textContainer!)
            let used = editor.layoutManager!.usedRect(for: editor.textContainer!)
            try require(used.height < field.font!.pointSize * 1.5,
                        "IME composition wraps early at y=\(y): field=\(field.frame), used=\(used)")
            let editingWidth = field.frame.width
            editor.unmarkText()
            c.finishTextEditing()
            let text = c.annotations.last!
            let naturalWidth = ceil((text.text as NSString).size(withAttributes: [.font: field.font!]).width)
            try require(abs(editingWidth - naturalWidth) <= 1,
                        "IME input and committed text use different widths at y=\(y)")
        }

        let long = try preparedAnnotationFixture(image, tool: "文字")
        let longCanvas = long.root.verificationCanvas
        longCanvas.mouseDown(with: long.mouse(.leftMouseDown, at: CGPoint(x: 220, y: 400)))
        let field = longCanvas.subviews.compactMap { $0 as? NSTextField }.first!
        let initialWidth = field.frame.width
        let text = "长文本应当在输入和完成后保持相同的换行位置。" + String(repeating: "继续输入文字进行测试。", count: 7)
        field.stringValue = text; field.currentEditor()?.string = text
        longCanvas.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        try require(!field.isBordered && !field.isBezeled && !field.drawsBackground,
                    "Inline editing still has a border or opaque background")
        try require(field.frame.width > initialWidth && field.frame.height > field.font!.pointSize * 2,
                    "Long text does not expand and wrap during editing")
        func saveTextPreview(_ name: String) throws {
            guard let directory = ProcessInfo.processInfo.environment["PATCH_TEXT_PREVIEW_DIR"] else { return }
            long.root.layoutSubtreeIfNeeded()
            let bitmap = longCanvas.bitmapImageRepForCachingDisplay(in: longCanvas.bounds)!
            longCanvas.cacheDisplay(in: longCanvas.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
        }
        let editingFrame = field.frame
        let fieldEditor = field.currentEditor() as! NSTextView
        fieldEditor.setSelectedRange(NSRange(location: fieldEditor.string.utf16.count, length: 0))
        try require(longCanvas.control(field, textView: fieldEditor,
            doCommandBy: #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))), "Shift-Enter did not insert a newline")
        try require(fieldEditor.string.contains("\n"), "Explicit newline was lost")
        let committedText = fieldEditor.string
        fieldEditor.setSelectedRange(NSRange(location: 0, length: 0))
        try saveTextPreview("text-editing.png")
        longCanvas.finishTextEditing()
        try require(longCanvas.annotations.last?.text == committedText
                    && longCanvas.annotations.last?.points.first == editingFrame.origin
                    && (longCanvas.annotations.last?.textWrapWidth ?? 0) >= editingFrame.width,
                    "Commit lost the full text, anchor or wrap width")
        longCanvas.deselectAnnotation()
        try saveTextPreview("text-completed.png")
        longCanvas.undoAnnotation()
        try require(longCanvas.annotations.isEmpty, "Multiline text cannot be undone as one operation")
    }

    private static func rgba(_ image: CGImage, x: Int, y: Int) throws -> [CGFloat] {
        guard let c = NSBitmapImageRep(cgImage: image).colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
            throw SelectionUIFailure(description: "Cannot read pixel (\(x), \(y))")
        }
        return [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent]
    }

    @MainActor private static func verifyRetinaExport(_ image: CGImage) throws {
        let f = try preparedAnnotationFixture(image, tool: "方框")
        let canvas = f.root.verificationCanvas
        try require(canvas.frame.size == CGSize(width: 800, height: 600) && canvas.bounds.size == CGSize(width: 1600, height: 1200),
                    "Canvas does not retain separate point frame and pixel bounds")
        let start = CGPoint(x: 220, y: 400), end = CGPoint(x: 280, y: 350)
        canvas.mouseDown(with: f.mouse(.leftMouseDown, at: start))
        canvas.mouseDragged(with: f.mouse(.leftMouseDragged, at: end))
        canvas.mouseUp(with: f.mouse(.leftMouseUp, at: end))
        try require(canvas.annotations.first?.points == [CGPoint(x: 440, y: 400), CGPoint(x: 560, y: 500)],
                    "Retina annotation events did not map to top-left image pixels")
        try f.button("完成").performClick(nil)
        guard let selection = f.root.verificationSelection, let exported = f.actions.last?.2 else {
            throw SelectionUIFailure(description: "Copy did not return a cropped image")
        }
        let crop = SelectionGeometry.pixelRect(selection, in: f.root.bounds,
            imageSize: CGSize(width: image.width, height: image.height))
        try require(exported.width == Int(crop.width) && exported.height == Int(crop.height), "Export crop dimensions are incorrect")
        for (x, y) in [(20, 20), (Int(crop.width) - 20, Int(crop.height) - 20)] {
            let before = try rgba(image, x: Int(crop.minX) + x, y: Int(crop.minY) + y)
            let after = try rgba(exported, x: x, y: y)
            try require(zip(before, after).allSatisfy { abs($0 - $1) < 0.015 }, "Export changed untouched source pixels")
        }
        let mark = try rgba(exported, x: 440 - Int(crop.minX), y: 420 - Int(crop.minY))
        try require(mark[0] > 0.8 && mark[1] < 0.35, "Annotation stroke is not at its displayed Retina coordinate")
        canvas.clearAnnotations()
        // An entire-screen export includes the toolbar's displayed position; those pixels must remain source-only.
        try f.button("整屏").performClick(nil)
        try f.button("完成").performClick(nil)
        guard let full = f.actions.last?.2 else { throw SelectionUIFailure(description: "Missing full-screen export") }
        let toolbarPixel = canvas.convert(f.center(of: try f.button("完成")), from: f.root)
        let x = min(full.width - 1, max(0, Int(toolbarPixel.x)))
        let y = min(full.height - 1, max(0, Int(toolbarPixel.y)))
        let sourcePixel = try rgba(image, x: x, y: y), outputPixel = try rgba(full, x: x, y: y)
        try require(zip(sourcePixel, outputPixel).allSatisfy { abs($0 - $1) < 0.015 }, "Export includes toolbar raster pixels")
    }

    @MainActor private static func verifyShortcuts(_ image: CGImage) throws {
        for (purpose, action) in [(CaptureSelectionPurpose.screenshot, CaptureSelectionAction.copy), (.text, .ocr), (.scroll, .scroll), (.record, .record)] {
            let f = SelectionUIFixture(source: image, purpose: purpose)
            if purpose.supportsFullScreen {
                try require(f.root.handleShortcut(f.key(3, characters: "f")), "F was not handled")
                try require(f.root.verificationSelection == f.root.bounds && f.actions.isEmpty, "F did not select the current screen only")
            } else {
                try require(!f.root.handleShortcut(f.key(3, characters: "f")), "Dedicated entry retains hidden F")
                f.root.verificationSelect(CGRect(x: 140, y: 200, width: 440, height: 280))
            }
            try require(f.root.handleShortcut(f.key(36, characters: "\r")), "Enter was not handled")
            try require(f.actions.count == 1 && f.actions[0].0 == action, "Enter did not invoke the purpose's primary action")
            if action == .record { try require(f.actions[0].2 == nil, "Live action unexpectedly exported frozen pixels") }
            try require(f.root.handleShortcut(f.key(53, characters: "\u{1b}")) && f.cancelCount == 1, "Esc did not cancel the selection")
        }
    }

    @MainActor private static func verifyCrossScreenShortcuts(_ image: CGImage) throws {
        let a = SelectionUIFixture(source: image)
        let b = SelectionUIFixture(source: image)
        let coordinator = RegionSelector()
        coordinator.verificationAttachViews([a.root, b.root])
        let selected = CGRect(x: 140, y: 200, width: 440, height: 280)
        a.root.verificationSelect(selected)
        b.window.makeKey()
        b.window.makeFirstResponder(b.root)
        let operations: [(UInt16, String, NSEvent.ModifierFlags, CaptureSelectionAction)] = [
            (36, "\r", [], .copy), (8, "c", .command, .copy), (1, "s", .command, .save)
        ]
        for (code, characters, modifiers, expected) in operations {
            let previous = a.actions.count
            let event = b.key(code, characters: characters, modifiers: modifiers)
            try require(b.window.performKeyEquivalent(with: event), "Cross-screen shortcut was not handled")
            try require(a.actions.count == previous + 1 && a.actions.last?.0 == expected && b.actions.isEmpty,
                        "Cross-screen \(characters.debugDescription) did not target the selected display")
            try require(a.actions.last?.1 == selected, "Cross-screen operation changed selection bounds")
        }
        try a.button("方框").performClick(nil)
        let canvas = a.root.verificationCanvas
        canvas.mouseDown(with: a.mouse(.leftMouseDown, at: CGPoint(x: 220, y: 400)))
        canvas.mouseDragged(with: a.mouse(.leftMouseDragged, at: CGPoint(x: 280, y: 350)))
        canvas.mouseUp(with: a.mouse(.leftMouseUp, at: CGPoint(x: 280, y: 350)))
        try require(canvas.annotations.count == 1, "Cannot prepare cross-screen undo annotation")
        b.window.makeFirstResponder(b.root)
        try require(b.window.performKeyEquivalent(with: b.key(6, characters: "z", modifiers: .command)), "Cross-screen undo was not handled")
        try require(canvas.annotations.isEmpty && a.root.verificationSelection == selected, "Cross-screen undo did not target selection's annotations")
        try require(b.window.performKeyEquivalent(with: b.key(3, characters: "f")), "Current-screen F was not handled")
        try require(b.root.verificationSelection == b.root.bounds && a.root.verificationSelection == nil,
                    "F did not move full-screen selection to the current display")
    }

    @MainActor private static func verifyCrossScreenEditingKeys(_ image: CGImage) throws {
        let a = try rectangleFixture(image)
        let b = SelectionUIFixture(source: image)
        let coordinator = RegionSelector()
        coordinator.verificationAttachViews([a.root, b.root])
        let canvas = a.root.verificationCanvas
        let selected = a.root.verificationSelection
        b.window.makeKey()
        b.window.makeFirstResponder(b.root)
        try require(b.window.performKeyEquivalent(with: b.key(51, characters: "\u{7f}")),
                    "Delete from another display was not handled")
        try require(canvas.annotations.isEmpty && a.root.verificationSelection == selected
                    && b.root.verificationSelection == nil && a.cancelCount == 0 && b.cancelCount == 0,
                    "Cross-screen Delete did not remove the selected display's annotation")
        try require(b.window.performKeyEquivalent(with: b.key(6, characters: "z", modifiers: .command)),
                    "Cross-screen deleted annotation undo was not handled")
        try require(canvas.annotations.count == 1 && canvas.selectedAnnotation != nil,
                    "Cross-screen Delete could not be undone with its object selection restored")
        try require(b.window.performKeyEquivalent(with: b.key(53, characters: "\u{1b}")),
                    "First cross-screen Esc was not handled")
        try require(canvas.selectedAnnotation == nil && canvas.annotations.count == 1
                    && a.root.verificationSelection == selected && a.cancelCount == 0 && b.cancelCount == 0,
                    "First cross-screen Esc cancelled the screenshot instead of annotation editing")
        try require(b.window.performKeyEquivalent(with: b.key(53, characters: "\u{1b}")),
                    "Second cross-screen Esc was not handled")
        try require(a.cancelCount == 1 && b.cancelCount == 0,
                    "Second cross-screen Esc did not cancel the selected display's screenshot")
    }

    @MainActor private static func savePreview(_ f: SelectionUIFixture, output: URL, name: String) throws {
        f.root.layoutSubtreeIfNeeded()
        guard let bitmap = f.root.bitmapImageRepForCachingDisplay(in: f.root.bounds) else {
            throw SelectionUIFailure(description: "Cannot allocate view preview bitmap")
        }
        f.root.cacheDisplay(in: f.root.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw SelectionUIFailure(description: "Cannot encode view preview")
        }
        let path = output.appendingPathComponent(name)
        try data.write(to: path, options: .atomic)
        print("INFO: preview saved at \(path.path)")
    }

    @MainActor private static func previews(output: URL) throws {
        let image = DemoImage.make()
        let selected = CGRect(x: 60, y: 185, width: 830, height: 340)
        let screenshot = SelectionUIFixture(source: image, size: CGSize(width: 960, height: 600))
        screenshot.root.verificationSelect(selected)
        try screenshot.button("箭头").performClick(nil)
        let arrowWidth = try screenshot.selectedSample("标注粗细")
        try require(arrowWidth == "标注粗细:3", "Arrow preview does not use the default stroke configuration")
        try savePreview(screenshot, output: output, name: "selection-preview.png")
        let text = SelectionUIFixture(source: image, size: CGSize(width: 960, height: 600))
        text.root.verificationSelect(selected)
        try text.button("文字").performClick(nil)
        let textSize = try text.selectedSample("文字大小")
        try require(textSize == "文字大小:18", "Text preview does not show default font configuration")
        try savePreview(text, output: output, name: "selection-text-preview.png")
        let mosaic = SelectionUIFixture(source: image, size: CGSize(width: 960, height: 600))
        mosaic.root.verificationSelect(selected)
        try mosaic.button("马赛克").performClick(nil)
        try savePreview(mosaic, output: output, name: "selection-mosaic-preview.png")
        let object = SelectionUIFixture(source: image, size: CGSize(width: 960, height: 600))
        object.root.verificationSelect(selected)
        try object.button("方框").performClick(nil)
        try object.routedGesture(from: CGPoint(x: 74, y: 455), to: CGPoint(x: 245, y: 515))
        try require(object.root.verificationCanvas.selectedAnnotation != nil, "Selected-object preview has no selected annotation")
        try savePreview(object, output: output, name: "selection-object-preview.png")
        let recording = SelectionUIFixture(source: image, size: CGSize(width: 960, height: 600), purpose: .record,
                                          toolbarArea: CGRect(x: 0, y: 60, width: 960, height: 510))
        try recording.button("整屏").performClick(nil)
        try savePreview(recording, output: output, name: "selection-record-fullscreen-preview.png")
    }
}
