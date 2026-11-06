// Concatenated after AnnotationControls.swift; synthetic layouts only.
import Darwin

extension SelectionButton {
    fileprivate var verificationGlyph: NSView { glyph }
    fileprivate var verificationCaption: NSView { caption }
    fileprivate func verificationHover() {
        isPointerInside = true; hoverIsReady = true; updateInteraction()
    }
}

private struct ToolbarFailure: Error, CustomStringConvertible { let description: String }

@main private struct ToolbarVerification {
    @MainActor static func main() {
        guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--verify",
              CommandLine.arguments[2].hasPrefix("/") else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
            fputs("FAIL: toolbar verification timed out\n", stderr); exit(1)
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        do {
            try verifyGeometry()
            try verifyLayout()
            try verifyNativeBacking(output: URL(fileURLWithPath: CommandLine.arguments[2]))
            print("COMPLETE: toolbar metrics, backing alignment and stable glyph verification passed")
            exit(0)
        } catch { print("FAIL: \(error)"); exit(1) }
    }
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw ToolbarFailure(description: message) }
    }
    static func verifyGeometry() throws {
        for scale: CGFloat in [1, 2] {
            let bounds = CGRect(x: -1920, y: -248, width: 1920, height: 1080)
            for selection in [CGRect(x: -1800, y: 120, width: 401, height: 200),
                              CGRect(x: -1919.5, y: -247.5, width: 20, height: 21)] {
                let rect = SelectionGeometry.toolbarFrame(selection: selection,
                    size: CGSize(width: 468, height: 40), within: bounds, backingScaleFactor: scale)
                try require(bounds.contains(rect), "Pixel alignment escaped the display")
                try require(rect.minX * scale == (rect.minX * scale).rounded()
                            && rect.minY * scale == (rect.minY * scale).rounded(), "Toolbar origin lies between backing pixels")
            }
        }
        print("PASS: 1x/2x toolbar origins align to pixels within negative-origin displays")
    }
    @MainActor static func verifyLayout() throws {
        for scale: CGFloat in [1, 2] {
            let toolbar = SelectionToolbar()
            toolbar.configure(forBackingScaleFactor: scale)
            let tools = (0..<12).map { index in SelectionButton("Tool \(index)", symbol: "pencil") {} }
            let cancel = SelectionButton.cancellation(toolTip: "Cancel") {}
            let finish = SelectionButton.confirmation(toolTip: "Finish") {}
            let parameters = AnnotationSizeControl(frame: .zero)
            (tools + [cancel, finish]).forEach { $0.imagePosition = .imageOnly }
            toolbar.rows = [tools + [cancel, finish], [parameters]]
            toolbar.trailingActions = [cancel, finish]
            let result = toolbar.arrange(maxWidth: 320, maxHeight: 280)
            toolbar.frame.size = result
            try require(result.width <= 320 && result.height <= 280, "Comfortable controls no longer fit a narrow display")
            let expected = ToolbarMetrics.forBackingScaleFactor(scale)
            for item in tools + [cancel, finish] {
                try require(item.frame.width >= expected.buttonWidth && item.frame.height == expected.buttonHeight,
                            "Wrapping shrank a button hit target")
                try require(CGRect(origin: .zero, size: result).contains(item.frame), "A button escaped its toolbar")
            }
            try require(cancel.frame.minY == finish.frame.minY && finish.frame.maxX == result.width - 8,
                        "Completion actions lost their stable trailing placement")
            parameters.layoutSubtreeIfNeeded()
            try require(parameters.plus.frame.width == (scale == 1 ? 40 : 28), "Parameter step button did not adopt display metrics")
            try require(parameters.plus.frame.minX >= parameters.slider.frame.maxX, "Comfortable parameter controls overlap")
        }
        print("PASS: compact 2x baseline and comfortable 1x controls wrap without shrinking completion targets")
    }
    @MainActor static func verifyNativeBacking(output: URL) throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let screens = NSScreen.screens
        try require(!screens.isEmpty, "Native backing verification requires a WindowServer connection")
        for (index, screen) in screens.enumerated() {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 150),
                styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let targetFrame = CGRect(x: screen.visibleFrame.minX + 16, y: screen.visibleFrame.minY + 16,
                width: min(500, screen.visibleFrame.width - 32), height: min(150, screen.visibleFrame.height - 32))
            window.setFrame(targetFrame, display: false)
            let displayKey = NSDeviceDescriptionKey("NSScreenNumber")
            let targetDisplay = screen.deviceDescription[displayKey] as? NSNumber
            let actualDisplay = window.screen?.deviceDescription[displayKey] as? NSNumber
            try require(targetDisplay != nil && actualDisplay == targetDisplay,
                        "Hidden window did not move onto the requested display")
            try require(window.backingScaleFactor == screen.backingScaleFactor,
                        "Hidden window requested \(screen.backingScaleFactor)x backing but received \(window.backingScaleFactor)x")
            let toolbar = SelectionToolbar()
            toolbar.configure(forBackingScaleFactor: screen.backingScaleFactor)
            let button = SelectionButton("Sample", symbol: "pencil.tip") {}
            let caption = SelectionButton("Copy", symbol: "doc.on.doc") {}
            button.imagePosition = .imageOnly
            toolbar.rows = [[button, caption]]
            window.contentView?.addSubview(toolbar)
            let size = toolbar.arrange(maxWidth: 400)
            toolbar.frame = SelectionGeometry.toolbarFrame(selection: CGRect(x: 80, y: 90, width: 201, height: 30),
                size: size, within: window.contentView!.bounds, backingScaleFactor: window.backingScaleFactor)
            toolbar.layoutSubtreeIfNeeded()
            for control in [button, caption] {
                control.layoutSubtreeIfNeeded()
                for child in [control.verificationGlyph, control.verificationCaption] where !child.isHidden {
                    let backing = control.convertToBacking(child.frame)
                    try require(backing.minX == backing.minX.rounded() && backing.minY == backing.minY.rounded(),
                                "Native glyph or caption lies between backing pixels")
                }
                control.verificationHover()
                try require(CATransform3DIsIdentity(control.verificationGlyph.layer!.transform), "Hover resamples the glyph")
                control.highlight(true)
                try require(CATransform3DIsIdentity(control.verificationGlyph.layer!.transform), "Press resamples the glyph")
                control.resetPointerFeedback()
            }
            if let bitmap = toolbar.bitmapImageRepForCachingDisplay(in: toolbar.bounds) {
                toolbar.cacheDisplay(in: toolbar.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to:
                    output.appendingPathComponent("toolbar-\(index)-\(Int(window.backingScaleFactor))x.png"))
            }
            print("PASS: requested and actual \(Int(screen.backingScaleFactor))x display match; hidden-window glyph/caption alignment and stable hover/press")
        }
    }
}
