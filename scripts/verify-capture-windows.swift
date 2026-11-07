import AppKit
import ScreenCaptureKit
import Darwin

@MainActor private final class SyntheticPinPanel: NSPanel, CapturePinWindow {}

@main struct VerifyCaptureWindows {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = CaptureWindowVerificationDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
    @MainActor static func verify() async {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let base = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 240, height: 180),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let overlay = NSPanel(contentRect: base.contentRect(forFrameRect: base.frame),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let pin = SyntheticPinPanel(contentRect: base.contentRect(forFrameRect: base.frame),
            styleMask: [.borderless], backing: .buffered, defer: false)
        pin.isReleasedWhenClosed = false; pin.backgroundColor = .green; pin.level = .floating
        defer { pin.close() }
        guard !CaptureWindowPolicy.includes(pin), CaptureWindowPolicy.includes(pin, hidePins: false),
              !CaptureWindowPolicy.includes(overlay, hidePins: false) else {
            print("FAIL: pin toggle must include content only, never operation overlays"); exit(1)
        }
        print("PASS: pin content obeys toggle; operation overlays remain excluded")
        base.isReleasedWhenClosed = false; overlay.isReleasedWhenClosed = false
        base.backgroundColor = .blue; overlay.backgroundColor = .red; overlay.level = .floating
        defer { overlay.close(); base.close() }
        guard CaptureWindowPolicy.includes(base), !CaptureWindowPolicy.includes(overlay) else {
            print("FAIL: ordinary window/overlay capture policy"); exit(1)
        }
        print("PASS: ordinary Patch windows included; operation panels excluded")
        guard CGPreflightScreenCaptureAccess() else {
            print("SKIP: real pixel check requires existing screen capture access; no permission requested"); return
        }
        base.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true); pin.orderFront(nil); overlay.orderFront(nil)
        do {
            try await Task.sleep(for: .milliseconds(350))
            let screen = base.screen!
            let rect = base.convertToScreen(base.contentView!.bounds)
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value
            let region = CaptureRegion(rect: rect, displayID: id, screenFrame: screen.frame,
                scale: screen.backingScaleFactor, targetPID: nil)
            let image = try await CaptureService().capture(region)
            let color = NSBitmapImageRep(cgImage: image).colorAt(x: image.width / 2, y: image.height / 2)!.usingColorSpace(.deviceRGB)!
            guard color.blueComponent > 0.7 && color.redComponent < 0.3 else {
                print("FAIL: ordinary window pixels missing or operation overlay captured: R=\(color.redComponent) G=\(color.greenComponent) B=\(color.blueComponent) allowed=\(CaptureWindowPolicy.includedWindowIDs) base=\(base.windowNumber) overlay=\(overlay.windowNumber)"); exit(1)
            }
            let withPins = try await CaptureService().capture(region, hidePins: false)
            let pinColor = NSBitmapImageRep(cgImage: withPins).colorAt(x: withPins.width / 2, y: withPins.height / 2)!.usingColorSpace(.deviceRGB)!
            // Display color conversion can add red/blue to AppKit green; compare dominance.
            guard pinColor.greenComponent > 0.7,
                  pinColor.greenComponent > pinColor.redComponent + 0.25,
                  pinColor.greenComponent > pinColor.blueComponent + 0.25 else {
                print("FAIL: visible pin pixels missing or operation overlay included: color=\(pinColor) visible=\(pin.isVisible) id=\(pin.windowNumber) included=\(CaptureWindowPolicy.includedWindowIDs(hidePins: false))"); exit(1)
            }
            pin.orderOut(nil)
            try await Task.sleep(for: .milliseconds(150))
            let hiddenPin = try await CaptureService().capture(region, hidePins: false)
            let hiddenColor = NSBitmapImageRep(cgImage: hiddenPin).colorAt(x: hiddenPin.width / 2, y: hiddenPin.height / 2)!.usingColorSpace(.deviceRGB)!
            guard hiddenColor.blueComponent > 0.7 && hiddenColor.greenComponent < 0.3 else {
                print("FAIL: manually hidden pin appeared in screenshot"); exit(1)
            }
            print("PASS: pin pixels included only when visible and toggle off; overlays excluded")
            print("PASS: real screenshot includes own blue ordinary window and excludes covering red panel; pixels discarded")
        } catch { print("FAIL: \(error)"); exit(1) }
    }
}

@MainActor private final class CaptureWindowVerificationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await VerifyCaptureWindows.verify(); NSApp.terminate(nil) }
    }
}
