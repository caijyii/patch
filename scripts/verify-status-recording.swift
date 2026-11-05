import AppKit
import ScreenCaptureKit
import CoreMedia
import Darwin

private final class StatusRecordingSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    private var failure: String?
    var count: Int { lock.lock(); defer { lock.unlock() }; return frames }
    var error: String? { lock.lock(); defer { lock.unlock() }; return failure }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
        // Count and discard the sample; never inspect or save its pixels.
        lock.lock(); frames += 1; lock.unlock()
    }
    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        lock.lock(); failure = error.localizedDescription; lock.unlock()
    }
}

@MainActor private final class StatusRecordingCheck: NSObject, NSApplicationDelegate {
    private var controls: StatusBarControls!
    private var window: NSWindow!
    private var stream: SCStream?
    private let sink = StatusRecordingSink()
    private var originalItem: ObjectIdentifier?
    private var finished = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Status recording verification", action: nil, keyEquivalent: "")
        controls = StatusBarControls(menu: menu)
        originalItem = ObjectIdentifier(controls.item)
        window = NSWindow(contentRect: NSRect(x: 32, y: 80, width: 160, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.backgroundColor = .systemBlue
        window.title = "Patch status verification — own window only"
        window.orderFront(nil)
        Task {
            do {
                try await Task.sleep(for: .milliseconds(700))
                try checkSpacing("before stream")
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let id = CGWindowID(exactly: window.windowNumber),
                      let ownWindow = content.windows.first(where: {
                          $0.windowID == id && $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
                      }) else { throw CheckError(message: "Own test window was not found") }
                let configuration = SCStreamConfiguration()
                configuration.width = 160; configuration.height = 100
                configuration.capturesAudio = false; configuration.captureMicrophone = false
                configuration.showsCursor = false; configuration.queueDepth = 2
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 5)
                let nextStream = SCStream(filter: SCContentFilter(desktopIndependentWindow: ownWindow),
                    configuration: configuration, delegate: sink)
                try nextStream.addStreamOutput(sink, type: .screen,
                    sampleHandlerQueue: DispatchQueue(label: "dev.screenleaf.verify.status-recording.frames"))
                stream = nextStream
                print("SCOPE: own PID \(ProcessInfo.processInfo.processIdentifier), own window \(id); audio off; no video file")
                try await nextStream.startCapture()
                try await Task.sleep(for: .seconds(1))
                try checkSpacing("recording 1 s")
                try await Task.sleep(for: .seconds(2))
                try checkSpacing("recording 3 s")
                try await nextStream.stopCapture(); stream = nil
                try await Task.sleep(for: .milliseconds(400))
                try checkSpacing("after stream")
                guard sink.count > 0, sink.error == nil else { throw CheckError(message: sink.error ?? "No video frames arrived") }
                guard controls.item.menu === controls.menu, controls.menuButton.bounds.width == StatusBarControls.buttonWidth else {
                    throw CheckError(message: "Idle did not remove Stop and its extra space")
                }
                print("PASS: real self-window stream preserved only the Patch menu icon; \(sink.count) frames discarded")
                await finish(code: 0)
            } catch {
                print("FAIL: \(error.localizedDescription)")
                await finish(code: 1)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            guard !self.finished else { return }
            print("FAIL: status recording verification timed out")
            self.controls?.remove(); self.window?.close()
            fflush(stdout); exit(1)
        }
    }

    private func checkSpacing(_ phase: String) throws {
        controls.menuButton.layoutSubtreeIfNeeded()
        let main = controls.menuButton
        guard main.window != nil, ObjectIdentifier(controls.item) == originalItem,
              controls.item.length == StatusBarControls.buttonWidth,
              controls.menuButton.bounds.width == StatusBarControls.buttonWidth,
              controls.item.menu === controls.menu else {
            throw CheckError(message: "Patch duplicated the system recording control")
        }
        print("CHECK: \(phase); one Patch menu icon; frames=\(sink.count)")
        fflush(stdout)
    }

    private func finish(code: Int32) async {
        guard !finished else { return }; finished = true
        if let stream { try? await stream.stopCapture(); self.stream = nil }
        controls?.remove(); window?.close()
        fflush(stdout); exit(code)
    }
}

private struct CheckError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@main private enum VerifyStatusRecording {
    @MainActor static func main() {
        guard CGPreflightScreenCaptureAccess() else {
            print("SKIP: existing screen-capture authorization is required; no permission request was made")
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = StatusRecordingCheck(); app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
