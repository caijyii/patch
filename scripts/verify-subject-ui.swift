import ImageIO
import Darwin

private struct SubjectUIFailure: Error { let message: String }

extension SubjectSelectionController {
    fileprivate var verificationExtraction: SubjectExtractionResult? { extraction }
    fileprivate var verificationRendering: Bool { rendering }
    fileprivate var verificationOutput: CGImage? { output }
    fileprivate var verificationSelected: IndexSet { selected }
    fileprivate var verificationOutputButtons: [NSButton] { outputButtons }
    fileprivate var verificationHistory: [IndexSet] { history }
    fileprivate var verificationOriginal: SubjectPreviewView { original }
    fileprivate var verificationPreview: SubjectPreviewView { preview }
    fileprivate var verificationUndo: NSButton { undoButton }
    fileprivate var verificationReset: NSButton { resetButton }
    fileprivate var verificationClosed: Bool { closed }
}
extension SubjectPreviewView { fileprivate var verificationRect: CGRect { imageRect } }
extension ImageToolsPinController { fileprivate var verificationSurface: ImageToolsPinSurface { surface } }
extension ImageToolsCoordinator {
    fileprivate var verificationPins: [UUID: ImageToolsPinController] { pins }
    fileprivate var verificationWindows: [UUID: NSWindowController] { windows }
    fileprivate var verificationHidden: Bool { pinsHidden }
}

@main
private struct SubjectUIProbe {
    @MainActor static func main() {
        do {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let input = URL(fileURLWithPath: CommandLine.arguments[1])
            let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            guard let imageSource = CGImageSourceCreateWithURL(input as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
                throw SubjectUIFailure(message: "Cannot load sample")
            }
            let controller = SubjectSelectionController(image: image)
            controller.showWindow(nil)
            guard let window = controller.window else { throw SubjectUIFailure(message: "No selection window") }
            window.makeKeyAndOrderFront(nil)
            try wait { controller.verificationExtraction != nil && !controller.verificationRendering }
            try require(controller.verificationOutput != nil && controller.verificationSelected.count == 1, "Duck must start selected")
            try require(controller.verificationOutputButtons.allSatisfy(\.isEnabled), "Ready output buttons must be enabled")
            try require(ImageToolsUI.hasTransparentPixels(controller.verificationOutput!), "Export must retain transparent pixels")
            let png = try ImageToolsUI.png(controller.verificationOutput!)
            try png.write(to: directory.appendingPathComponent("duck-transparent.png"))
            let decoded = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(png as CFData, nil)!, 0, nil)!
            try require(ImageToolsUI.hasTransparentPixels(decoded), "PNG round-trip must preserve alpha")
            window.contentView?.layoutSubtreeIfNeeded()
            window.appearance = NSAppearance(named: .aqua)
            window.display()
            pump(seconds: 0.05)
            try snapshot(window.contentView!, to: directory.appendingPathComponent("subject-selection-preview.png"))
            window.appearance = NSAppearance(named: .darkAqua)
            window.display()
            pump(seconds: 0.05)
            try snapshot(window.contentView!, to: directory.appendingPathComponent("subject-selection-dark-preview.png"))
            print("PASS: background analysis, transparent result, PNG alpha and initial selection")

            let body = CGPoint(x: 0.59, y: 0.65)
            let historyCount = controller.verificationHistory.count
            try click(controller.verificationOriginal, normalized: CGPoint(x: 0.85, y: 0.15))
            try require(controller.verificationHistory.count == historyCount, "Background click must not edit selection")
            try click(controller.verificationOriginal, normalized: body)
            try wait { !controller.verificationRendering }
            try require(controller.verificationSelected.isEmpty && controller.verificationOutput == nil && controller.verificationPreview.result == nil,
                        "Deselecting the only subject must produce an empty result")
            try require(controller.verificationOutputButtons.allSatisfy { !$0.isEnabled }, "Empty output must disable export")
            controller.verificationUndo.performClick(nil)
            try wait { !controller.verificationRendering }
            try require(controller.verificationOutput != nil && controller.verificationSelected.count == 1, "Undo must restore the duck")
            try click(controller.verificationOriginal, normalized: body)
            try wait { !controller.verificationRendering }
            controller.verificationReset.performClick(nil)
            try wait { !controller.verificationRendering }
            try require(controller.verificationOutput != nil, "Reset must restore initial selection")
            print("PASS: actual preview click, background no-op, empty output, undo and reset")

            window.setContentSize(CGSize(width: 700, height: 460))
            window.contentView?.layoutSubtreeIfNeeded()
            try click(controller.verificationOriginal, normalized: body)
            try wait { !controller.verificationRendering }
            try require(controller.verificationOutput == nil, "Hit testing must track the resized image")
            for _ in 0..<3 { try click(controller.verificationOriginal, normalized: body) }
            try wait { !controller.verificationRendering }
            try require(controller.verificationSelected.count == 1 && controller.verificationOutput != nil, "Latest render must win rapid toggles")
            var pinned: CGImage?
            controller.onPin = { pinned = $0 }
            controller.verificationOutputButtons[2].performClick(nil)
            try require(pinned != nil && !window.isVisible, "Pin must pass transparent output and close selection")
            print("PASS: resize coordinates, rapid updates and pin action")

            let pin = ImageToolsPinController(image: pinned!, preferences: PreferencesStore(storage: MemoryPreferencesStorage()))
            pin.showWindow(nil)
            pin.window?.contentView?.layoutSubtreeIfNeeded()
            try require(ImageToolsUI.hasTransparentPixels(pinned!) && pin.window?.isOpaque == false && pin.window?.hasShadow == false,
                        "Transparent image pin must have no rectangular background or window shadow")
            try snapshot(pin.verificationSurface, to: directory.appendingPathComponent("transparent-pin-preview.png"))
            let rep = pin.verificationSurface.bitmapImageRepForCachingDisplay(in: pin.verificationSurface.bounds)!
            pin.verificationSurface.cacheDisplay(in: pin.verificationSurface.bounds, to: rep)
            try require(rep.cgImage.map { ImageToolsUI.hasTransparentPixels($0) } == true,
                        "Pin must preserve transparent source pixels without adding a background")
            pin.close()
            let coordinator = ImageToolsCoordinator()
            coordinator.pinImage(pinned!)
            coordinator.pinText("session fixture")
            try require(coordinator.verificationPins.count == 2, "Both pin types should be in memory")
            coordinator.closeAll()
            try require(coordinator.verificationPins.isEmpty && coordinator.verificationWindows.isEmpty && !coordinator.verificationHidden,
                        "Session cleanup must close and clear every pin")
            let restarted = ImageToolsCoordinator()
            try require(restarted.verificationPins.isEmpty && restarted.verificationWindows.isEmpty, "New session must not restore pins")
            print("PASS: transparent pin surface, image/text session cleanup and empty new session")

            let cancelled = SubjectSelectionController(image: image)
            cancelled.showWindow(nil)
            cancelled.close()
            pump(seconds: 0.7)
            try require(cancelled.verificationClosed && cancelled.verificationExtraction == nil && cancelled.window?.isVisible == false,
                        "Analysis completion after closing must not revive the window")
            print("PASS: closing during analysis prevents late results from reopening")
            print("COMPLETE: subject UI verification")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw SubjectUIFailure(message: message) }
    }
    @MainActor private static func wait(_ ready: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(8)
        while !ready(), Date() < deadline { pump(seconds: 0.02) }
        try require(ready(), "Timed out waiting for background render")
    }
    @MainActor private static func pump(seconds: Double) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
    @MainActor private static func click(_ view: SubjectPreviewView, normalized: CGPoint) throws {
        guard let window = view.window else { throw SubjectUIFailure(message: "Preview has no window") }
        let rect = view.verificationRect
        let point = view.convert(CGPoint(x: rect.minX + normalized.x * rect.width,
                                         y: rect.minY + normalized.y * rect.height), to: nil)
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        view.mouseDown(with: event)
    }
    @MainActor private static func snapshot(_ view: NSView, to url: URL) throws {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw SubjectUIFailure(message: "Cannot render view preview")
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw SubjectUIFailure(message: "Cannot encode view preview")
        }
        try data.write(to: url)
    }
}
