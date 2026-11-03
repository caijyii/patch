// Concatenated with Recording.swift. No capture, system input or TCC requests.
import Darwin

private struct RecordingLifecycleFailure: Error, CustomStringConvertible {
    let description: String
}

extension RecordingCoordinator {
    fileprivate static func verifyLifecycle() async throws {
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw RecordingLifecycleFailure(description: message) }
        }
        func fixture() -> RecordingCoordinator {
            let coordinator = RecordingCoordinator()
            coordinator.region = CaptureRegion(rect: CGRect(x: 0, y: 0, width: 400, height: 300),
                displayID: 0, screenFrame: CGRect(x: 0, y: 0, width: 400, height: 300),
                scale: 1, targetPID: nil)
            coordinator.buildPanel() // Construct controls without showing a window.
            return coordinator
        }

        func snapshot(_ coordinator: RecordingCoordinator, name: String) throws {
            guard let content = coordinator.panel?.contentView,
                  let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".build/verification/recording-lifecycle/\(name).png")
            try bitmap.representation(using: .png, properties: [:])?.write(to: url)
        }
        let compact = fixture()
        try snapshot(compact, name: "controls-idle")
        try require((compact.panel?.frame.width ?? 1000) < 400 && (compact.panel?.frame.height ?? 1000) < 260,
                    "Idle recording controls must fit their content")
        compact.phase = .preparing
        compact.setStatus("选择 MP4 保存位置")
        compact.updateControls()
        let promptWidth = ceil((compact.statusLabel.stringValue as NSString).size(withAttributes: [.font: compact.statusLabel.font ?? NSFont.systemFont(ofSize: 13)]).width)
        try require(compact.statusLabel.frame.width >= promptWidth, "Save-location prompt must fit on one line")
        try snapshot(compact, name: "controls-save-location")
        compact.setStatus("")
        compact.phase = .recording
        compact.updateControls()
        try require((compact.panel?.frame.height ?? 1000) < 150 && (compact.panel?.frame.width ?? 1000) < 200 && compact.audioToolbar.isHidden
                    && compact.startButton.superview == nil, "Active recording must show compact stop controls")
        try snapshot(compact, name: "controls-recording")
        compact.phase = .idle
        compact.failure = ScreenLeafError(message: "合成错误")
        compact.setStatus("未能开始录制，请检查屏幕录制权限后重试。", isError: true)
        compact.updateControls()
        try require((compact.panel?.frame.width ?? 1000) < 400 && compact.settingsButton.superview != nil,
                    "Compact error controls must retain the recovery action")
        try snapshot(compact, name: "controls-error")
        print("PASS: recording controls shrink to their current phase")

        let waiting = fixture()
        waiting.phase = .preparing
        let cancelledID = waiting.sessionID
        var permissionReply: CheckedContinuation<Void, Never>?
        let suspended = Task { @MainActor in
            await withCheckedContinuation { permissionReply = $0 }
        }
        waiting.preparationTask = suspended
        while permissionReply == nil { await Task.yield() }
        waiting.stop()
        try require(!waiting.isRecording && waiting.startButton.isEnabled,
                    "Cancelling a suspended permission request must immediately enable retry")
        try require(suspended.isCancelled && waiting.sessionID != cancelledID,
                    "Cancelled preparation must be invalidated before a late reply")
        permissionReply?.resume()
        await suspended.value
        print("PASS: cancelling suspended preparation immediately releases controls")

#if !RECORDING_CANCEL_BASELINE
        // Run the real start task, then cancel before it gets an actor turn.
        let queued = fixture()
        queued.startPressed()
        guard let queuedTask = queued.preparationTask else {
            throw RecordingLifecycleFailure(description: "Missing preparation task")
        }
        queued.stop()
        await queuedTask.value
        try require(!queued.isRecording && queued.savePanel == nil && queued.panel?.attachedSheet == nil,
                    "A cancelled queued task opened a save sheet")
        print("PASS: cancelling before task execution never opens a save sheet")

        // An old permission reply arrives while a different session owns a stream.
        // The stream is only an inert object; startCapture is never called.
        let newer = fixture()
        let oldID = newer.sessionID
        newer.phase = .preparing
        newer.stop()
        newer.phase = .starting
        newer.stopRequested = false
        let newID = newer.sessionID
        let newStream = SCStream(filter: SCContentFilter(), configuration: SCStreamConfiguration(), delegate: nil)
        newer.stream = newStream
        let newDestination = URL(fileURLWithPath: "/tmp/patch-lifecycle-new.mp4")
        newer.destinationURL = newDestination
        let newSheet = NSSavePanel()
        newer.savePanel = newSheet
        do {
            try newer.checkPreparation(id: oldID)
            throw RecordingLifecycleFailure(description: "Stale preparation was accepted")
        } catch is CancellationError {
            newer.cancelPreparation(id: oldID)
        }
        // Rejected permission and a cancelled chooser also use existing ID guards.
        newer.fail(ScreenLeafError(message: "Late permission rejection"), id: oldID)
        newer.resetAfterCancellation(id: oldID)
        try require(newer.sessionID == newID && newer.phase == .starting && !newer.stopRequested
                    && newer.stream === newStream && newer.destinationURL == newDestination
                    && newer.savePanel === newSheet,
                    "An old authorization/chooser completion changed the next session")
        newer.releaseSession()
        newer.savePanel = nil
        print("PASS: stale preparation replies cannot stop or reset a newer session")

        let starting = fixture()
        starting.phase = .starting
        starting.stop()
        try require(starting.isRecording && starting.phase == .stopping && starting.stopRequested
                    && !starting.startButton.isEnabled && starting.stopTask == nil,
                    "Stopping during start must wait for capture startup and file finalization")
        starting.releaseSession()
        print("PASS: stopping a starting capture keeps finalization pending")

        let chooserCancelled = fixture()
        chooserCancelled.phase = .preparing
        chooserCancelled.resetAfterCancellation(id: chooserCancelled.sessionID)
        try require(!chooserCancelled.isRecording && chooserCancelled.startButton.isEnabled
                    && !chooserCancelled.stopButton.isEnabled,
                    "Cancelling a save chooser must restore idle controls")
        print("PASS: save chooser cancellation restores idle controls")

        let released = fixture()
        var inertStream: SCStream? = SCStream(filter: SCContentFilter(), configuration: SCStreamConfiguration(), delegate: nil)
        weak var previousStream = inertStream
        released.stream = inertStream
        inertStream = nil
        let clock = Timer(timeInterval: 1, repeats: true) { _ in }
        released.timer = clock
        released.destinationURL = URL(fileURLWithPath: "/tmp/patch-resource-destination.mp4")
        released.workingURL = URL(fileURLWithPath: "/tmp/patch-resource-working.mp4")
        released.releaseSession()
        try require(previousStream == nil && !clock.isValid && released.timer == nil
                    && released.recordingOutput == nil && released.preparationTask == nil
                    && released.captureStartTask == nil && released.stopTask == nil
                    && released.finalizationTask == nil && released.destinationURL == nil
                    && released.workingURL == nil && !released.isRecording,
                    "Session release retained a stream, timer, task or working URL")
        print("PASS: session release deallocates the inert stream and clears timers/tasks/URLs")

        let audio = fixture()
        audio.systemAudioToggle.performClick(nil)
        audio.microphoneToggle.performClick(nil)
        try require(audio.systemAudioToggle.state == .off && audio.microphoneToggle.state == .on,
                    "Audio controls must independently toggle their recording options")
        audio.phase = .recording
        audio.updateControls()
        try require(!audio.systemAudioToggle.isEnabled && !audio.microphoneToggle.isEnabled,
                    "Audio controls must stay locked during recording")
        audio.phase = .idle
        audio.updateControls()
        try require(audio.systemAudioToggle.state == .off && audio.microphoneToggle.state == .on,
                    "Returning to idle must preserve selected audio options")
        print("PASS: audio toggles preserve independent selection across recording states")

        if let directory = ProcessInfo.processInfo.environment["SCREENLEAF_RECORDING_PREVIEW_DIR"] {
            let output = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let preview = fixture()
            for name in ["idle", "preparing", "recording", "saved", "error"] {
                preview.phase = name == "preparing" ? .preparing : name == "recording" ? .recording : .idle
                preview.revealURL = ["saved", "error"].contains(name) ? URL(fileURLWithPath: "/tmp/小贴录屏.mp4") : nil
                preview.failure = name == "error" ? ScreenLeafError(message: "录屏权限不可用") : nil
                preview.regionLabel.stringValue = "已选区域：800 × 600 像素 · MP4 · 30 fps"
                preview.fileLabel.stringValue = preview.revealURL?.path ?? ""
                preview.setStatus(name == "error" ? "录屏权限不可用，请在系统设置中检查屏幕录制权限后重试。" : name == "saved" ? "录屏已保存。" : "选择需要录制的声音，开始时可选择保存位置。", isError: name == "error")
                preview.updateControls()
                let content = preview.panel!.contentView!
                // Give the offscreen content cache the opaque window backdrop.
                preview.panel!.appearance = NSAppearance(named: .aqua)
                content.wantsLayer = true
                content.layer?.backgroundColor = NSColor(calibratedWhite: 0.93, alpha: 1).cgColor
                content.layoutSubtreeIfNeeded()
                guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
                    throw RecordingLifecycleFailure(description: "Cannot render recording preview")
                }
                content.cacheDisplay(in: content.bounds, to: bitmap)
                let composed = NSImage(size: content.bounds.size)
                composed.lockFocus()
                preview.panel!.backgroundColor.setFill()
                content.bounds.fill()
                bitmap.draw(in: content.bounds)
                composed.unlockFocus()
                guard let tiff = composed.tiffRepresentation,
                      let rendered = NSBitmapImageRep(data: tiff),
                      let png = rendered.representation(using: .png, properties: [:]) else {
                    throw RecordingLifecycleFailure(description: "Cannot encode recording preview")
                }
                try png.write(to: output.appendingPathComponent("recording-\(name).png"))
            }
        }
#endif
    }
}

@main private struct RecordingLifecycleVerification {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                try await RecordingCoordinator.verifyLifecycle()
                print("COMPLETE: recording lifecycle verification")
                fflush(stdout)
                exit(0)
            } catch {
                print("FAIL: \(error)")
                fflush(stdout)
                exit(1)
            }
        }
        app.run()
    }
}
