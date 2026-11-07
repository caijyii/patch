import AppKit
import ScreenCaptureKit
import Darwin

@MainActor private final class RecordingPinFixture: NSPanel, CapturePinWindow {}
@MainActor private final class RecordingPinCheck: NSObject, NSApplicationDelegate {
    private var windows: [NSWindow] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        let frame = CGRect(x: 60, y: 100, width: 180, height: 120)
        if CommandLine.arguments.contains("--backdrop") {
            let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.backgroundColor = .blue; window.isReleasedWhenClosed = false
            windows = [window]; window.orderFrontRegardless()
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            print("SKIP: existing screen capture access required; no permission requested"); exit(0)
        }
        let backdrop = Process()
        backdrop.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]); backdrop.arguments = ["--backdrop"]
        do { try backdrop.run() } catch { print("FAIL: backdrop: \(error)"); exit(1) }
        let pin = RecordingPinFixture(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        let overlay = NSPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        for window in [pin, overlay] { window.isReleasedWhenClosed = false; window.hidesOnDeactivate = false }
        pin.backgroundColor = .green; pin.level = .floating
        overlay.backgroundColor = .red; overlay.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        windows = [pin, overlay]
        Task {
            do {
                try await Task.sleep(for: .milliseconds(500))
                pin.orderFrontRegardless(); overlay.orderFrontRegardless()
                try await Task.sleep(for: .milliseconds(300))
                for hide in [true, false] {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                    let screen = pin.screen!
                    let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value
                    let display = content.displays.first { $0.displayID == displayID }!
                    let region = CaptureRegion(rect: frame, displayID: displayID, screenFrame: screen.frame, scale: 1, targetPID: nil)
                    let config = SCStreamConfiguration()
                    config.sourceRect = region.sourceRect; config.width = 180; config.height = 120; config.showsCursor = false
                    let image = try await SCScreenshotManager.captureImage(contentFilter: RecordingCoordinator.captureFilter(content: content, display: display, hidePins: hide), configuration: config)
                    let c = NSBitmapImageRep(cgImage: image).colorAt(x: 90, y: 60)!.usingColorSpace(.deviceRGB)!
                    let passed = hide ? c.blueComponent > 0.7 && c.redComponent < 0.3
                        : c.greenComponent > 0.7 && c.greenComponent > c.redComponent + 0.25 && c.greenComponent > c.blueComponent + 0.25
                    guard passed else { throw PatchError(message: "Recording filter hide=\(hide) produced \(c)") }
                }
                print("PASS: production recording filter hides/shows pin pixels and always excludes operation panels; pixels discarded")
                backdrop.terminate(); windows.forEach { $0.close() }; exit(0)
            } catch {
                backdrop.terminate(); windows.forEach { $0.close() }
                print("FAIL: \(error)"); exit(1)
            }
        }
    }
}
@main struct VerifyRecordingPins {
    @MainActor static func main() {
        let app = NSApplication.shared, delegate = RecordingPinCheck()
        app.setActivationPolicy(.accessory); app.delegate = delegate; app.run()
        withExtendedLifetime(delegate) {}
    }
}
