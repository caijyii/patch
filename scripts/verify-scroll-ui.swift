// Concatenated after ScrollCapture.swift. Never invokes start, capture, event taps or scroll posting.
import Darwin

private struct ScrollUIFailure: Error, CustomStringConvertible {
    let description: String
}

private struct ScrollUIUnavailable: Error, CustomStringConvertible {
    let description: String
}

extension ScrollCaptureCoordinator {
    fileprivate func verificationPresent(_ region: CaptureRegion) {
        cancel()
        self.region = region
        mode = .manual
        state = .preparing
        presentHUD(region: region)
    }
    fileprivate var verificationPanel: NSPanel? { panel }
    fileprivate var verificationEditor: InlineAnnotationView? { inlineEditor }
    fileprivate var verificationOutline: NSWindow? { outline }
    fileprivate var verificationToolbar: SelectionToolbar { toolbar }
    fileprivate var verificationHUD: NSView? { panel?.contentView }
    fileprivate var verificationHasFirstFrame: Bool { hasFirstFrame }
    fileprivate var verificationHeight: Int { imageHeight }
    fileprivate var verificationRunning: Bool { state == .running }
    fileprivate var verificationFinishing: Bool { state == .finishing }
    fileprivate var verificationTask: Task<Void, Never>? { task }
    fileprivate func verificationWaitForCompletion() async { await task?.value }
    fileprivate var verificationRecovering: Bool { state == .recovering }
    fileprivate var verificationRun: UUID { run }
    fileprivate func verificationCaptureActive(_ operation: UUID) -> Bool {
        isCapturing(token: session, operation: operation)
    }
    fileprivate var verificationManual: Bool { mode == .manual }
    fileprivate var verificationPreview: ScrollCapturePreview? { previewView.preview }
    fileprivate var verificationPreviewVisible: Bool { !previewView.isHidden }
    fileprivate var verificationMask: ScrollOutlineView? { outline?.contentView as? ScrollOutlineView }
    fileprivate func verificationPreviewCount() async -> Int { await processor.previewGenerationCount }
    fileprivate func verificationSetRunning(automatic: ScrollStitcher.Direction? = nil) {
        mode = automatic.map { .automatic($0) } ?? .manual
        state = .running
        setStatus(mode.label)
    }
    fileprivate func verificationPause() { pause("已暂停 · 可继续或完成") }
    fileprivate func verificationLimit() { apply(.limitReached("test limit"), width: imageWidth) }
    fileprivate func verificationReject(_ reason: String) { apply(.paused(reason), width: imageWidth) }
    fileprivate func verificationStopAutomatic() -> Bool { stopAutomatic() }
    fileprivate func verificationAccept(_ image: CGImage) async {
        let (update, preview) = await processor.append(image)
        apply(update, width: image.width, preview: preview)
    }
    fileprivate func verificationImage() async -> CGImage? { await processor.image() }
    fileprivate func verificationReleaseLargeFrames() async throws {
        for _ in 0..<5 {
            let context = CGContext(data: nil, width: 3840, height: 2160, bitsPerComponent: 8,
                bytesPerRow: 3840 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(NSColor.systemBlue.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 3840, height: 2160))
            await verificationAccept(context.makeImage()!)
            guard hasFirstFrame, previewView.preview != nil else {
                throw ScrollUIFailure(description: "4K fixture was not retained for capture")
            }
            weak var oldProcessor = processor
            cancel()
            await Task.yield()
            guard oldProcessor == nil, previewView.preview == nil, inlineEditor == nil,
                  task == nil, scrollLock == nil, region == nil, !hasFirstFrame,
                  await processor.image() == nil else {
                throw ScrollUIFailure(description: "Cancel retained a previous 4K capture resource")
            }
        }
    }

}

@main
private struct ScrollUIVerification {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        Task { @MainActor in await verifyAll() }
        application.run()
    }

    @MainActor private static func verifyAll() async {
        var failures = 0
        var passed = 0
        var skipped = 0
        func run(_ name: String, _ body: () async throws -> Void) async {
            do { try await body(); passed += 1; print("PASS: \(name)") }
            catch let unavailable as ScrollUIUnavailable { skipped += 1; print("SKIP: \(name): \(unavailable)") }
            catch { failures += 1; print("FAIL: \(name): \(error)") }
            fflush(stdout)
        }
        await run("negative-origin display keeps the compact HUD within its screen") { try verifyGeometry() }
        await run("HUD icon actions retain accessible names, hints and actual view hit tests") { try verifyToolbar() }
        await run("live outside-selection shade leaves the selected pixels clear") { try verifyMask() }
        await run("HUD is nonactivating and transparent outline does not block the target") { try verifyInputPassThrough() }
        await run("mode and pause display changes preserve seeded pixels and revisits are not stationary") { try await verifyStateAndSeed() }
        await run("rejected frames keep sampling and recover on overlap without Continue") { try await verifyRecovery() }
        await run("compact pause status retains details on hover and clears on recovery") { try await verifyVisibleReason() }
        await run("stationary automatic capture yields to manual; hard pauses stop sampling") { try await verifyRecoveryBoundaries() }
        await run("completion choices deliver the entire assembled image exactly once and close") { try await verifyCompletionChoices() }
        await run("failed completion preserves the long image for retry or annotation") { try await verifyCompletionFailure() }
        await run("inline annotation cancels safely and retries failed completion without losing marks") { try await verifyInlineAnnotationLifecycle() }
        await run("cancelled completion cannot deliver stale pixels or close a new session") { try await verifyCancelledCompletion() }
        await run("five 4K capture cycles release old processors and preview buffers on cancel") {
            let coordinator = ScrollCaptureCoordinator(capture: { _ in
                throw ScrollUIFailure(description: "Resource probe must not capture the screen")
            }, onComplete: { _, _ in })
            try await coordinator.verificationReleaseLargeFrames()
        }
        print("COMPLETE: scroll HUD verification: \(passed) PASS, \(skipped) SKIP, \(failures) FAIL")
        exit(failures == 0 ? 0 : 1)
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw ScrollUIFailure(description: message) }
    }

    @MainActor private static func fixture(_ region: CaptureRegion,
        onComplete: @escaping (CGImage, ScrollCaptureCoordinator.CompletionAction) throws -> Void = { _, _ in }) -> ScrollCaptureCoordinator {
        let coordinator = ScrollCaptureCoordinator(capture: { _ in
            throw ScrollUIFailure(description: "Verification must not call capture")
        }, onComplete: onComplete)
        coordinator.verificationPresent(region)
        return coordinator
    }

    private static func syntheticRegion() -> CaptureRegion {
        CaptureRegion(rect: CGRect(x: -1320, y: 280, width: 400, height: 280), displayID: 2,
            screenFrame: CGRect(x: -1440, y: 100, width: 1440, height: 900), scale: 1, targetPID: nil)
    }

    @MainActor private static func buttons(_ coordinator: ScrollCaptureCoordinator) -> [NSButton] {
        coordinator.verificationToolbar.rows.flatMap { $0 }.compactMap { $0 as? NSButton }
    }

    @MainActor private static func button(_ title: String, in coordinator: ScrollCaptureCoordinator) throws -> NSButton {
        guard let button = buttons(coordinator).first(where: { $0.title == title }) else {
            throw ScrollUIFailure(description: "Missing HUD button: \(title)")
        }
        return button
    }

    @MainActor private static func verifyGeometry() throws {
        let region = syntheticRegion()
        let coordinator = fixture(region)
        defer { coordinator.cancel() }
        guard let panel = coordinator.verificationPanel, let outline = coordinator.verificationOutline else {
            throw ScrollUIFailure(description: "Missing HUD or outline")
        }
        try require(region.screenFrame.contains(panel.frame), "HUD is outside negative-origin display bounds")
        try require(panel.frame.height < 300 && coordinator.verificationPreviewVisible, "HUD does not show a compact preview")
        try require(!panel.frame.contains(CGPoint(x: region.rect.midX, y: region.rect.midY)), "HUD blocks the automatic scroll anchor")
        try require(outline.frame == region.screenFrame, "Mask does not cover the capture display")
        try require(coordinator.verificationMask?.selection == region.rect.offsetBy(dx: -region.screenFrame.minX, dy: -region.screenFrame.minY),
                    "Negative-origin mask aperture does not match the confirmed selection")
        try button("预览", in: coordinator).performClick(nil)
        try require(!coordinator.verificationPreviewVisible && panel.frame.height < 150, "Preview does not collapse to compact controls")
        try button("预览", in: coordinator).performClick(nil)
        try require(coordinator.verificationPreviewVisible && !panel.frame.contains(CGPoint(x: region.rect.midX, y: region.rect.midY)),
                    "Expanded preview blocks the scroll anchor")
    }

    @MainActor private static func verifyToolbar() throws {
        let coordinator = fixture(syntheticRegion())
        defer { coordinator.cancel() }
        coordinator.verificationSetRunning()
        let toolbar = coordinator.verificationToolbar
        try require(buttons(coordinator).map(\.title) == ["自动上", "自动下", "预览", "标注", "取消", "完成"],
                    "Default manual capture still requires a manual or pause button")
        coordinator.verificationSetRunning(automatic: .down)
        try require(buttons(coordinator).map(\.title) == ["自动上", "自动下", "暂停自动", "预览", "标注", "取消", "完成"],
                    "Automatic capture does not offer a clearly labeled automatic pause action")
        for action in buttons(coordinator) {
            try require(action.image != nil && action.imagePosition == .imageOnly && !action.title.isEmpty
                        && action.accessibilityLabel() == action.title && !(action.toolTip ?? "").isEmpty,
                        "\(action.title) must show only its icon while retaining its name and hint: position=\(action.imagePosition.rawValue), label=\(action.accessibilityLabel() ?? "nil"), hint=\(action.toolTip ?? "nil"), image=\(action.image != nil)")
            let point = toolbar.convert(CGPoint(x: action.bounds.midX, y: action.bounds.midY), from: action)
            let hit = toolbar.hitTest(toolbar.convert(point, to: toolbar.superview))
            try require(hit === action || hit?.isDescendant(of: action) == true, "\(action.title) does not receive view hit testing")
        }
        let pause = try button("暂停自动", in: coordinator)
        let runningTooltip = pause.toolTip
        let runningIcon = pause.image
        try require(coordinator.verificationStopAutomatic() && coordinator.verificationManual && coordinator.verificationRunning,
                    "Stopping automatic scrolling did not return to active manual capture")
        try require(!buttons(coordinator).contains(where: { $0.title == "暂停自动" || $0.title == "手动" }),
                    "Manual capture retains unnecessary mode/pause buttons")
        coordinator.verificationPause()
        let resume = try button("继续", in: coordinator)
        try require(resume.image !== runningIcon && resume.toolTip != runningTooltip,
                    "Pause/resume did not update the icon and tooltip")
        try require(resume.imagePosition == .imageOnly && resume.accessibilityLabel() == "继续",
                    "Resuming must remain icon-only with the updated accessible name")
    }

    @MainActor private static func verifyMask() throws {
        let coordinator = fixture(syntheticRegion())
        defer { coordinator.cancel() }
        guard let mask = coordinator.verificationMask,
              let bitmap = mask.bitmapImageRepForCachingDisplay(in: mask.bounds) else {
            throw ScrollUIFailure(description: "Cannot rasterize synthetic selection mask")
        }
        mask.cacheDisplay(in: mask.bounds, to: bitmap)
        let scaleX = CGFloat(bitmap.pixelsWide) / mask.bounds.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / mask.bounds.height
        let center = CGPoint(x: mask.selection.midX, y: mask.selection.midY)
        let inside = bitmap.colorAt(x: Int(center.x * scaleX), y: Int((mask.bounds.maxY - center.y) * scaleY))
        let outside = bitmap.colorAt(x: Int(10 * scaleX), y: Int(10 * scaleY))
        try require((outside?.alphaComponent ?? 0) > 0.25, "Outside selection is missing its live translucent shade")
        try require((inside?.alphaComponent ?? 1) < 0.01, "Mask paints over the live selected content")
        try require(coordinator.verificationOutline?.ignoresMouseEvents == true, "Full-screen shade intercepts target input")
    }

    @MainActor private static func verifyInputPassThrough() throws {
        guard let screen = NSScreen.screens.first else { throw ScrollUIFailure(description: "No GUI screen available") }
        let area = CGRect(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.minY + 150, width: 260, height: 140)
        let target = NSWindow(contentRect: area, styleMask: [.borderless], backing: .buffered, defer: false)
        target.isReleasedWhenClosed = false
        target.backgroundColor = .systemGreen
        target.isOpaque = true
        target.level = .screenSaver
        target.orderFrontRegardless()
        let originalApplication = NSWorkspace.shared.frontmostApplication
        let region = CaptureRegion(rect: area, displayID: 1, screenFrame: screen.frame,
                                   scale: screen.backingScaleFactor, targetPID: nil)
        let coordinator = fixture(region)
        defer { coordinator.cancel(); target.orderOut(nil) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        guard let panel = coordinator.verificationPanel, let outline = coordinator.verificationOutline else {
            throw ScrollUIFailure(description: "Missing HUD windows")
        }
        // Isolate only the synthetic windows from any unrelated floating windows on the desktop.
        outline.level = target.level
        outline.orderFrontRegardless()
        panel.level = target.level
        panel.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        try require(outline.ignoresMouseEvents && !outline.isOpaque && !outline.canBecomeKey,
                    "Outline is not a transparent input-pass-through window")
        try require(panel.styleMask.contains(.nonactivatingPanel) && !panel.canBecomeKey && !panel.canBecomeMain,
                    "HUD can steal application or key-window activation")
        if let originalApplication {
            try require(NSWorkspace.shared.frontmostApplication?.isEqual(originalApplication) == true, "Showing HUD changed the foreground application")
        }
        let number = NSWindow.windowNumber(at: CGPoint(x: area.midX, y: area.midY), belowWindowWithWindowNumber: 0)
        print("INFO: own fixture target=\(target.windowNumber), outline=\(outline.windowNumber), HUD=\(panel.windowNumber), hit=\(number), center=\(CGPoint(x: area.midX, y: area.midY)), HUD frame=\(panel.frame)")
        var systemShield = false
        for item in CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? [] {
            guard item[kCGWindowNumber as String] as? Int == number else { continue }
            let pid = item[kCGWindowOwnerPID as String] as? pid_t ?? 0
            let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "unavailable"
            let layer = item[kCGWindowLayer as String] as? Int ?? 0
            let bounds = (item[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
            let displayBounds = CGRect(x: screen.frame.minX, y: 0, width: screen.frame.width, height: screen.frame.height)
            systemShield = layer >= Int(Int32.max) - 2 && bounds?.contains(displayBounds) == true
            if number != target.windowNumber {
                print("INFO: interfering hit number=\(number), PID=\(pid), bundle=\(bundle), layer=\(layer), bounds=\(String(describing: bounds))")
            }
        }
        if systemShield { throw ScrollUIUnavailable(description: "system input shield covers this display; native target hit remains unverified") }
        try require(number == target.windowNumber, "Outline or HUD blocks the confirmed target's input center")
    }

    @MainActor private static func verifyStateAndSeed() async throws {
        let coordinator = fixture(syntheticRegion())
        defer { coordinator.cancel() }
        try require(coordinator.verificationManual, "Initial mode is not manual")
        // Mode clicks remain in preparing here; the probe never installs a lock or starts a capture task.
        for title in ["自动上", "自动下"] {
            let selected = try button(title, in: coordinator)
            selected.performClick(nil)
            try require(selected.state == .on, "\(title) does not reflect the selected mode")
        }
        coordinator.verificationSetRunning()
        await coordinator.verificationAccept(image(top: 0))
        try require(coordinator.verificationHasFirstFrame && coordinator.verificationHeight == 90,
                    "Frozen confirmed selection was not preserved as the initial frame")
        let seedPreviewCount = await coordinator.verificationPreviewCount()
        try require(seedPreviewCount == 1 && coordinator.verificationPreview != nil, "Seed frame does not produce a long-image preview")
        let finish = try button("完成", in: coordinator)
        try require(finish.isEnabled, "Seeded image cannot be completed before the first live scroll")
        coordinator.verificationSetRunning(automatic: .down)
        try require(coordinator.verificationStopAutomatic() && coordinator.verificationManual && coordinator.verificationRunning,
                    "Automatic pause stops capture instead of returning to manual")
        await coordinator.verificationAccept(image(top: 27))
        try require(coordinator.verificationHeight == 117, "First scroll lost the seeded top content")
        let grownPreviewCount = await coordinator.verificationPreviewCount()
        try require(grownPreviewCount == 2 && coordinator.verificationPreview?.whole.height == 117,
                    "Appended rows do not grow the assembled preview")
        coordinator.verificationSetRunning(automatic: .down)
        for top in [0, 27, 0, 27] { await coordinator.verificationAccept(image(top: top)) }
        try require(coordinator.verificationRunning && coordinator.verificationHeight == 117,
                    "Revisiting covered positions was counted as stationary or appended again")
        let revisitedPreviewCount = await coordinator.verificationPreviewCount()
        try require(revisitedPreviewCount == grownPreviewCount, "Revisits unnecessarily regenerate full-image thumbnails")
        coordinator.verificationPause()
        coordinator.verificationSetRunning(automatic: .up)
        await coordinator.verificationAccept(image(top: 0))
        await coordinator.verificationAccept(image(top: -24))
        try require(coordinator.verificationHeight == 141, "Switching automatic direction reset seeded output")
        let upwardPreviewCount = await coordinator.verificationPreviewCount()
        try require(upwardPreviewCount == 3 && coordinator.verificationPreview?.whole.height == 141
                    && coordinator.verificationPreview?.viewport.minY == 0,
                    "Upward extension does not update the whole-image preview and visible position")
        let assembled = await coordinator.verificationImage()
        try require(assembled?.dataProvider?.data as Data? == image(height: 141, top: -24).dataProvider?.data as Data?,
                    "HUD state changes lost original seeded pixels")
        for _ in 0..<3 { await coordinator.verificationAccept(image(top: -24)) }
        try require(coordinator.verificationRecovering && coordinator.verificationManual,
                    "Three unchanged automatic frames did not stop posting while keeping manual recovery available")
        let unchangedPreviewCount = await coordinator.verificationPreviewCount()
        try require(unchangedPreviewCount == upwardPreviewCount, "Duplicate frames unnecessarily regenerate thumbnails")
        let large = fixture(syntheticRegion())
        defer { large.cancel() }
        await large.verificationAccept(image(width: 1200, height: 1000, top: 0))
        guard let preview = large.verificationPreview else { throw ScrollUIFailure(description: "Missing bounded large-frame preview") }
        try require(max(preview.whole.width, preview.whole.height) <= 500
                    && max(preview.recent.width, preview.recent.height) <= 500,
                    "Preview thumbnail exceeded the bounded raster size")
    }

    @MainActor private static func verifyRecovery() async throws {
        let coordinator = fixture(syntheticRegion())
        defer { coordinator.cancel() }
        coordinator.verificationSetRunning()
        await coordinator.verificationAccept(image(top: 0))
        await coordinator.verificationAccept(image(top: 27))
        let operation = coordinator.verificationRun
        let before = await coordinator.verificationImage()
        // Jump farther than the permitted overlap, then return without clicking any HUD action.
        await coordinator.verificationAccept(image(top: 180))
        try require(coordinator.verificationRecovering && coordinator.verificationCaptureActive(operation),
                    "A rejected frame cancelled the sampling run")
        try require(!buttons(coordinator).contains { $0.title == "继续" }, "Recoverable pause still requires Continue")
        let up = try button("自动上", in: coordinator)
        let down = try button("自动下", in: coordinator)
        try require(up.isEnabled && down.isEnabled,
                    "Recoverable pause requires Continue before selecting an automatic direction")
        let rejected = await coordinator.verificationImage()
        try require(rejected?.dataProvider?.data as Data? == before?.dataProvider?.data as Data?,
                    "Rejected frame changed retained pixels")
        await coordinator.verificationAccept(image(top: 27))
        try require(coordinator.verificationRecovering, "An unchanged frame cleared the recovery hint")
        await coordinator.verificationAccept(image(top: 0))
        try require(coordinator.verificationRunning && coordinator.verificationCaptureActive(operation),
                    "A valid reverse revisit did not resume on the same sampling run")
        await coordinator.verificationAccept(image(top: -24))
        await coordinator.verificationAccept(image(top: 27))
        await coordinator.verificationAccept(image(top: 51))
        let recovered = await coordinator.verificationImage()
        try require(coordinator.verificationHeight == 165
                    && recovered?.dataProvider?.data as Data? == image(height: 165, top: -24).dataProvider?.data as Data?,
                    "Bidirectional recovery dropped or duplicated rows")
    }

    @MainActor private static func verifyRecoveryBoundaries() async throws {
        let coordinator = fixture(syntheticRegion())
        defer { coordinator.cancel() }
        coordinator.verificationSetRunning(automatic: .down)
        await coordinator.verificationAccept(image(top: 0))
        let operation = coordinator.verificationRun
        for _ in 0..<3 { await coordinator.verificationAccept(image(top: 0)) }
        try require(coordinator.verificationRecovering && coordinator.verificationManual
                    && coordinator.verificationCaptureActive(operation),
                    "Stationary automatic capture did not leave a live manual recovery run")
        await coordinator.verificationAccept(image(top: 27))
        try require(coordinator.verificationRunning && coordinator.verificationManual
                    && coordinator.verificationHeight == 117,
                    "Manual movement did not recover or unexpectedly restarted automatic input")
        coordinator.verificationPause()
        try require(!coordinator.verificationCaptureActive(operation), "Safety pause left the sampling run active")
        let resume = try button("继续", in: coordinator)
        try require(resume.isEnabled, "Safety pause lost its explicit retry action")
        coordinator.verificationSetRunning()
        let nextOperation = coordinator.verificationRun
        coordinator.verificationLimit()
        try require(!coordinator.verificationRecovering && !coordinator.verificationCaptureActive(nextOperation),
                    "Resource limit was treated as recoverable overlap")
        let retained = await coordinator.verificationImage()
        try require(retained?.dataProvider?.data as Data? == image(height: 117, top: 0).dataProvider?.data as Data?,
                    "Safety or resource pause changed retained output")
    }

    @MainActor private static func verifyVisibleReason() async throws {
        let reason = "没有找到可靠的重叠内容。请回到上一段并慢一点滚动；动态画面或固定顶栏也可能影响拼接。"
        for screenWidth: CGFloat in [600, 420] {
            let region = CaptureRegion(rect: CGRect(x: 30, y: 300, width: 300, height: 220), displayID: 99,
                screenFrame: CGRect(x: 0, y: 0, width: screenWidth, height: 900), scale: 1, targetPID: nil)
            let coordinator = fixture(region)
            defer { coordinator.cancel() }
            coordinator.verificationSetRunning(automatic: .down)
            await coordinator.verificationAccept(image(top: 0))
            coordinator.verificationReject(reason)
            guard let hud = coordinator.verificationHUD, let panel = coordinator.verificationPanel else {
                throw ScrollUIFailure(description: "Missing recovery HUD")
            }
            func visibleText(in view: NSView) -> [NSTextField] {
                guard !view.isHidden else { return [] }
                return (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { visibleText(in: $0) }
            }
            guard let explanation = visibleText(in: hud).first(where: {
                $0.identifier?.rawValue == "scroll.status"
            }) else { throw ScrollUIFailure(description: "Missing inline capture status") }
            try require(explanation.stringValue == "拼接暂停，请回滚重试",
                        "Pause reason and recovery action are not condensed into the status")
            try require(explanation.toolTip?.contains(reason) == true
                        && explanation.accessibilityHelp()?.contains(reason) == true,
                        "Compact status lost its detailed tooltip or accessible help")
            try require(!visibleText(in: hud).contains { $0.identifier?.rawValue == "scroll.status.detail" },
                        "Recovery still shows a separate detail paragraph")
            try require(explanation.frame.width >= explanation.cell!.cellSize.width
                        && panel.frame.height < 270,
                        "Compact status is truncated or still reserves a detail paragraph")
            try require(region.screenFrame.contains(panel.frame)
                        && !panel.frame.contains(CGPoint(x: region.rect.midX, y: region.rect.midY)),
                        "Expanded explanation leaves the display or covers the automatic scroll anchor")
            try require(!buttons(coordinator).contains { $0.title == "继续" }, "Explanation requires Continue")
            if screenWidth == 600, let bitmap = hud.bitmapImageRepForCachingDisplay(in: hud.bounds) {
                hud.cacheDisplay(in: hud.bounds, to: bitmap)
                if let path = ProcessInfo.processInfo.environment["SCREENLEAF_SCROLL_REASON_PREVIEW"],
                   let png = bitmap.representation(using: .png, properties: [:]) {
                    try png.write(to: URL(fileURLWithPath: path))
                }
            }
            await coordinator.verificationAccept(image(top: 27))
            try require(coordinator.verificationRunning && coordinator.verificationManual,
                        "Visible explanation changed the existing automatic-to-manual recovery behavior")
            try require(!explanation.stringValue.contains("拼接暂停") && explanation.toolTip?.contains(reason) != true,
                        "Previous failure reason remains visible after a valid overlap resumes stitching")
        }
    }

    @MainActor private static func verifyCompletionChoices() async throws {
        for (title, expectedAction) in [("完成", ScrollCaptureCoordinator.CompletionAction.copy),
                                        ("标注", .annotate)] {
            var delivered: [(CGImage, ScrollCaptureCoordinator.CompletionAction)] = []
            let coordinator = fixture(syntheticRegion()) { delivered.append(($0, $1)) }
            defer { coordinator.cancel() }
            for label in ["完成", "标注"] {
                let completion = try button(label, in: coordinator)
                try require(!completion.isEnabled, "Completion enabled without any pixels")
            }
            coordinator.verificationSetRunning()
            await coordinator.verificationAccept(image(top: 0))
            await coordinator.verificationAccept(image(top: 27))
            await coordinator.verificationAccept(image(top: -24))
            let originalPanel = coordinator.verificationPanel
            try button(title, in: coordinator).performClick(nil)
            try require(coordinator.verificationFinishing, "Click did not start completion")
            for label in ["完成", "标注"] {
                let other = try button(label, in: coordinator)
                try require(!other.isEnabled, "Completion can be submitted twice")
                other.performClick(nil)
            }
            await coordinator.verificationWaitForCompletion()
            if expectedAction == .annotate {
                try require(delivered.isEmpty && coordinator.verificationPanel === originalPanel
                            && coordinator.verificationEditor?.window === originalPanel && originalPanel?.canBecomeKey == true,
                            "Annotation created a new window or delivered before editing")
                coordinator.verificationEditor?.complete()
            }
            try require(delivered.count == 1 && delivered[0].1 == .copy,
                        "Completion delivered to the wrong destination or more than once")
            try require(delivered[0].0.dataProvider?.data as Data? == image(height: 141, top: -24).dataProvider?.data as Data?,
                        "Completion delivered a preview or incomplete stitched image")
            try require(!coordinator.isActive && coordinator.verificationOutline == nil,
                        "Successful completion did not close both capture windows")
        }
    }

    @MainActor private static func verifyCompletionFailure() async throws {
        for retryTitle in ["完成", "标注"] {
            var attempts = 0
            var deliveredAction: ScrollCaptureCoordinator.CompletionAction?
            let coordinator = fixture(syntheticRegion()) { _, action in
                attempts += 1
                if attempts == 1 { throw ScreenLeafError(message: "Injected clipboard failure") }
                deliveredAction = action
            }
            defer { coordinator.cancel() }
            coordinator.verificationSetRunning()
            await coordinator.verificationAccept(image(top: 0))
            await coordinator.verificationAccept(image(top: 27))
            try button("完成", in: coordinator).performClick(nil)
            await coordinator.verificationWaitForCompletion()
            try require(coordinator.isActive && coordinator.verificationHeight == 117
                        && coordinator.verificationManual && !coordinator.verificationRunning,
                        "Clipboard failure discarded pixels or resumed scrolling")
            let retained = await coordinator.verificationImage()
            try require(retained?.dataProvider?.data as Data? == image(height: 117, top: 0).dataProvider?.data as Data?,
                        "Failure changed the assembled pixels")
            let detail = coordinator.verificationHUD?.subviews.compactMap { $0 as? NSTextField }
                .first { $0.identifier?.rawValue == "scroll.status.detail" }
            try require(detail?.isHidden == true && coordinator.verificationToolbar.subviews.compactMap { $0 as? NSTextField }.contains { $0.toolTip?.contains("Injected clipboard failure") == true },
                        "Failure reason is not visible")
            try button(retryTitle, in: coordinator).performClick(nil)
            await coordinator.verificationWaitForCompletion()
            if retryTitle == "标注" { coordinator.verificationEditor?.complete() }
            try require(attempts == 2 && deliveredAction == .copy
                        && !coordinator.isActive, "Retry or annotation fallback failed")
        }
    }

    @MainActor private static func verifyInlineAnnotationLifecycle() async throws {
        var attempts = 0
        let coordinator = fixture(syntheticRegion()) { _, action in
            attempts += 1
            if attempts == 1 { throw ScreenLeafError(message: "Injected inline clipboard failure") }
            try require(action == .copy, "Inline completion did not copy the complete image")
        }
        defer { coordinator.cancel() }
        coordinator.verificationSetRunning()
        await coordinator.verificationAccept(image(top: 0))
        await coordinator.verificationAccept(image(top: 27))
        let panel = coordinator.verificationPanel
        try button("标注", in: coordinator).performClick(nil)
        await coordinator.verificationWaitForCompletion()
        coordinator.verificationEditor?.onCancel?()
        try require(coordinator.verificationEditor == nil && coordinator.isActive
                    && coordinator.verificationPanel === panel && panel?.canBecomeKey == false
                    && coordinator.verificationHeight == 117, "Cancelling annotation lost the captured long image or panel")
        try button("标注", in: coordinator).performClick(nil)
        await coordinator.verificationWaitForCompletion()
        guard let editor = coordinator.verificationEditor else { throw ScrollUIFailure(description: "No inline workspace") }
        var errors = 0
        editor.onError = { _ in errors += 1 }
        editor.complete()
        try require(attempts == 1 && errors == 1 && coordinator.isActive && coordinator.verificationEditor === editor,
                    "Failed copy discarded the inline editor or failed to report the error")
        editor.complete()
        try require(attempts == 2 && !coordinator.isActive, "Inline completion cannot retry or close")
    }

    @MainActor private static func verifyCancelledCompletion() async throws {
        var callbacks = 0
        let coordinator = fixture(syntheticRegion()) { _, _ in callbacks += 1 }
        defer { coordinator.cancel() }
        coordinator.verificationSetRunning()
        await coordinator.verificationAccept(image(top: 0))
        try button("完成", in: coordinator).performClick(nil)
        let oldCompletion = coordinator.verificationTask
        coordinator.verificationPresent(syntheticRegion())
        coordinator.verificationSetRunning()
        await coordinator.verificationAccept(image(top: 27))
        await oldCompletion?.value
        try require(callbacks == 0 && coordinator.isActive && coordinator.verificationHeight == 90,
                    "Cancelled completion leaked into the replacement session")
    }

    private static func image(width: Int = 96, height: Int = 90, top: Int) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                var value = UInt32(truncatingIfNeeded: x) &* 747_796_405 ^ UInt32(truncatingIfNeeded: y + top) &* 2_891_336_453 ^ 19
                value = (value ^ (value >> 16)) &* 2_246_822_519
                let index = (y * width + x) * 4
                bytes[index] = UInt8(truncatingIfNeeded: value)
                bytes[index + 1] = UInt8(truncatingIfNeeded: value >> 8)
                bytes[index + 2] = UInt8(truncatingIfNeeded: value >> 16)
            }
        }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).union(.byteOrder32Big),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
}
