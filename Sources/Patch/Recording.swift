// SPDX-FileCopyrightText: 2026 caijyii
// SPDX-License-Identifier: MIT

import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Owns every segment until its output delegate confirms the file is complete.
@MainActor
final class RecordingCoordinator: NSObject {
    private enum Phase { case idle, preparing, countdown, starting, recording, pausing, paused, stopping }
    private var phase: Phase = .idle
    private var panel: NSPanel?
    private var needsInitialPlacement = true
    private var isPositioningControls = false
    private var clampAfterMove: DispatchWorkItem?
    private var closeRequested = false
    private let regionOverlay = RecordingRegionOverlay()
    private var displayObserver: NSObjectProtocol?
    private var region: CaptureRegion?
    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var preparationTask: Task<Void, Never>?
    private var captureStartTask: Task<Void, Error>?
    private var stopTask: Task<Void, Never>?
    private var finalizationTask: Task<Void, Never>?
    private var savePanel: NSSavePanel?
    private var timer: Timer?
    private var startedAt: Date?
    private var sessionID = UUID()
    private var streamHasStarted = false
    private var streamStoppedByUser = false
    private var stopRequested = false
    private var pauseRequested = false
    private var failure: Error?
    private var destinationURL: URL?
    private var workingURL: URL?
    private var workingDirectory: URL?
    private var completedSegments: [URL] = []
    private var completedDuration: TimeInterval = 0
    private var frozenSegmentDuration: TimeInterval?
    private var revealURL: URL?
    private var recoverableSession: (files: [URL], directory: URL)?
    private var recordsSystemAudio = true
    private var recordsMicrophone = false
    private var countdownSleep: () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }

    var onStateChange: (() -> Void)?
    var onCompletedVideo: ((URL) -> Void)?
    /// Includes preparation, countdown, pauses and finalization, so quitting can wait safely.
    var isRecording: Bool { phase != .idle }
    /// The menu-bar Stop action appears only after recording actually begins.
    /// Completed segments keep it available while a paused session resumes.
    var hasActiveRecordingSession: Bool {
        switch phase {
        case .recording, .pausing, .paused: return true
        case .starting: return !completedSegments.isEmpty
        case .idle, .preparing, .countdown, .stopping: return false
        }
    }
    var hasControls: Bool { panel != nil }
    var canShowControls: Bool { isRecording && !closeRequested && panel?.isVisible == false }
    var isPaused: Bool { phase == .paused }
    var canPauseOrResume: Bool { phase == .recording || phase == .paused }
    var statusText: String { statusLabel.stringValue }
    var elapsedSeconds: TimeInterval {
        completedDuration + (frozenSegmentDuration ?? currentSegmentDuration)
    }

    private let systemAudioToggle = SelectionButton(L("系统声音"), symbol: "speaker.wave.2") {}
    private let microphoneToggle = SelectionButton(L("麦克风"), symbol: "mic") {}
    private lazy var startButton = SelectionButton(L("开始录制"), symbol: "record.circle") { [weak self] in self?.startPressed() }
    private lazy var stopButton = SelectionButton(L("停止录制"), symbol: "stop") { [weak self] in self?.stop() }
    private lazy var pauseButton = SelectionButton(L("暂停录制"), symbol: "pause") { [weak self] in self?.togglePause() }
    private lazy var hideButton = SelectionButton(L("隐藏控制窗"), symbol: "eye.slash") { [weak self] in self?.hideControls() }
    private lazy var revealButton = SelectionButton(L("在 Finder 中显示"), symbol: "folder") { [weak self] in self?.revealPressed() }
    private lazy var retrySaveButton = SelectionButton(L("重新保存"), symbol: "square.and.arrow.down") { [weak self] in self?.retrySave() }
    private lazy var settingsButton = SelectionButton(L("打开系统设置"), symbol: "gearshape") { [weak self] in self?.settingsPressed() }
    private let audioToolbar = SelectionToolbar()
    private let actionToolbar = SelectionToolbar()
    private let durationLabel = NSTextField(labelWithString: "00:00")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let fileLabel = NSTextField(wrappingLabelWithString: "")
    private let exclusionLabel = NSTextField(wrappingLabelWithString: L("控制窗与范围提示不会录入视频"))

    override init() {
        super.init()
        systemAudioToggle.setButtonType(.pushOnPushOff)
        microphoneToggle.setButtonType(.pushOnPushOff)
        systemAudioToggle.state = .on; microphoneToggle.state = .off
        systemAudioToggle.toolTip = L("开启或关闭系统声音录制")
        microphoneToggle.toolTip = L("开启或关闭麦克风录制")
        revealButton.toolTip = L("在 Finder 中显示录屏文件")
        settingsButton.toolTip = L("打开系统设置以检查录屏权限")
        hideButton.toolTip = L("隐藏后可从菜单栏恢复控制窗或停止录制")
        displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screenParametersChanged() }
            }
    }

    deinit {
        clampAfterMove?.cancel()
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) }
    }

    func showControls(region: CaptureRegion) {
        if !isRecording {
            self.region = region; closeRequested = false
            needsInitialPlacement = true
            if panel == nil { buildPanel(); setStatus(L("准备录制")) }
        }
        showControls()
    }
    func showControls() {
        guard let panel, !closeRequested else { return }
        WindowActivationCoordinator.shared.register(panel)
        updateControls()
        if needsInitialPlacement { placeControlsInitially() }
        else { clampControlsToScreen() }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        onStateChange?()
    }
    func hideControls() {
        if let panel {
            panel.orderOut(nil)
            WindowActivationCoordinator.shared.unregister(panel)
        }
        onStateChange?()
    }

    private func dismissControls() {
        let oldPanel = panel
        panel = nil; region = nil; closeRequested = false
        needsInitialPlacement = true; clampAfterMove?.cancel(); clampAfterMove = nil
        oldPanel?.delegate = nil; oldPanel?.close()
        regionOverlay.close()
        onStateChange?()
    }

    private func screenParametersChanged() {
        clampControlsToScreen()
        guard isRecording, let region else { return }
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == region.displayID
        }), screen.frame == region.screenFrame, screen.backingScaleFactor == region.scale else {
            // Existing segments keep their original size. A changed display must
            // not resume with a different crop or silently move the region guide.
            regionOverlay.close()
            stop()
            return
        }
    }

    func togglePause() {
        guard failure == nil else { return }
        if phase == .recording {
            pauseRequested = true
            frozenSegmentDuration = currentSegmentDuration
            phase = .pausing
            stopClock()
            setStatus(L("正在暂停…"))
            updateControls()
            if streamHasStarted { requestStreamStop() }
        } else if phase == .paused {
            pauseRequested = false; frozenSegmentDuration = nil
            phase = .starting
            setStatus(L("正在继续录制…")); updateControls()
            let id = sessionID
            preparationTask = Task { [weak self] in
                guard let self else { return }
                do { try await self.startSegment(id: id) }
                catch { self.fail(error, id: id) }
                if self.sessionID == id { self.preparationTask = nil }
            }
        }
    }

    func stop() {
        regionOverlay.close()
        guard isRecording, failure == nil, !stopRequested else { return }
        stopRequested = true
        if phase == .preparing || phase == .countdown {
            preparationTask?.cancel(); savePanel?.cancel(nil)
            resetAfterCancellation(id: sessionID)
            return
        }
        let wasPaused = phase == .paused
        phase = .stopping
        frozenSegmentDuration = currentSegmentDuration
        stopClock()
        setStatus(L("正在结束录制并保存文件…")); updateControls()
        if wasPaused { finishRecording(id: sessionID) }
        else if streamHasStarted { requestStreamStop() }
        // A start or pause already in flight completes before this request is finalized.
    }

    private func buildPanel() {
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        PatchWindowTitle.apply(to: window, title: L("Patch · 录屏"))
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.isFloatingPanel = true; window.level = .floating; window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; window.delegate = self
        window.backgroundColor = WindowAmbientBackground.color
        let content = WindowAmbientView()
        content.glowRadiusScale = 0.55
        window.contentView = content
        for view in [statusLabel, durationLabel, fileLabel, exclusionLabel, audioToolbar, actionToolbar] { content.addSubview(view) }
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.maximumNumberOfLines = 4
        durationLabel.font = .monospacedDigitSystemFont(ofSize: 26, weight: .medium)
        fileLabel.font = .systemFont(ofSize: 11); fileLabel.textColor = .secondaryLabelColor
        fileLabel.lineBreakMode = .byTruncatingMiddle; fileLabel.maximumNumberOfLines = 1
        exclusionLabel.font = .systemFont(ofSize: 11); exclusionLabel.textColor = .secondaryLabelColor
        panel = window; needsInitialPlacement = true
        audioToolbar.onDisplayMetricsChanged = { [weak self] in self?.layoutControls() }
        actionToolbar.onDisplayMetricsChanged = { [weak self] in self?.layoutControls() }
        updateControls()
    }

    private func updateControls() {
        let idle = phase == .idle
        let cancellable = phase == .preparing || phase == .countdown
        systemAudioToggle.isEnabled = idle; microphoneToggle.isEnabled = idle
        startButton.isEnabled = idle && region != nil
        startButton.title = revealURL == nil ? L("开始录制") : L("再次录制")
        startButton.setAccessibilityLabel(startButton.title)
        stopButton.isEnabled = isRecording && phase != .stopping
        stopButton.title = cancellable ? L("取消") : L("停止录制")
        stopButton.setAccessibilityLabel(stopButton.title)
        stopButton.image = NSImage(systemSymbolName: cancellable ? "xmark" : "stop", accessibilityDescription: stopButton.title)
        pauseButton.title = isPaused ? L("继续录制") : L("暂停录制")
        pauseButton.setAccessibilityLabel(pauseButton.title)
        pauseButton.image = NSImage(systemSymbolName: isPaused ? "play" : "pause", accessibilityDescription: pauseButton.title)
        pauseButton.isEnabled = canPauseOrResume
        hideButton.isEnabled = isRecording && phase != .stopping
        revealButton.isEnabled = idle && revealURL != nil
        audioToolbar.rows = [[systemAudioToggle, microphoneToggle]]
        actionToolbar.rows = idle
            ? [[startButton] + (recoverableSession == nil ? [] : [retrySaveButton]) + (revealURL == nil ? [] : [revealButton]) + (failure == nil ? [] : [settingsButton])]
            : [[stopButton] + (cancellable ? [] : [pauseButton]) + [hideButton]]
        layoutControls(); onStateChange?()
    }

    private func layoutControls() {
        guard let panel, let content = panel.contentView else { return }
        let idle = phase == .idle
        audioToolbar.isHidden = !idle
        durationLabel.isHidden = idle || phase == .preparing || phase == .countdown
        statusLabel.isHidden = statusLabel.stringValue.isEmpty
        fileLabel.isHidden = !idle || fileLabel.stringValue.isEmpty
        fileLabel.toolTip = fileLabel.stringValue; statusLabel.toolTip = statusLabel.stringValue
        let padding: CGFloat = 12, gap: CGFloat = 8, maxWidth: CGFloat = 352
        let audioSize = audioToolbar.arrange(maxWidth: maxWidth)
        let actionSize = actionToolbar.arrange(maxWidth: maxWidth)
        let width = min(maxWidth, max(260, max(idle ? audioSize.width : 0, actionSize.width)))
        let views: [NSView] = [statusLabel, durationLabel, fileLabel, exclusionLabel, audioToolbar, actionToolbar]
        let rows: [(NSView, CGFloat)] = views.filter { !$0.isHidden }.map { view in
            if view === audioToolbar { return (view, audioSize.height) }
            if view === actionToolbar { return (view, actionSize.height) }
            let label = view as! NSTextField
            return (view, ceil(label.cell?.cellSize(forBounds: CGRect(x: 0, y: 0, width: width, height: 200)).height ?? 20))
        }
        let height = padding * 2 + rows.reduce(0) { $0 + $1.1 } + CGFloat(max(0, rows.count - 1)) * gap
        let oldFrame = panel.frame
        let titlebarHeight = panel.frame.height - panel.contentLayoutRect.height
        isPositioningControls = true
        panel.setContentSize(CGSize(width: width + padding * 2, height: height + titlebarHeight))
        panel.setFrameOrigin(CGPoint(x: oldFrame.minX, y: oldFrame.maxY - panel.frame.height))
        isPositioningControls = false
        // Keep the title bar where the user put it. A phase change must never
        // repeat the initial corner choice or pull a drag back to its old screen.
        if !needsInitialPlacement, NSEvent.pressedMouseButtons & 1 == 0 { clampControlsToScreen() }
        var y = content.convert(panel.contentLayoutRect, from: nil).maxY - padding
        for (view, height) in rows { y -= height; view.frame = CGRect(x: padding, y: y, width: width, height: height); y -= gap }
    }

    private func placeControlsInitially() {
        guard let panel else { return }
        let screens = NSScreen.screens
        let selected = screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == region?.displayID
        }
        let fallbackIndex = RecordingControlsPlacement.closestScreenIndex(to: region?.rect ?? panel.frame,
            screens: screens.map(\.frame))
        guard let screen = selected ?? fallbackIndex.map({ screens[$0] }) else { return }
        let frame = RecordingControlsPlacement.initialFrame(size: panel.frame.size,
            visibleFrame: screen.visibleFrame, avoiding: region?.rect ?? .null)
        isPositioningControls = true
        panel.setFrame(frame, display: false)
        isPositioningControls = false
        needsInitialPlacement = false
    }

    private func clampControlsToScreen() {
        guard !needsInitialPlacement, let panel else { return }
        let screens = NSScreen.screens
        guard let index = RecordingControlsPlacement.closestScreenIndex(to: panel.frame, screens: screens.map(\.frame)) else { return }
        let frame = RecordingControlsPlacement.clamped(panel.frame, to: screens[index].visibleFrame)
        guard frame != panel.frame else { return }
        isPositioningControls = true
        panel.setFrame(frame, display: panel.isVisible)
        isPositioningControls = false
    }

    private func clampControlsAfterDragging() {
        clampAfterMove?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Waiting for release lets the user cross display boundaries freely.
            if NSEvent.pressedMouseButtons & 1 != 0 { self.clampControlsAfterDragging(); return }
            self.clampAfterMove = nil
            self.clampControlsToScreen()
        }
        clampAfterMove = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func setStatus(_ text: String, isError: Bool = false) {
        statusLabel.stringValue = text; statusLabel.textColor = isError ? .systemRed : .labelColor
        layoutControls(); onStateChange?()
    }

    @objc private func startPressed() {
        guard phase == .idle, region != nil, let panel else { return }
        sessionID = UUID(); let id = sessionID
        closeRequested = false
        recordsSystemAudio = systemAudioToggle.state == .on; recordsMicrophone = microphoneToggle.state == .on
        failure = nil; revealURL = nil; recoverableSession = nil; destinationURL = nil; workingURL = nil; workingDirectory = nil
        completedSegments = []; completedDuration = 0; frozenSegmentDuration = nil; startedAt = nil
        streamHasStarted = false; streamStoppedByUser = false; stopRequested = false; pauseRequested = false
        durationLabel.stringValue = "00:00"; fileLabel.stringValue = ""
        phase = .preparing
        setStatus(L("选择 MP4 保存位置")); updateControls()
        preparationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try self.checkPreparation(id: id)
                guard let url = await self.chooseDestination(in: panel) else { self.resetAfterCancellation(id: id); return }
                try self.checkPreparation(id: id)
                self.destinationURL = url; self.fileLabel.stringValue = url.path
                self.setStatus(L("正在检查录屏权限…"))
                try await self.authorizeCapture(microphone: self.recordsMicrophone)
                try self.checkPreparation(id: id)
                // Validate the display and capture grant before the countdown begins.
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                try self.checkPreparation(id: id)
                guard content.displays.contains(where: { $0.displayID == self.region?.displayID }) else {
                    throw PatchError(message: L("所选屏幕已断开。请重新选择录屏区域。"))
                }
                try await self.runCountdown(id: id)
                try await self.startSegment(id: id, preparedContent: content)
            } catch is CancellationError { self.cancelPreparation(id: id) }
            catch { self.fail(error, id: id) }
            if self.sessionID == id { self.preparationTask = nil }
        }
    }

    private func runCountdown(id: UUID) async throws {
        try checkPreparation(id: id)
        phase = .countdown
        if let region { regionOverlay.show(region: region) }
        activateCaptureTarget()
        for remaining in (1...3).reversed() {
            try checkPreparation(id: id)
            setStatus(LF("%d 秒后开始录制", remaining)); updateControls()
            try await countdownSleep()
        }
        try checkPreparation(id: id)
    }

    private func activateCaptureTarget() {
        if let pid = region?.targetPID, pid != ProcessInfo.processInfo.processIdentifier,
           let target = NSRunningApplication(processIdentifier: pid), !target.isTerminated { target.activate(options: []) }
    }

    private func startSegment(id: UUID, preparedContent: SCShareableContent? = nil) async throws {
        try checkPreparation(id: id)
        guard !stopRequested else { finishRecording(id: id); return }
        guard let region else { throw PatchError(message: L("所选屏幕已断开。请重新选择录屏区域。")) }
        var content: SCShareableContent
        if let preparedContent { content = preparedContent }
        else { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) }
        try checkPreparation(id: id)
        guard !stopRequested else { finishRecording(id: id); return }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        if !content.applications.contains(where: { $0.processID == ownPID }) {
            // The fallback excludes explicit windows, so refresh after the
            // countdown created the guide instead of using its older snapshot.
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            try checkPreparation(id: id)
            guard !stopRequested else { finishRecording(id: id); return }
        }
        guard let display = content.displays.first(where: { $0.displayID == region.displayID }) else {
            throw PatchError(message: L("所选屏幕已断开。请重新选择录屏区域。"))
        }
        let ownApps = content.applications.filter { $0.processID == ownPID }
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == ownPID }
        if ownApps.isEmpty {
            let protectedNumbers = [regionOverlay.windowNumber, panel?.windowNumber].compactMap { $0 }
            let protectedIDs = protectedNumbers.compactMap { CGWindowID(exactly: $0) }
            guard protectedIDs.count == protectedNumbers.count,
                  Self.canExcludeRecordingWindows(required: protectedIDs, available: ownWindows.map(\.windowID)) else {
                throw PatchError(message: L("无法从录屏中排除控制窗和范围提示。请重新打开录屏后再试。"))
            }
        }
        let filter = ownApps.isEmpty
            ? SCContentFilter(display: display, excludingWindows: ownWindows)
            : SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.sourceRect = region.sourceRect
        config.width = evenPixelDimension(region.rect.width * region.scale); config.height = evenPixelDimension(region.rect.height * region.scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.capturesAudio = recordsSystemAudio; config.captureMicrophone = recordsMicrophone
        config.excludesCurrentProcessAudio = true; config.showsCursor = true; config.captureDynamicRange = .SDR
        if recordsMicrophone { config.microphoneCaptureDeviceID = AVCaptureDevice.default(for: .audio)?.uniqueID }
        if workingDirectory == nil {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Patch-Recording-\(id.uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            workingDirectory = directory
        }
        let url = workingDirectory!.appendingPathComponent(String(format: "segment-%03d.mp4", completedSegments.count + 1))
        workingURL = url
        let outputConfig = SCRecordingOutputConfiguration()
        outputConfig.outputURL = url; outputConfig.videoCodecType = .h264; outputConfig.outputFileType = .mp4
        guard outputConfig.availableVideoCodecTypes.contains(.h264), outputConfig.availableOutputFileTypes.contains(.mp4) else {
            throw PatchError(message: L("这台 Mac 当前无法写入 H.264 MP4，请重试或重新选择较小的录屏区域。"))
        }
        let output = SCRecordingOutput(configuration: outputConfig, delegate: self)
        let nextStream = SCStream(filter: filter, configuration: config, delegate: self)
        try nextStream.addRecordingOutput(output)
        stream = nextStream; recordingOutput = output; streamHasStarted = false
        startedAt = nil; frozenSegmentDuration = nil; stopTask = nil
        phase = .starting; setStatus(completedSegments.isEmpty ? L("正在开始录制…") : L("正在继续录制…")); updateControls()
        activateCaptureTarget()
        let startTask = Task { try await nextStream.startCapture() }
        captureStartTask = startTask
        try await startTask.value
        guard id == sessionID, stream === nextStream, failure == nil else { return }
        streamHasStarted = true
        if stopRequested || pauseRequested { requestStreamStop() }
    }

    private func checkPreparation(id: UUID) throws {
        try Task.checkCancellation()
        guard id == sessionID else { throw CancellationError() }
    }
    static func canExcludeRecordingWindows(required: [CGWindowID], available: [CGWindowID]) -> Bool {
        Set(required).isSubset(of: Set(available))
    }
    private func cancelPreparation(id: UUID) {
        guard id == sessionID else { return }
        if stream == nil && completedSegments.isEmpty { resetAfterCancellation(id: id) }
        else { stop() }
    }
    private func evenPixelDimension(_ value: CGFloat) -> Int {
        // H.264 uses even pixel dimensions; at most one pixel is added at the edge.
        max(2, Int(ceil(value / 2)) * 2)
    }

    private func chooseDestination(in window: NSWindow) async -> URL? {
        let chooser = NSSavePanel()
        chooser.allowedContentTypes = [.mpeg4Movie]
        chooser.canCreateDirectories = true
        chooser.nameFieldStringValue = "Patch-\(Self.filenameDateFormatter.string(from: Date())).mp4"
        chooser.title = L("保存录屏")
        chooser.prompt = L("选择")
        savePanel = chooser
        let result: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            chooser.beginSheetModal(for: window) { response in
                continuation.resume(returning: response)
            }
        }
        // A cancelled sheet can finish after a new session presents its own sheet.
        if savePanel === chooser { savePanel = nil }
        return result == .OK ? chooser.url : nil
    }

    private static let filenameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()

    private func authorizeCapture(microphone: Bool) async throws {
        if !CGPreflightScreenCaptureAccess(), !CGRequestScreenCaptureAccess() {
            throw PatchError(message: L("请在“系统设置 → 隐私与安全性 → 屏幕与系统音频录制”中允许小贴，然后重新打开工具并重试。"))
        }
        guard microphone else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil else {
                throw PatchError(message: L("当前版本无法申请麦克风权限。请使用 Patch.app，或关闭麦克风开关后重试。"))
            }
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw microphonePermissionError()
            }
        case .denied, .restricted:
            throw microphonePermissionError()
        @unknown default:
            throw microphonePermissionError()
        }
        guard AVCaptureDevice.default(for: .audio) != nil else {
            throw PatchError(message: L("未找到可用的麦克风。请连接麦克风，或关闭麦克风开关后重试。"))
        }
    }

    private func microphonePermissionError() -> PatchError {
        PatchError(message: L("麦克风访问未获允许。请在“系统设置 → 隐私与安全性 → 麦克风”中允许小贴，或关闭麦克风开关后重试。"))
    }


    private func requestStreamStop() {
        guard stopTask == nil, let stream else { return }
        let id = sessionID
        stopTask = Task { [weak self] in
            do { try await stream.stopCapture() }
            catch {
                if (error as NSError).domain == SCStreamErrorDomain && (error as NSError).code == SCStreamError.Code.userStopped.rawValue {
                    self?.systemStoppedRecording()
                } else if (error as NSError).domain == SCStreamErrorDomain,
                          (error as NSError).code == SCStreamError.Code.attemptToStopStreamState.rawValue,
                          self?.finalizationTask != nil {
                    // The output can finish before the system's stop callback.
                    // An already-stopped stream must not discard that valid output.
                } else if self?.streamStoppedByUser != true { self?.fail(error, id: id) }
            }
        }
    }
    private var currentSegmentDuration: TimeInterval {
        let recorded = recordingOutput.map { CMTimeGetSeconds($0.recordedDuration) } ?? 0
        if recorded.isFinite && recorded > 0 { return recorded }
        return startedAt.map { max(0, Date().timeIntervalSince($0)) } ?? 0
    }
    private func stopClock() { timer?.invalidate(); timer = nil; updateDuration() }
    private func didStart(_ output: SCRecordingOutput) {
        guard output === recordingOutput, failure == nil, finalizationTask == nil else { return }
        startedAt = Date()
        if stopRequested || pauseRequested {
            phase = stopRequested ? .stopping : .pausing
            if streamHasStarted { requestStreamStop() }
        } else {
            phase = .recording; setStatus(L("录制中"))
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.updateDuration() }
            }
        }
        updateControls()
    }
    private func updateDuration() {
        let total = max(0, Int(elapsedSeconds))
        durationLabel.stringValue = total >= 3600
            ? String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
        onStateChange?()
    }

    private func didFinish(_ output: SCRecordingOutput) {
        guard output === recordingOutput, failure == nil, finalizationTask == nil else { return }
        let id = sessionID
        stopClock()
        finalizationTask = Task { [weak self] in
            guard let self else { return }
            // SCRecordingOutput can finish before startCapture returns. Await both boundaries.
            _ = await self.captureStartTask?.result
            guard self.sessionID == id, self.failure == nil, self.recordingOutput === output else { return }
            if self.stopTask == nil && !self.streamStoppedByUser { self.requestStreamStop() }
            await self.stopTask?.value
            guard self.sessionID == id, self.failure == nil, let url = self.workingURL else { return }
            guard FileManager.default.fileExists(atPath: url.path) else {
                self.fail(PatchError(message: L("录屏片段未能写入，已有文件已保留。")), id: id); return
            }
            self.acceptCompletedSegment(at: url, duration: self.currentSegmentDuration, id: id)
        }
    }

    private func acceptCompletedSegment(at url: URL, duration: TimeInterval, id: UUID) {
        guard id == sessionID, failure == nil else { return }
        completedSegments.append(url)
        completedDuration += max(0, duration.isFinite ? duration : 0)
        stream = nil; recordingOutput = nil; streamHasStarted = false
        captureStartTask = nil; stopTask = nil; finalizationTask = nil
        workingURL = nil; startedAt = nil; frozenSegmentDuration = nil
        updateDuration()
        if pauseRequested && !stopRequested {
            phase = .paused
            setStatus(L("已暂停")); updateControls()
        } else { finishRecording(id: id) }
    }

    private func finishRecording(id: UUID) {
        guard id == sessionID, failure == nil, finalizationTask == nil, let destination = destinationURL else { return }
        phase = .stopping; stopRequested = true
        setStatus(L("正在合并并保存录屏…")); updateControls()
        let segments = completedSegments, directory = workingDirectory
        finalizationTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let first = segments.first else { throw PatchError(message: L("没有可保存的录屏片段。")) }
                let export: URL
                if segments.count == 1 { export = first }
                else {
                    export = directory!.appendingPathComponent("Recording-\(UUID().uuidString).mp4")
                    _ = try await RecordingSegments.assemble(segments, at: export)
                }
                let remaining = try await Task.detached(priority: .userInitiated) {
                    try RecordingFileStorage.saveCompletedRecording(at: export, to: destination)
                    return RecordingFileStorage.removeSavedSegments(segments, in: directory)
                }.value
                guard self.sessionID == id, self.failure == nil else { return }
                self.revealURL = destination
                self.onCompletedVideo?(destination)
                self.recoverableSession = nil
                self.releaseSession()
                self.fileLabel.stringValue = destination.path
                self.setStatus(remaining.map { LF("已保存完成的录屏片段。其余文件保留在：%@", $0.path) } ?? L("录屏已保存。")); self.updateControls()
                if self.closeRequested { self.dismissControls() }
                else { self.showControls() }
            } catch {
                self.fail(PatchError(message: LF("录屏未能保存：%@\n原始片段保留在：%@", error.localizedDescription, directory?.path ?? "")), id: id)
            }
        }
    }

    private func systemStoppedRecording() {
        guard isRecording else { return }
        streamStoppedByUser = true; stopRequested = true; pauseRequested = false
        frozenSegmentDuration = currentSegmentDuration
        phase = .stopping; regionOverlay.close(); stopClock()
        setStatus(L("正在结束录制并保存文件…")); updateControls()
        // The system has already stopped SCStream. The output delegate completes
        // and commits the same file through didFinish, without a second stop.
    }

    private func fail(_ error: Error, id: UUID) {
        guard id == sessionID, failure == nil, isRecording else { return }
        failure = error; phase = .stopping
        regionOverlay.close()
        stopClock(); setStatus(L("录制未完成，正在结束…"), isError: true); updateControls()
        let currentStream = stream, currentStart = captureStartTask, currentStop = stopTask
        Task { [weak self] in
            _ = await currentStart?.result
            if let currentStop { await currentStop.value }
            else if let currentStream { try? await currentStream.stopCapture() }
            guard let self, self.sessionID == id else { return }
            let recoverable = self.workingDirectory.flatMap { directory -> URL? in
                guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path), !files.isEmpty else { return nil }
                return directory
            }
            self.revealURL = recoverable
            if let recoverable, !self.completedSegments.isEmpty {
                self.recoverableSession = (self.completedSegments, recoverable)
            }
            self.releaseSession()
            self.closeRequested = false
            if self.panel == nil { self.buildPanel() }
            self.fileLabel.stringValue = recoverable.map { LF("原始录屏片段保留在：%@", $0.path) } ?? ""
            self.setStatus(error.localizedDescription, isError: true); self.updateControls()
            self.showControls()
        }
    }

    private func resetAfterCancellation(id: UUID) {
        guard id == sessionID else { return }
        sessionID = UUID()
        releaseSession()
        setStatus(L("已取消。可重新开始录制。")); updateControls()
        if closeRequested { dismissControls() }
    }
    private func retrySave() {
        guard phase == .idle, let recovery = recoverableSession, let panel else { return }
        sessionID = UUID(); let id = sessionID
        failure = nil; stopRequested = false; closeRequested = false; phase = .preparing
        setStatus(L("选择 MP4 保存位置")); updateControls()
        preparationTask = Task { [weak self] in
            guard let self else { return }
            guard self.sessionID == id, !Task.isCancelled else { return }
            guard let destination = await self.chooseDestination(in: panel) else {
                self.resetAfterCancellation(id: id); return
            }
            guard self.sessionID == id, !Task.isCancelled else { return }
            self.destinationURL = destination; self.workingDirectory = recovery.directory
            self.completedSegments = recovery.files; self.preparationTask = nil
            self.finishRecording(id: id)
        }
    }
    private func releaseSession() {
        regionOverlay.close()
        timer?.invalidate(); timer = nil
        stream = nil; recordingOutput = nil; preparationTask = nil; captureStartTask = nil
        stopTask = nil; finalizationTask = nil; streamHasStarted = false; streamStoppedByUser = false
        destinationURL = nil; workingURL = nil; workingDirectory = nil
        startedAt = nil; frozenSegmentDuration = nil; completedSegments = []; completedDuration = 0
        phase = .idle
    }
    @objc private func revealPressed() {
        if let revealURL { NSWorkspace.shared.activateFileViewerSelecting([revealURL]) }
    }
    @objc private func settingsPressed() { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app")) }
}

extension RecordingCoordinator: NSWindowDelegate {
    func windowDidMove(_ notification: Notification) {
        guard notification.object as? NSWindow === panel, !isPositioningControls, !needsInitialPlacement else { return }
        clampControlsAfterDragging()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === panel else { return true }
        closeRequested = true
        if isRecording { hideControls(); stop() }
        else { dismissControls() }
        return false
    }
    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === panel else { return }
        panel = nil
        needsInitialPlacement = true; clampAfterMove?.cancel(); clampAfterMove = nil
        regionOverlay.close()
        if isRecording { closeRequested = true; stop() }
        else { region = nil; closeRequested = false }
        onStateChange?()
    }
}
extension RecordingCoordinator: SCRecordingOutputDelegate {
    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [weak self] in self?.didStart(recordingOutput) }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [weak self] in self?.didFinish(recordingOutput) }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, recordingOutput === self.recordingOutput else { return }
            self.fail(error, id: self.sessionID)
        }
    }
}

extension RecordingCoordinator: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, stream === self.stream else { return }
            if (error as NSError).domain == SCStreamErrorDomain && (error as NSError).code == SCStreamError.Code.userStopped.rawValue {
                self.systemStoppedRecording()
            } else { self.fail(error, id: self.sessionID) }
        }
    }
}

/// Pure AppKit-point geometry, including displays to the left/below the primary.
private enum RecordingControlsPlacement {
    static func initialFrame(size: NSSize, visibleFrame: NSRect, avoiding selection: NSRect) -> NSRect {
        let margin: CGFloat = 16
        let corners = [
            NSPoint(x: visibleFrame.maxX - size.width - margin, y: visibleFrame.minY + margin),
            NSPoint(x: visibleFrame.minX + margin, y: visibleFrame.minY + margin),
            NSPoint(x: visibleFrame.maxX - size.width - margin, y: visibleFrame.maxY - size.height - margin),
            NSPoint(x: visibleFrame.minX + margin, y: visibleFrame.maxY - size.height - margin)
        ]
        let candidates = corners.map { clamped(NSRect(origin: $0, size: size), to: visibleFrame) }
        let avoided = selection.isNull ? selection : selection.insetBy(dx: -8, dy: -8)
        func overlap(_ frame: NSRect) -> CGFloat {
            let intersection = frame.intersection(avoided)
            return intersection.isNull ? 0 : intersection.width * intersection.height
        }
        if let clear = candidates.first(where: { overlap($0) == 0 }) { return clear }
        // Full-screen capture may leave no free corner. Keep the controls at an
        // edge, minimizing obstruction; equal scores retain bottom-right priority.
        return candidates.dropFirst().reduce(candidates[0]) { best, candidate in
            overlap(candidate) < overlap(best) ? candidate : best
        }
    }

    static func clamped(_ frame: NSRect, to visibleFrame: NSRect) -> NSRect {
        guard !visibleFrame.isEmpty else { return frame }
        let x = frame.width > visibleFrame.width ? visibleFrame.minX
            : min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - frame.width)
        // On an exceptionally small desktop, preserve access to the title bar.
        let y = frame.height > visibleFrame.height ? visibleFrame.maxY - frame.height
            : min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - frame.height)
        return NSRect(origin: NSPoint(x: x, y: y), size: frame.size)
    }

    static func closestScreenIndex(to frame: NSRect, screens: [NSRect]) -> Int? {
        guard !screens.isEmpty else { return nil }
        let intersections = screens.map { screen -> CGFloat in
            let overlap = screen.intersection(frame)
            return overlap.isNull ? 0 : overlap.width * overlap.height
        }
        if let maximum = intersections.max(), maximum > 0 { return intersections.firstIndex(of: maximum) }
        let center = NSPoint(x: frame.midX, y: frame.midY)
        func distance(_ screen: NSRect) -> CGFloat {
            let dx = max(screen.minX - center.x, 0, center.x - screen.maxX)
            let dy = max(screen.minY - center.y, 0, center.y - screen.maxY)
            return dx * dx + dy * dy
        }
        return screens.indices.min { distance(screens[$0]) < distance(screens[$1]) }
    }
}
