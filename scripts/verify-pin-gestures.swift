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

@main private struct PinGesturesVerification {
    @MainActor static func main() {
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

        guard let context = CGContext(data: nil, width: 600, height: 320, bitsPerComponent: 8,
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
        print("SKIP: native magnify construction has no public NSEvent/CGEvent factory; no private event fields used")
        print("PASS: native CG precise scroll phases route through NSWindow to the production image pin")
        print("LIMIT: CG events are sent directly to their target window; WindowServer/hardware assignment is not exercised")
    }
}
