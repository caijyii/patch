// Production ImageTools.swift is concatenated before this probe.
// Uses only self-created nonactivating test windows and NSWindow.sendEvent.
// Never activates the app, posts events, or captures desktop content.
import Darwin

private struct PinGestureFailure: Error, CustomStringConvertible { let description: String }
private func gestureRequire(_ value: @autoclosure () -> Bool, _ message: String) throws {
    guard value() else { throw PinGestureFailure(description: message) }
}

extension ImageToolsPinController {
    fileprivate var gestureScale: CGFloat { scale }
    fileprivate var gestureView: ImageToolsPinImageView? { imageView }
    fileprivate var gestureSurface: NSView { surface }

}

private final class GestureControlView: NSView {
    var count = 0
    override func scrollWheel(with event: NSEvent) { count += 1 }
}

private final class PinMagnifyEvent: NSEvent {
    var amount: CGFloat = 0.25
    var point: CGPoint = .zero
    override var type: NSEvent.EventType { .magnify }
    override var magnification: CGFloat { amount }
    override var locationInWindow: NSPoint { point }
}

@main private struct PinGesturesVerification {
    @MainActor private static var interactivePins: [ImageToolsPinController] = []
    @MainActor private static var interactiveMonitor: Any?
    @MainActor private static var interactiveControl: NSWindow?
    @MainActor private static func interactive() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        guard let screen = NSScreen.main else { return }
        for (index, height) in [320, 6000].enumerated() {
            guard let context = CGContext(data: nil, width: 600, height: height, bitsPerComponent: 8,
                bytesPerRow: 2400, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            context.setFillColor(index == 0 ? NSColor.systemBlue.cgColor : NSColor.systemOrange.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 600, height: height))
            guard let image = context.makeImage() else { continue }
            let pin = ImageToolsPinController(image: image, pixelScale: 2,
                anchor: CGPoint(x: screen.visibleFrame.midX + CGFloat(index * 380 - 250), y: screen.visibleFrame.midY))
            guard let window = pin.window, let view = pin.gestureView else { continue }
            let original = view.onZoom
            view.onZoom = { [weak pin] factor, point in
                original?(factor, point)
                print("HANDLED: fixture=\(index) factor=\(factor) scale=\(pin?.gestureScale ?? 0)")
                fflush(stdout)
            }
            interactivePins.append(pin)
            window.orderFrontRegardless()
            print("FIXTURE: \(index) window=\(window.windowNumber) height=\(height)")
        }
        interactiveMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .scrollWheel, .magnify, .beginGesture, .endGesture, .gesture, .smartMagnify]) { event in
            print("RECEIVED: type=\(event.type.rawValue) window=\(event.windowNumber) magnification=\(event.type == .magnify ? event.magnification : 0)")
            if event.type == .leftMouseDown {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    print("FOCUS: appActive=\(NSRunningApplication.current.isActive) frontmostMatches=\(NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier) keyWindow=\(NSApp.keyWindow?.windowNumber ?? 0)")
                    fflush(stdout)
                }
            }
            fflush(stdout)
            return event
        }
        if CommandLine.arguments.contains("--interactive-active") {
            let window = NSWindow(contentRect: CGRect(x: screen.visibleFrame.midX - 160,
                y: screen.visibleFrame.midY + 180, width: 320, height: 170),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "捏合对照 · 系统滚动视图"
            window.isReleasedWhenClosed = false
            let scroll = NSScrollView(frame: window.contentView!.bounds)
            scroll.allowsMagnification = true
            scroll.minMagnification = 0.1
            scroll.maxMagnification = 5
            let document = NSTextView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
            document.string = "系统视图：请在这里捏合\nSystem pinch control"
            document.font = .systemFont(ofSize: 24)
            scroll.documentView = document
            window.contentView = scroll
            interactiveControl = window
            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
            interactivePins.first?.window?.makeKeyAndOrderFront(nil)
        }
        print("READY: active=\(app.isActive) policy=\(app.activationPolicy().rawValue); blue=ordinary, orange=tall; pinch each. Test closes automatically after 180 seconds.")
        fflush(stdout)
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) {
            interactiveControl?.close()
            interactivePins.forEach { $0.close() }
            if let interactiveMonitor { NSEvent.removeMonitor(interactiveMonitor) }
            exit(0)
        }
        app.run()
    }

    @MainActor static func main() {
        if ["--interactive", "--interactive-active"].contains(CommandLine.arguments.last ?? "") { interactive(); return }
        guard CommandLine.arguments.dropFirst().elementsEqual(["--verify"]) else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
            fputs("FAIL: routed pin gesture probe timed out\n", stderr); exit(1)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        DispatchQueue.main.async {
            do { try run(); exit(0) }
            catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
        }
        app.run()
    }

    @MainActor private static func scrollEvent(window: NSWindow, location: CGPoint, delta: Int32,
        phase: Int64 = 0, momentum: Int64 = 0, precise: Bool = true) throws -> NSEvent {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: precise ? .pixel : .line,
                               wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0) else {
            throw PinGestureFailure(description: "Cannot create CG scroll event")
        }
        let global = window.convertPoint(toScreen: location)
        let top = NSScreen.screens.first?.frame.maxY ?? 900
        cg.location = CGPoint(x: global.x, y: top - global.y)
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: precise ? 1 : 0)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        guard var event = NSEvent(cgEvent: cg) else { throw PinGestureFailure(description: "CG scroll did not become NSEvent") }
        if event.windowNumber == 0 {
            // Unposted CGEvents are unbound. NSWindow.sendEvent receives a local
            // position, so supply that position without private event mutation.
            cg.location = CGPoint(x: location.x, y: top - location.y)
            guard let localEvent = NSEvent(cgEvent: cg) else { throw PinGestureFailure(description: "Local CG scroll did not become NSEvent") }
            event = localEvent
        }
        print("EVENT: target=\(window.windowNumber) actual=\(event.windowNumber) location=\(event.locationInWindow) expected=\(location) delta=\(event.scrollingDeltaY) precise=\(event.hasPreciseScrollingDeltas) phase=\(event.phase.rawValue) momentum=\(event.momentumPhase.rawValue)")
        try gestureRequire(abs(event.locationInWindow.x-location.x)<0.01 && abs(event.locationInWindow.y-location.y)<0.01,
            "Native CG event did not preserve the supplied window-local coordinates")
        return event
    }

    @MainActor private static func run() throws {
        let frontBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier
        defer {
            print("FOCUS: before=\(String(describing: frontBefore)) after=\(String(describing: NSWorkspace.shared.frontmostApplication?.processIdentifier)) current=\(NSRunningApplication.current.processIdentifier)")
        }
        let control = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 260, height: 180),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        control.isReleasedWhenClosed = false
        let controlView = GestureControlView(frame: CGRect(x: 0, y: 0, width: 260, height: 180))
        control.contentView = controlView
        defer { control.close() }
        control.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        let center = CGPoint(x: 130, y: 90)
        for (delta, phase, momentum) in [(Int32(0), Int64(1), Int64(0)), (8, 2, 0), (0, 4, 0), (5, 0, 1), (0, 0, 3)] {
            control.sendEvent(try scrollEvent(window: control, location: center, delta: delta, phase: phase, momentum: momentum))
        }
        print("CONTROL: delivered=\(controlView.count) visible=\(control.isVisible)")
        try gestureRequire(controlView.count > 0, "NSWindow did not deliver any scroll event to the visible plain control; direct synthetic routing is unavailable")
        control.orderOut(nil)

        for fixtureHeight in [320, 6000, 24000] {
            guard let context = CGContext(data: nil, width: 600, height: fixtureHeight, bitsPerComponent: 8,
                bytesPerRow: 2400, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let image = context.makeImage() else { throw PinGestureFailure(description: "Cannot create synthetic image") }
            let pin = ImageToolsPinController(image: image, pixelScale: 2, anchor: CGPoint(x: 300, y: 500))
            defer { pin.close() }
            guard let window = pin.window, let view = pin.gestureView else { throw PinGestureFailure(description: "Missing pin") }
            window.orderFrontRegardless()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            let original = view.onZoom
            var zoomCalls = 0
            view.onZoom = { factor, point in zoomCalls += 1; original?(factor, point) }
            for stage in ["unselected", "first-responder"] {
                if stage == "first-responder" { _ = window.makeFirstResponder(view) }
                let before = pin.gestureScale
                let startCalls = zoomCalls
                let point = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
                let hitPoint = pin.gestureSurface.convert(point, from: nil)
                print("PIN: stage=\(stage) hit=\(String(describing: pin.gestureSurface.hitTest(hitPoint))) viewFrame=\(view.frame) first=\(String(describing: window.firstResponder)) hidden=\(!window.isVisible)")
                try gestureRequire(pin.gestureSurface.hitTest(hitPoint) === view, "Production hierarchy does not hit the image view")
                for (delta, phase, momentum) in [(Int32(0), Int64(1), Int64(0)), (8, 2, 0), (0, 4, 0), (5, 0, 1), (0, 0, 3)] {
                    window.sendEvent(try scrollEvent(window: window, location: point, delta: delta, phase: phase, momentum: momentum))
                }
                print("PIN RESULT: stage=\(stage) calls=\(zoomCalls-startCalls) scale=\(before)->\(pin.gestureScale)")
                try gestureRequire(zoomCalls > startCalls && pin.gestureScale > before, "Routed precise scroll did not reach image zoom in \(stage)")
            }
            let pinch = PinMagnifyEvent()
            pinch.point = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            let beforePinch = pin.gestureScale
            view.magnify(with: pinch)
            try gestureRequire(abs(pin.gestureScale - beforePinch * 1.25) < 0.000001,
                               "Tall image magnify handler failed to enlarge")
            pinch.amount = -0.2
            pinch.point = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            view.magnify(with: pinch)
            try gestureRequire(abs(pin.gestureScale - beforePinch) < 0.000001,
                               "Tall image magnify handler failed to shrink")
        }
        print("SKIP: native magnify construction has no public NSEvent/CGEvent factory; no private event fields used")
        print("PASS: native CG precise scroll phases route through NSWindow to the production image pin")
        print("LIMIT: CG events are sent directly to their target window; WindowServer/hardware assignment is not exercised")
    }
}
