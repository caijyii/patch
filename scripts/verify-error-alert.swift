import AppKit
import Darwin
@MainActor final class Probe: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.deactivate()
            var active = false
            var visible = false
            let timer = Timer(timeInterval: 0.8, repeats: false) { _ in
                MainActor.assumeIsolated {
                    active = NSApp.isActive
                    visible = NSApp.modalWindow?.isVisible == true && NSApp.modalWindow?.isKeyWindow == true
                    NSApp.stopModal()
                }
            }
            RunLoop.main.add(timer, forMode: .modalPanel)
            showError(PatchError(message: "Synthetic empty clipboard"), title: "Test error")
            print("\(active && visible ? "PASS" : "FAIL"): background error alert active=\(active) keyAndVisible=\(visible)")
            exit(active && visible ? 0 : 1)
        }
    }
}
@main struct Main {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = Probe()
        app.setActivationPolicy(.accessory); app.delegate = delegate
        app.run(); withExtendedLifetime(delegate) {}
    }
}
