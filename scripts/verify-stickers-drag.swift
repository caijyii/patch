// Concatenated with RegionSelector.swift. Uses only generated artwork and this
// application's NSEvent queue; never captures a screen or posts system input.
import Darwin

extension SelectionView {
    fileprivate var probeControls: AnnotationControls { controls }
    fileprivate var probeSelection: CGRect? { selection }
    fileprivate func seedStickerSelection() {
        screenshotMode = .rectangle; selectionMode = .free; committedMode = .rectangle
        pendingModeChange = false; selection = CGRect(x: 140, y: 240, width: 340, height: 230)
        hover = nil; activeTool = nil; updateSelection()
    }
}
private struct StickerEventFailure: Error { let message: String }

@main private struct StickerEventVerification {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let memory = MemoryPreferencesStorage(), size = CGSize(width: 800, height: 600)
        let preferences = PreferencesStore(storage: memory)
        let view = SelectionView(image: DemoImage.make(), size: size, candidates: [], purpose: .screenshot,
                                 initialMode: .rectangle, preferences: preferences)
        let window = SelectionWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        window.acceptsMouseMovedEvents = true; window.level = .screenSaver
        view.seedStickerSelection()
        window.center(); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(view)
        app.activate(ignoringOtherApps: true); NSCursor.crosshair.push()
        let controls = view.probeControls
        controls.choose(tool: .sticker); controls.moreStickerButton.performClick(nil)
        alarm(8)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            var succeeded = false
            defer {
                controls.probePopover?.close(); window.orderOut(nil); NSCursor.pop()
                fflush(stdout); exit(succeeded ? 0 : 1)
            }
            do {
                func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
                    if !condition() { throw StickerEventFailure(message: message) }
                }
                guard let picker = controls.probePicker, let popup = picker.view.window else {
                    throw StickerEventFailure(message: "Missing production sticker popover")
                }
                func button(_ id: String) -> NSButton {
                    picker.view.subviews.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == id }!
                }
                func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
                    NSEvent.mouseEvent(with: type, location: picker.view.convert(point, to: nil), modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: popup.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                }
                func gesture(_ id: String, to point: CGPoint, escape: Bool = false, small: Bool = false) {
                    let source = button(id), start = CGPoint(x: source.frame.midX, y: source.frame.midY)
                    if escape {
                        app.postEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: popup.windowNumber,
                            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!, atStart: true)
                    } else { app.postEvent(event(.leftMouseUp, point), atStart: true) }
                    app.postEvent(event(.leftMouseDragged, small ? CGPoint(x: start.x + 2, y: start.y) : point), atStart: true)
                    // Dispatch through the production popover's window and hit test.
                    popup.sendEvent(event(.leftMouseDown, start))
                }
                func centre(_ id: String) -> CGPoint { let b = button(id); return CGPoint(x: b.frame.midX, y: b.frame.midY) }
                let initial = controls.orderedStickerIdentifiers, moved = initial.last!, first = initial.first!
                let selection = view.probeSelection
                gesture(moved, to: centre(first))
                let expected = [moved] + initial.dropLast()
                try require(controls.orderedStickerIdentifiers == expected && memory.writeCount > 0,
                            "Actual popover mouse-down/drag/up did not persist the moved item")
                try require(controls.probePopover?.isShown == true && controls.activeTool == .sticker && view.probeSelection == selection,
                            "Reordering closed the picker or changed the capture selection/tool")
                gesture(moved, to: centre(first))
                try require(controls.orderedStickerIdentifiers[0] == first && controls.orderedStickerIdentifiers[1] == moved,
                            "Dropping over the adjacent centre did not swap")
                gesture(moved, to: centre(first))
                try require(controls.orderedStickerIdentifiers == expected, "Backward centre drop did not restore order")
                let writes = memory.writeCount
                gesture(moved, to: CGPoint(x: -30, y: -20))
                gesture(moved, to: centre(first), escape: true)
                try require(memory.writeCount == writes && controls.orderedStickerIdentifiers == expected && controls.probePopover?.isShown == true,
                            "Cancel or outside release saved an order or dismissed the popover")
                let restored = PreferencesStore(storage: memory)
                try require(restored.orderedStickerIdentifiers(defaults: StickerCatalog.items.map(\.id)) == expected,
                            "Full event-chain reorder was not retained by fresh preferences")
                gesture("patch-cat", to: centre("patch-cat"), small: true)
                try require(controls.canvas.annotationSticker == "patch-cat", "Small jitter click did not choose the requested sticker")
                // NSPopover finishes its animated close on a later run-loop turn.
                let closeDeadline = Date().addingTimeInterval(1)
                while controls.probePopover?.isShown == true && Date() < closeDeadline {
                    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
                }
                try require(controls.probePopover?.isShown == false && memory.writeCount == writes,
                            "Small pointer jitter did not remain a normal selection click")
                print("PASS: production SelectionWindow/SelectionView popover event chain reorders, swaps adjacent centres, cancels, persists, and retains click-to-select")
                print("PASS: screenshot parent and popover levels \(window.level.rawValue)/\(popup.level.rawValue); capture selection and active tool preserved")
                succeeded = true
            } catch { print("FAIL: \(error)") }
        }
        app.run()
    }
}
