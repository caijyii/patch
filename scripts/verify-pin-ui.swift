// Concatenated with product ImageTools.swift. Public fixture pixels and no posted input.
import Darwin

private struct PinUIFailure: Error, CustomStringConvertible { let description: String }

extension ImageToolsPinController {
    fileprivate var nativeSelected: Bool { selected && surface.selected }
    fileprivate var nativeHUD: NSPanel? { hud }
    fileprivate var nativeDragView: NSView? { imageView }
    fileprivate var nativeButtons: [NSButton] { toolbar.rows.flatMap { $0 }.compactMap { $0 as? NSButton } }
    fileprivate var nativeOutline: NSView { selectionOutline }
    fileprivate var nativeViewportFrame: CGRect { scroll.frame }
}

extension ImageToolsOCRController {
    fileprivate func nativeCopyAndClose() { copyText() }
}

@main private struct PinUIVerification {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in await verifyAll() }
        app.run()
    }
    @MainActor private static func verifyAll() async {
        var failures = 0
        var passed = 0
        var skipped = 0
        func check(_ name: String, _ body: @MainActor () async throws -> Void) async {
            do { try await body(); passed += 1; print("PASS: \(name)") }
            catch { failures += 1; print("FAIL: \(name): \(error)") }
            fflush(stdout)
        }
        let store = PreferencesStore(storage: MemoryPreferencesStorage())
        let source = whitePinFixture()
        let first = ImageToolsPinController(image: source, preferences: store)
        let second = ImageToolsPinController(image: source, preferences: store)
        var copied = false
        let ocr = ImageToolsOCRController(writeClipboard: { text in copied = text == "公开测试文字"; return copied })
        defer { first.close(); second.close(); ocr.close() }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        guard let firstWindow = first.window, let secondWindow = second.window, let ocrWindow = ocr.window else { exit(1) }
        firstWindow.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        firstWindow.makeKey()
        for _ in 0..<20 {
            await settle()
            if NSApp.isActive && firstWindow.isKeyWindow && first.nativeHUD?.isVisible == true { break }
        }
        if !NSApp.isActive || !firstWindow.isKeyWindow {
            skipped += 1
            print("SKIP: native key transitions are unavailable in the current desktop session")
        } else {
            await check("visible selected pin shows a nonactivating toolbar with working actions") {
                try require(first.nativeSelected && first.nativeHUD?.isVisible == true, "Selected pin has no visible HUD")
                guard let hud = first.nativeHUD else { throw PinUIFailure(description: "Missing HUD") }
                try require(!hud.canBecomeKey && !hud.canBecomeMain && hud.styleMask.contains(.nonactivatingPanel), "HUD steals key-window focus")
                try require(first.nativeButtons.map(\.title) == ["标注", "提取文字", "复制图片", "保存 PNG", "关闭贴图"], "Unexpected selected-pin action set")
                var received = false
                first.onOCR = { _ in received = true }
                first.nativeButtons.first(where: { $0.title == "提取文字" })?.performClick(nil)
                await settle()
                try require(received && firstWindow.isKeyWindow && first.nativeHUD?.isVisible == true, "HUD action loses selection or does not invoke OCR")
            }
            await check("selected image renders an inner highlight without covering its viewport or mouse targets") {
                guard let content = firstWindow.contentView else { throw PinUIFailure(description: "Missing image content") }
                try require(first.nativeOutline.frame == first.nativeViewportFrame && first.nativeOutline.frame == content.bounds,
                            "Selection outline added an outer margin or does not match the image viewport")
                for point in [CGPoint(x: 0.75, y: content.bounds.midY),
                              CGPoint(x: content.bounds.midX, y: content.bounds.midY),
                              CGPoint(x: content.bounds.maxX - 0.75, y: content.bounds.midY)] {
                    try require(first.nativeOutline.hitTest(point) == nil, "Selection outline intercepts image interaction")
                }
                try verifyOutlinePixels(firstWindow, selected: true,
                                        output: output.appendingPathComponent("pin-native-selected.png"))
            }
            await check("actual key-window changes select one pin and hide the previous toolbar") {
                secondWindow.setFrameOrigin(firstWindow.frame.origin + CGSize(width: 90, height: 60))
                secondWindow.makeKeyAndOrderFront(nil)
                await settle(); await settle()
                try require(secondWindow.isKeyWindow && second.nativeSelected && second.nativeHUD?.isVisible == true,
                            "Second pin cannot become selected")
                try require(!first.nativeSelected && first.nativeHUD?.isVisible == false, "Previous pin remains selected")
                try verifyOutlinePixels(firstWindow, selected: false,
                                        output: output.appendingPathComponent("pin-native-deselected.png"))
                try verifyOutlinePixels(secondWindow, selected: true, output: nil)
            }
            await check("mouse event movement updates the visible pin and keeps its toolbar attached") {
                firstWindow.makeKeyAndOrderFront(nil)
                await settle()
                guard let view = first.nativeDragView, let beforeHUD = first.nativeHUD?.frame else {
                    throw PinUIFailure(description: "Missing selected image or toolbar")
                }
                let before = firstWindow.frame
                let anchor = firstWindow.convertPoint(toScreen: view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil))
                for (type, point) in [(NSEvent.EventType.leftMouseDown, anchor), (.leftMouseDragged, anchor + CGSize(width: 24, height: 18)), (.leftMouseUp, anchor + CGSize(width: 24, height: 18))] {
                    let event = NSEvent.mouseEvent(with: type, location: firstWindow.convertPoint(fromScreen: point), modifierFlags: [],
                        timestamp: 0, windowNumber: firstWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                    switch type {
                    case .leftMouseDown: view.mouseDown(with: event)
                    case .leftMouseDragged: view.mouseDragged(with: event)
                    default: view.mouseUp(with: event)
                    }
                }
                await settle()
                try require(abs(firstWindow.frame.minX - before.minX - 24) < 1 && abs(firstWindow.frame.minY - before.minY - 18) < 1,
                            "Image drag did not move the actual window")
                try require(first.nativeHUD?.frame != beforeHUD && first.nativeHUD?.isVisible == true, "Toolbar did not follow the moved pin")
            }
            await check("hiding and restoring a pin does not retain selection, highlight or toolbar") {
                firstWindow.orderOut(nil)
                await settle(); await settle()
                try require(!firstWindow.isVisible && !first.nativeSelected && first.nativeHUD?.isVisible == false,
                            "Hidden pin retains selection or its floating toolbar")
                secondWindow.makeKeyAndOrderFront(nil)
                await settle()
                firstWindow.orderFrontRegardless()
                await settle(); await settle()
                try require(firstWindow.isVisible && !firstWindow.isKeyWindow && !first.nativeSelected
                            && first.nativeHUD?.isVisible == false,
                            "Restoring an inactive pin revived its selection or floating toolbar")
                try verifyOutlinePixels(firstWindow, selected: false,
                                        output: output.appendingPathComponent("pin-native-restored-idle.png"))
            }
            await check("quick focus cancellation and reselection keeps the new highlight after the old fade completes") {
                firstWindow.makeKeyAndOrderFront(nil)
                await settle()
                secondWindow.makeKeyAndOrderFront(nil)
                await settle()
                try require(!first.nativeSelected && second.nativeSelected, "Quick focus change did not deselect the first pin")
                firstWindow.makeKeyAndOrderFront(nil)
                await settle(); await settle(); await settle()
                try require(firstWindow.isKeyWindow && first.nativeSelected && !second.nativeSelected
                            && first.nativeHUD?.isVisible == true,
                            "Quick reselection lost the current pin's focus or toolbar")
                try verifyOutlinePixels(firstWindow, selected: true,
                                        output: output.appendingPathComponent("pin-native-reselected.png"))
                try verifyOutlinePixels(secondWindow, selected: false, output: nil)
            }
        }
        ocr.complete("公开测试文字")
        ocrWindow.makeKeyAndOrderFront(nil)
        await settle()
        await check("OCR uses the native fullscreen window configuration and copy closes after success") {
            try require(ocrWindow.styleMask.contains(.miniaturizable) && ocrWindow.styleMask.contains(.resizable)
                        && ocrWindow.collectionBehavior.contains(.fullScreenPrimary), "OCR window is still configured for zoom only")
            guard let button = ocrWindow.standardWindowButton(.zoomButton) else { throw PinUIFailure(description: "Missing native green control") }
            try require(button.isEnabled, "Native fullscreen control is disabled")
            let subrole = button.accessibilitySubrole()?.rawValue
            print("INFO: own OCR green control subrole=\(subrole ?? "unavailable"), label=\(button.accessibilityLabel() ?? "unavailable")")
            if let subrole { try require(subrole == "AXFullScreenButton", "Native green control still exposes the zoom role") }
            if let frame = ocrWindow.contentView?.superview,
               let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
                frame.cacheDisplay(in: frame.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    try data.write(to: output.appendingPathComponent("ocr-native-window-preview.png"), options: .atomic)
                }
            }
            ocr.nativeCopyAndClose()
            try require(copied && !ocrWindow.isVisible, "Copy success did not close OCR")
        }
        first.close(); second.close(); ocr.close()
        print("COMPLETE: pin native UI verification: \(passed) PASS, \(skipped) SKIP, \(failures) FAIL")
        exit(failures == 0 ? 0 : 1)
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw PinUIFailure(description: message) }
    }
    private static func whitePinFixture() -> CGImage {
        let context = CGContext(data: nil, width: 260, height: 180, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 260, height: 180))
        return context.makeImage()!
    }
    @MainActor private static func verifyOutlinePixels(_ window: NSWindow, selected: Bool, output: URL?) throws {
        guard let content = window.contentView else { throw PinUIFailure(description: "Missing pin content") }
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            throw PinUIFailure(description: "Cannot allocate native pin preview")
        }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        if let output, let png = bitmap.representation(using: .png, properties: [:]) {
            try png.write(to: output, options: .atomic)
        }
        func pixel(_ point: CGPoint) throws -> NSColor {
            let x = Int(point.x / content.bounds.width * CGFloat(bitmap.pixelsWide))
            let y = Int(point.y / content.bounds.height * CGFloat(bitmap.pixelsHigh))
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                throw PinUIFailure(description: "Cannot inspect native pin preview pixels")
            }
            return color
        }
        for point in [CGPoint(x: 0.75, y: content.bounds.midY),
                      CGPoint(x: content.bounds.maxX - 0.75, y: content.bounds.midY),
                      CGPoint(x: content.bounds.midX, y: 0.75),
                      CGPoint(x: content.bounds.midX, y: content.bounds.maxY - 0.75)] {
            let color = try pixel(point)
            if selected {
                try require(color.alphaComponent > 0.99 && color.redComponent < 0.8
                            && color.blueComponent > color.redComponent + 0.05,
                            "Selected pin has no visible blue-gray highlight at \(point)")
            } else {
                try require(color.alphaComponent > 0.99 && color.redComponent > 0.98
                            && color.greenComponent > 0.98 && color.blueComponent > 0.98,
                            "Inactive pin retains a highlight at \(point)")
            }
        }
        let center = try pixel(CGPoint(x: content.bounds.midX, y: content.bounds.midY))
        try require(center.redComponent > 0.98 && center.greenComponent > 0.98 && center.blueComponent > 0.98,
                    "Selection decoration covers the image interior")
    }
    private static func settle() async { try? await Task.sleep(nanoseconds: 80_000_000) }
}

private func + (point: CGPoint, delta: CGSize) -> CGPoint { CGPoint(x: point.x + delta.width, y: point.y + delta.height) }
