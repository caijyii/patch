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
            guard let window = coordinator.panel, let content = window.contentView else {
                throw RecordingLifecycleFailure(description: "Recording controls have no content")
            }
            content.superview?.layoutSubtreeIfNeeded()
            content.layoutSubtreeIfNeeded()
#if !RECORDING_CANCEL_BASELINE
            try require(window.titlebarAppearsTransparent && window.styleMask.contains(.fullSizeContentView),
                        "Recording glow must extend beneath its transparent title bar")
            let safe = window.contentLayoutRect
            try require(!safe.isEmpty && safe.height < content.bounds.height,
                        "Recording must reserve the native title bar's content-layout inset")
            for view in content.subviews where !view.isHidden && !view.frame.isEmpty {
                let frame = view.convert(view.bounds, to: nil)
                try require(safe.insetBy(dx: -0.5, dy: -0.5).contains(frame),
                            "Recording control overlaps the title bar or escapes native layout bounds in \(name): \(view)")
            }
#endif
            let rendered = content.superview ?? content
            guard let bitmap = rendered.bitmapImageRepForCachingDisplay(in: rendered.bounds) else {
                throw RecordingLifecycleFailure(description: "Recording preview cannot be rendered")
            }
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                rendered.cacheDisplay(in: rendered.bounds, to: bitmap)
            }
            let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".build/verification/recording-lifecycle/\(name).png")
            try bitmap.representation(using: .png, properties: [:])?.write(to: url)
        }
        let systemStop = fixture()
        systemStop.phase = .recording
        systemStop.startedAt = Date().addingTimeInterval(-2)
        systemStop.systemStoppedRecording()
        try require(systemStop.streamStoppedByUser && systemStop.stopRequested && !systemStop.pauseRequested
            && systemStop.failure == nil && systemStop.phase == .stopping && systemStop.stopTask == nil,
            "System Stop must await normal output completion without an error or another stream stop")
        systemStop.releaseSession()
        print("PASS: macOS System Stop enters normal output finalization")

        let compact = fixture()
        try snapshot(compact, name: "controls-idle")
        try require((compact.panel?.frame.width ?? 1000) < 400 && (compact.panel?.frame.height ?? 1000) < 260,
                    "Idle recording controls must fit their content")
        compact.phase = .preparing
        compact.setStatus(L("选择 MP4 保存位置"))
        compact.updateControls()
        let promptWidth = ceil((compact.statusLabel.stringValue as NSString).size(withAttributes: [.font: compact.statusLabel.font ?? NSFont.systemFont(ofSize: 13)]).width)
        try require(compact.statusLabel.frame.width >= promptWidth, "Save-location prompt must fit on one line")
        try snapshot(compact, name: "controls-save-location")
        compact.setStatus(L("录制中"))
        compact.phase = .recording
        compact.updateControls()
        try require((compact.panel?.frame.height ?? 1000) < 260 && (compact.panel?.frame.width ?? 1000) < 400 && compact.audioToolbar.isHidden
                    && compact.startButton.superview == nil && compact.pauseButton.superview != nil && compact.hideButton.superview != nil
                    && !compact.statusLabel.isHidden && compact.exclusionLabel.stringValue == L("控制窗与范围提示不会录入视频"),
                    "Active recording must show its top status, pause/hide/stop and exclusion explanation")
        try snapshot(compact, name: "controls-recording")
        compact.phase = .idle
        compact.failure = ScreenLeafError(message: "合成错误")
        compact.setStatus("未能开始录制，请检查屏幕录制权限后重试。", isError: true)
        compact.updateControls()
        try require((compact.panel?.frame.width ?? 1000) < 400 && compact.settingsButton.superview != nil,
                    "Compact error controls must retain the recovery action")
        try snapshot(compact, name: "controls-error")
        print("PASS: recording controls shrink to their current phase")

#if !RECORDING_CANCEL_BASELINE
        let standard = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let utility = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        standard.isReleasedWhenClosed = false; utility.isReleasedWhenClosed = false
        let controls = compact.panel!
        let controlsClose = controls.standardWindowButton(.closeButton)!.frame.size
        let standardClose = standard.standardWindowButton(.closeButton)!.frame.size
        print("TITLEBAR: recording close=\(controlsClose), standard close=\(standardClose), utility close=\(utility.standardWindowButton(.closeButton)!.frame.size)")
        try require(!controls.styleMask.contains(.utilityWindow) && controlsClose == standardClose
                    && controls.isFloatingPanel && controls.level == .floating && !controls.hidesOnDeactivate,
                    "Recording controls did not retain a standard close button with floating behavior")
        try require(controls.title == L("Patch · 录屏") && controls.titleVisibility == .hidden
                    && !controls.titlebarAccessoryViewControllers.isEmpty,
                    "Recording controls did not adopt the shared leading Patch title")
        standard.close(); utility.close()

        let visible = NSRect(x: -1600, y: 50, width: 1600, height: 900)
        let panelSize = NSSize(width: 320, height: 180)
        let bottomRight = RecordingControlsPlacement.initialFrame(size: panelSize, visibleFrame: visible, avoiding: .null)
        try require(bottomRight == NSRect(x: -336, y: 66, width: 320, height: 180),
                    "Initial placement did not use the negative-coordinate display's bottom-right visible corner")
        let blockedCorner = NSRect(x: -400, y: 50, width: 400, height: 250)
        let avoided = RecordingControlsPlacement.initialFrame(size: panelSize, visibleFrame: visible, avoiding: blockedCorner)
        try require(avoided.minX == visible.minX + 16 && avoided.minY == visible.minY + 16 && !avoided.intersects(blockedCorner),
                    "An occupied bottom-right corner did not choose an unobscured edge")
        try require(RecordingControlsPlacement.initialFrame(size: panelSize, visibleFrame: visible, avoiding: visible) == bottomRight,
                    "A full-screen selection lost stable bottom-right fallback")
        let escaped = NSRect(x: -2000, y: -400, width: 320, height: 180)
        try require(visible.contains(RecordingControlsPlacement.clamped(escaped, to: visible)),
                    "Controls escaped a negative-coordinate visible frame")
        let oversized = RecordingControlsPlacement.clamped(NSRect(x: -2000, y: -400, width: 1800, height: 1000), to: visible)
        try require(oversized.minX == visible.minX && oversized.maxY == visible.maxY,
                    "An unusually small desktop hid the oversized panel's close/title area")
        try require(RecordingControlsPlacement.closestScreenIndex(to: NSRect(x: -1200, y: 100, width: 320, height: 180),
            screens: [NSRect(x: 0, y: 0, width: 1440, height: 900), visible]) == 1,
            "Clamping selected the primary instead of the panel's current display")

        let positioned = fixture()
        let targetScreen = NSScreen.screens.last!
        let targetID = (targetScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value
        positioned.region = CaptureRegion(rect: NSRect(x: targetScreen.frame.midX - 40, y: targetScreen.frame.midY - 40, width: 80, height: 80),
            displayID: targetID, screenFrame: targetScreen.frame, scale: targetScreen.backingScaleFactor, targetPID: nil)
        positioned.setStatus(L("准备录制")); positioned.updateControls(); positioned.placeControlsInitially()
        try require(positioned.panel!.frame == RecordingControlsPlacement.initialFrame(size: positioned.panel!.frame.size,
            visibleFrame: targetScreen.visibleFrame, avoiding: positioned.region!.rect), "Initial native placement ignored the selected display")
        let moved = RecordingControlsPlacement.clamped(NSRect(x: targetScreen.visibleFrame.minX + 48,
            y: targetScreen.visibleFrame.midY, width: positioned.panel!.frame.width, height: positioned.panel!.frame.height),
            to: targetScreen.visibleFrame)
        positioned.panel!.setFrameOrigin(moved.origin)
        let manualTopLeft = NSPoint(x: positioned.panel!.frame.minX, y: positioned.panel!.frame.maxY)
        for phase in [Phase.preparing, .countdown, .recording, .paused, .stopping] {
            positioned.phase = phase; positioned.updateControls()
            try require(positioned.panel!.frame.minX == manualTopLeft.x && positioned.panel!.frame.maxY == manualTopLeft.y,
                        "A recording phase reset the user's manually placed title bar")
        }
        positioned.phase = .idle; positioned.panel?.performClose(nil)
        print("PASS: standard title controls, selected-screen corner avoidance, negative-display clamping and manual-position preservation")

        let indicator = fixture()
        for phase in [Phase.idle, .preparing, .countdown, .starting, .stopping] {
            indicator.phase = phase
            try require(!indicator.hasActiveRecordingSession, "A not-yet-started or saving session exposed the menu-bar Stop action")
        }
        for phase in [Phase.recording, .pausing, .paused] {
            indicator.phase = phase
            try require(indicator.hasActiveRecordingSession, "Active or paused recording lost its menu-bar Stop action")
        }
        indicator.completedSegments = [URL(fileURLWithPath: "/tmp/synthetic-completed-segment.mp4")]
        indicator.phase = .starting
        try require(indicator.hasActiveRecordingSession, "Resuming a paused recording hid its menu-bar Stop action")
        indicator.phase = .stopping
        try require(!indicator.hasActiveRecordingSession, "Exporting completed segments left the menu-bar Stop action visible")
        indicator.releaseSession(); indicator.panel?.performClose(nil)
        print("PASS: menu-bar Stop waits for actual recording, survives pause/resume and hides during saving")
#endif

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

        let closedIdle = fixture()
        closedIdle.panel?.performClose(nil)
        try require(!closedIdle.hasControls && !closedIdle.canShowControls, "Idle close retained its recording panel")
        closedIdle.showControls()
        try require(!closedIdle.hasControls, "Show Controls recreated a closed session")

        let closedPreparation = fixture()
        closedPreparation.phase = .preparing
        let closedPreparationID = closedPreparation.sessionID
        closedPreparation.panel?.performClose(nil)
        try require(!closedPreparation.isRecording && !closedPreparation.hasControls
                    && closedPreparation.sessionID != closedPreparationID,
                    "Closing preparation did not cancel and release the recording session")
        print("PASS: idle/preparing close releases controls and stale Show Controls cannot recreate them")

        let countdown = fixture()
        countdown.phase = .preparing
        let countdownID = countdown.sessionID
        var ticks: [String] = []
        countdown.countdownSleep = {
            ticks.append(countdown.statusText)
            try require(countdown.stream == nil && countdown.recordingOutput == nil && countdown.elapsedSeconds == 0,
                        "Countdown started media capture or counted recording time")
            try require(countdown.regionOverlay.window?.isVisible == true,
                        "Countdown did not show the recording region guide")
        }
        try await countdown.runCountdown(id: countdownID)
        try require(ticks == [LF("%d 秒后开始录制", 3), LF("%d 秒后开始录制", 2), LF("%d 秒后开始录制", 1)],
                    "Countdown did not show exactly three one-second stages")
        countdown.stop()
        try require(!countdown.isRecording && countdown.stream == nil && countdown.sessionID != countdownID
                    && countdown.regionOverlay.window == nil,
                    "Countdown cancellation did not invalidate capture startup")
        let cancelledCountdown = fixture()
        cancelledCountdown.phase = .preparing
        let abandonedID = cancelledCountdown.sessionID
        var sleeps = 0
        cancelledCountdown.countdownSleep = { sleeps += 1; cancelledCountdown.panel?.performClose(nil) }
        do {
            try await cancelledCountdown.runCountdown(id: abandonedID)
            throw RecordingLifecycleFailure(description: "Cancelled countdown completed")
        } catch is CancellationError {}
        try require(sleeps == 1 && !cancelledCountdown.isRecording && cancelledCountdown.stream == nil
                    && !cancelledCountdown.hasControls && cancelledCountdown.regionOverlay.window == nil,
                    "Countdown continued after cancellation")
        print("PASS: cancellable three-stage countdown never captures or counts preparation time")

        let paused = fixture()
        paused.regionOverlay.show(region: paused.region!)
        paused.phase = .recording; paused.startedAt = Date().addingTimeInterval(-4)
        paused.togglePause()
        let frozen = paused.elapsedSeconds
        try require(paused.phase == .pausing && !paused.canPauseOrResume && paused.pauseRequested,
                    "Pause allowed resume before segment finalization")
        paused.togglePause()
        try await Task.sleep(for: .milliseconds(40))
        try require(paused.phase == .pausing && paused.elapsedSeconds == frozen, "Pausing kept counting or accepted a second transition")
        let segmentURL = URL(fileURLWithPath: "/tmp/patch-inert-complete-segment.mp4")
        paused.acceptCompletedSegment(at: segmentURL, duration: 4.25, id: paused.sessionID)
        try require(paused.isPaused && paused.canPauseOrResume && paused.elapsedSeconds == 4.25
                    && paused.completedSegments == [segmentURL] && paused.stream == nil,
                    "Completed pause lost the recording, allowed a gap or retained its stream")
        paused.hideControls()
        try require(paused.isPaused && paused.hasControls && paused.completedSegments == [segmentURL],
                    "Hiding controls ended or reset the paused recording")
        try require(paused.canShowControls && paused.regionOverlay.window?.isVisible == true,
                    "Hide removed the recording guide or the Show Controls recovery action")
        try await Task.sleep(for: .milliseconds(40))
        try require(paused.elapsedSeconds == 4.25, "Paused wall time entered the elapsed clock")
        paused.releaseSession()
        try require(paused.regionOverlay.window == nil, "Session release retained its overlay")
        print("PASS: pause waits for segment completion, freezes time and preserves recording when controls hide")

        let raceDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("Patch-Recording-Races-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: raceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: raceDirectory) }
        func completedFixture(_ name: String) throws -> (RecordingCoordinator, URL) {
            let coordinator = fixture()
            let directory = raceDirectory.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let segment = directory.appendingPathComponent("segment.mp4")
            // File-storage race tests use inert bytes. Media correctness is covered
            // separately with synthetic video/audio by verify-recording-segments.
            try Data("completed-test-segment".utf8).write(to: segment)
            coordinator.workingDirectory = directory; coordinator.workingURL = segment
            coordinator.destinationURL = raceDirectory.appendingPathComponent("\(name).mp4")
            return (coordinator, segment)
        }
        func awaitIdle(_ coordinator: RecordingCoordinator) async throws {
            for _ in 0..<500 where coordinator.isRecording { try await Task.sleep(for: .milliseconds(10)) }
            try require(!coordinator.isRecording && coordinator.failure == nil, "Recording did not finish its synthetic commit")
            coordinator.hideControls()
        }
        let (resumed, resumedURL) = try completedFixture("queued-resume")
        resumed.phase = .paused; resumed.completedSegments = [resumedURL]; resumed.completedDuration = 2
        resumed.togglePause()
        guard let resumeTask = resumed.preparationTask else { throw RecordingLifecycleFailure(description: "Resume task missing") }
        resumed.stop()
        await resumeTask.value
        try await awaitIdle(resumed)
        try require(resumed.stream == nil && FileManager.default.fileExists(atPath: raceDirectory.appendingPathComponent("queued-resume.mp4").path),
                    "Stopping a queued resume lost completed footage or started capture")
        print("PASS: stop before a queued resume saves existing segments without starting capture")

        let (earlyFinish, earlyURL) = try completedFixture("finish-before-start")
        let outputConfiguration = SCRecordingOutputConfiguration(); outputConfiguration.outputURL = earlyURL
        let inertOutput = SCRecordingOutput(configuration: outputConfiguration, delegate: earlyFinish)
        earlyFinish.phase = .starting; earlyFinish.recordingOutput = inertOutput
        var startReply: CheckedContinuation<Void, Error>?
        let suspendedStart = Task { @MainActor in try await withCheckedThrowingContinuation { startReply = $0 } }
        earlyFinish.captureStartTask = suspendedStart
        earlyFinish.stopTask = Task {} // No real stream exists in this test.
        while startReply == nil { await Task.yield() }
        earlyFinish.didFinish(inertOutput)
        earlyFinish.didStart(inertOutput) // Late start must not change state or start the timer.
        await Task.yield()
        try require(earlyFinish.completedSegments.isEmpty && earlyFinish.timer == nil,
                    "Output finalized before startup completed or late start restarted the clock")
        earlyFinish.panel?.performClose(nil)
        try require(earlyFinish.closeRequested && !earlyFinish.canShowControls && earlyFinish.isRecording,
                    "Closing startup discarded its in-flight output or offered to reopen closed controls")
        startReply?.resume()
        try await awaitIdle(earlyFinish)
        try require(FileManager.default.fileExists(atPath: raceDirectory.appendingPathComponent("finish-before-start.mp4").path)
                    && !earlyFinish.hasControls,
                    "Finish-before-start discarded the completed output")
        print("PASS: early output completion waits for start and ignores a late start callback")

        let (pauseThenStop, pauseURL) = try completedFixture("stop-during-pause")
        pauseThenStop.phase = .recording; pauseThenStop.startedAt = Date().addingTimeInterval(-1)
        pauseThenStop.togglePause(); pauseThenStop.panel?.performClose(nil)
        pauseThenStop.acceptCompletedSegment(at: pauseURL, duration: 1, id: pauseThenStop.sessionID)
        try require(pauseThenStop.phase == .stopping && !pauseThenStop.isPaused,
                    "Pause completion ignored a later stop request")
        try await awaitIdle(pauseThenStop)
        try require(!pauseThenStop.hasControls, "Closing during pause reopened controls after saving")
        print("PASS: stop during pause takes precedence and saves exactly once")

        let (closedPaused, closedPausedURL) = try completedFixture("close-paused")
        closedPaused.phase = .paused; closedPaused.completedSegments = [closedPausedURL]
        closedPaused.regionOverlay.show(region: closedPaused.region!)
        closedPaused.panel?.performClose(nil)
        try require(closedPaused.regionOverlay.window == nil && !closedPaused.canShowControls,
                    "Closing paused recording retained the guide or restore action")
        try await awaitIdle(closedPaused)
        try require(!closedPaused.hasControls && FileManager.default.fileExists(atPath: raceDirectory.appendingPathComponent("close-paused.mp4").path),
                    "Closing paused recording did not save and dismiss")

        let (closedSaving, closedSavingURL) = try completedFixture("close-saving")
        closedSaving.phase = .paused; closedSaving.completedSegments = [closedSavingURL]
        closedSaving.stop(); closedSaving.panel?.performClose(nil)
        try await awaitIdle(closedSaving)
        try require(!closedSaving.hasControls && FileManager.default.fileExists(atPath: raceDirectory.appendingPathComponent("close-saving.mp4").path),
                    "Closing while saving canceled the file commit or reopened controls")
        print("PASS: closing paused/saving sessions commits media and does not reopen successful controls")

        let (failedClose, failedCloseURL) = try completedFixture("failed-close")
        failedClose.phase = .paused; failedClose.completedSegments = [failedCloseURL]
        failedClose.destinationURL = raceDirectory.appendingPathComponent("missing-parent/failed.mp4")
        failedClose.panel?.performClose(nil)
        for _ in 0..<500 where failedClose.isRecording { try await Task.sleep(for: .milliseconds(10)) }
        try require(!failedClose.isRecording && failedClose.failure != nil && failedClose.panel?.isVisible == true
                    && failedClose.recoverableSession?.files == [failedCloseURL]
                    && FileManager.default.fileExists(atPath: failedCloseURL.path)
                    && failedClose.retrySaveButton.superview != nil && failedClose.statusText != L("准备录制")
                    && failedClose.regionOverlay.window == nil && !failedClose.canShowControls,
                    "Save failure after close lost originals, hid recovery or overwrote its error with Ready")
        failedClose.panel?.performClose(nil)
        try require(!failedClose.hasControls && FileManager.default.fileExists(atPath: failedCloseURL.path),
                    "Dismissing failure recovery deleted originals")
        print("PASS: save failure after Close restores visible retry controls and preserves original files")

        let negativeRegion = CaptureRegion(rect: CGRect(x: -1200, y: 180, width: 300, height: 200),
            displayID: 0, screenFrame: CGRect(x: -1280, y: 100, width: 1280, height: 800), scale: 2, targetPID: nil)
        let outline = RecordingRegionOverlay()
        outline.show(region: negativeRegion)
        let overlayWindow = outline.window!
        try require(overlayWindow.frame == negativeRegion.screenFrame && overlayWindow.ignoresMouseEvents
                    && !overlayWindow.canBecomeKey && !overlayWindow.canBecomeMain && !overlayWindow.isOpaque
                    && overlayWindow.collectionBehavior.contains(.canJoinAllSpaces)
                    && overlayWindow.collectionBehavior.contains(.fullScreenAuxiliary),
                    "Recording guide has incorrect secondary-display placement or intercepts input")
        let overlayView = overlayWindow.contentView!
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1280, pixelsHigh: 800,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.cgContext.clear(overlayView.bounds)
        overlayView.draw(overlayView.bounds)
        NSGraphicsContext.restoreGraphicsState()
        var clearPixels = 0, shadedPixels = 0
        for y in stride(from: 0, to: 800, by: 4) { for x in stride(from: 0, to: 1280, by: 4) {
            let alpha = bitmap.colorAt(x: x, y: y)!.alphaComponent
            if alpha < 0.01 { clearPixels += 16 }
            if alpha > 0.12 && alpha < 0.2 { shadedPixels += 16 }
        } }
        try require(clearPixels > 56000 && clearPixels < 61000 && shadedPixels > 900000,
                    "The recording region is not transparent or its outside mask is not light")
        let guideOutput = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/verification/recording-lifecycle")
        try bitmap.representation(using: .png, properties: [:])?.write(to: guideOutput.appendingPathComponent("region-overlay-transparent.png"))
        let preview = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1280, pixelsHigh: 800,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: preview)
        NSColor.white.setFill(); overlayView.bounds.fill()
        overlayView.draw(overlayView.bounds)
        NSGraphicsContext.restoreGraphicsState()
        try preview.representation(using: .png, properties: [:])?.write(to: guideOutput.appendingPathComponent("region-overlay-white.png"))
        outline.close()
        try require(outline.window == nil, "Overlay close retained its window")
        try require(Self.canExcludeRecordingWindows(required: [11, 22], available: [11, 22, 33])
                    && !Self.canExcludeRecordingWindows(required: [11, 22], available: [11]),
                    "Capture fallback accepts a missing protected recording window")
        let changedDisplay = fixture()
        changedDisplay.phase = .countdown; changedDisplay.regionOverlay.show(region: changedDisplay.region!)
        changedDisplay.screenParametersChanged() // Synthetic display ID 0 is absent.
        try require(!changedDisplay.isRecording && changedDisplay.regionOverlay.window == nil,
                    "An unavailable display left countdown or its guide active")
        print("PASS: transparent region/light mask, negative-display placement, click-through and exclusion/cleanup guards")

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
        weak let previousStream = inertStream
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
            for name in ["idle", "preparing", "countdown", "recording", "paused", "saved", "error"] {
                preview.phase = ["preparing": .preparing, "countdown": .countdown, "recording": .recording, "paused": .paused][name] ?? .idle
                preview.revealURL = ["saved", "error"].contains(name) ? URL(fileURLWithPath: "/tmp/小贴录屏.mp4") : nil
                preview.failure = name == "error" ? ScreenLeafError(message: "录屏权限不可用") : nil
                preview.fileLabel.stringValue = preview.revealURL?.path ?? ""
                let status = ["idle": L("准备录制"), "preparing": L("选择 MP4 保存位置"), "countdown": LF("%d 秒后开始录制", 3),
                    "recording": L("录制中"), "paused": L("已暂停"), "saved": L("录屏已保存。"),
                    "error": L("录制未完成，正在结束…")][name]!
                preview.setStatus(status, isError: name == "error")
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
        if ProcessInfo.processInfo.environment["SCREENLEAF_TEST_LANGUAGE"] == "en" { AppLocalization.language = .english }
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
