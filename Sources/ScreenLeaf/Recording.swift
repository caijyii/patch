// SPDX-FileCopyrightText: 2026 caijyii
// SPDX-License-Identifier: MIT

import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Owns a recording and its controls until ScreenCaptureKit finishes writing the file.
@MainActor
final class RecordingCoordinator: NSObject {
    private enum Phase {
        case idle, preparing, starting, recording, stopping
    }

    private var phase: Phase = .idle
    private var panel: NSPanel?
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
    private var stopRequested = false
    private var failure: Error?
    private var destinationURL: URL?
    private var workingURL: URL?
    private var revealURL: URL?

    private let systemAudioToggle = SelectionButton("系统声音", symbol: "speaker.wave.2") {}
    private let microphoneToggle = SelectionButton("麦克风", symbol: "mic") {}
    private lazy var startButton = SelectionButton("开始录制", symbol: "record.circle") { [weak self] in self?.startPressed() }
    private lazy var stopButton = SelectionButton("停止录制", symbol: "stop") { [weak self] in self?.stopPressed() }
    private lazy var revealButton = SelectionButton("在 Finder 中显示", symbol: "folder") { [weak self] in self?.revealPressed() }
    private lazy var settingsButton = SelectionButton("打开系统设置", symbol: "gearshape") { [weak self] in self?.settingsPressed() }
    private let audioToolbar = SelectionToolbar()
    private let actionToolbar = SelectionToolbar()
    private var audioToolbarHeight: NSLayoutConstraint?
    private var actionToolbarHeight: NSLayoutConstraint?
    private let durationLabel = NSTextField(labelWithString: "00:00")
    private let regionLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let fileLabel = NSTextField(wrappingLabelWithString: "")

    /// Remains true during preparation, stopping, and file finalization, so quitting can wait.
    var isRecording: Bool { phase != .idle }

    override init() {
        super.init()
        systemAudioToggle.setButtonType(.pushOnPushOff)
        microphoneToggle.setButtonType(.pushOnPushOff)
        systemAudioToggle.state = .on
        microphoneToggle.state = .off
        systemAudioToggle.toolTip = "开启或关闭系统声音录制"
        microphoneToggle.toolTip = "开启或关闭麦克风录制"
        revealButton.toolTip = "在 Finder 中显示录屏文件"
        settingsButton.toolTip = "打开系统设置以检查录屏权限"
    }

    func showControls(region: CaptureRegion) {
        // Opening controls again must never replace the source of an active recording.
        if !isRecording {
            self.region = region
            let width = Int((region.rect.width * region.scale).rounded())
            let height = Int((region.rect.height * region.scale).rounded())
            regionLabel.stringValue = "已选区域：\(width) × \(height) 像素 · MP4 · 30 fps"
            if panel == nil {
                buildPanel()
                setStatus("选择需要录制的声音，开始时可选择保存位置。")
            }
        }
        updateControls()
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
    }

    func stop() {
        guard isRecording, failure == nil else { return }
        stopRequested = true
        if phase == .preparing {
            preparationTask?.cancel()
            savePanel?.cancel(nil)
            // System permission requests may outlive task cancellation. Release the
            // controls now; the invalidated session cannot start capture later.
            resetAfterCancellation(id: sessionID)
        } else {
            phase = .stopping
            setStatus("正在结束录制并保存文件…")
            timer?.invalidate()
            timer = nil
            // A stop requested during startCapture is handled when startCapture returns.
            if streamHasStarted {
                requestStreamStop()
            }
        }
        updateControls()
    }

    private func buildPanel() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 340),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "小贴 · 录屏"
        window.isFloatingPanel = true
        window.level = .floating
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.delegate = self

        let content = NSView()
        window.contentView = content
        let stack = NSStackView(views: [regionLabel, audioToolbar, durationLabel, statusLabel,
                                      fileLabel, actionToolbar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        durationLabel.font = .monospacedDigitSystemFont(ofSize: 26, weight: .medium)
        regionLabel.textColor = .secondaryLabelColor
        regionLabel.font = .systemFont(ofSize: 12)
        fileLabel.font = .systemFont(ofSize: 11)
        fileLabel.textColor = .secondaryLabelColor
        fileLabel.lineBreakMode = .byTruncatingMiddle
        fileLabel.maximumNumberOfLines = 2
        statusLabel.maximumNumberOfLines = 3
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        fileLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        audioToolbar.translatesAutoresizingMaskIntoConstraints = false
        actionToolbar.translatesAutoresizingMaskIntoConstraints = false
        audioToolbarHeight = audioToolbar.heightAnchor.constraint(equalToConstant: 40)
        actionToolbarHeight = actionToolbar.heightAnchor.constraint(equalToConstant: 40)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
            audioToolbar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actionToolbar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            audioToolbarHeight!, actionToolbarHeight!,
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            fileLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        panel = window
        updateControls()
        window.center()
    }

    private func updateControls() {
        let idle = phase == .idle
        systemAudioToggle.isEnabled = idle
        microphoneToggle.isEnabled = idle
        startButton.isEnabled = idle && region != nil
        startButton.title = revealURL == nil ? "开始录制" : "再次录制"
        startButton.setAccessibilityLabel(startButton.title)
        startButton.toolTip = "\(startButton.title)，选择保存位置后开始"
        stopButton.isEnabled = phase == .preparing || phase == .starting || phase == .recording
        stopButton.title = phase == .preparing ? "取消" : "停止录制"
        stopButton.setAccessibilityLabel(stopButton.title)
        stopButton.image = NSImage(systemSymbolName: phase == .preparing ? "xmark" : "stop",
                                  accessibilityDescription: stopButton.title)
        stopButton.toolTip = phase == .preparing ? "取消准备，返回录屏选项" : "停止录制并保存到所选位置"
        revealButton.isHidden = revealURL == nil
        revealButton.isEnabled = idle && revealURL != nil
        settingsButton.isHidden = failure == nil
        let width = max(40, (panel?.contentView?.bounds.width ?? 500) - 40)
        audioToolbar.rows = [[systemAudioToggle, microphoneToggle]]
        actionToolbar.rows = [[startButton, stopButton]
            + (revealURL == nil ? [] : [revealButton])
            + (failure == nil ? [] : [settingsButton])]
        audioToolbarHeight?.constant = audioToolbar.arrange(maxWidth: width).height
        actionToolbarHeight?.constant = actionToolbar.arrange(maxWidth: width).height
    }

    private func setStatus(_ text: String, isError: Bool = false) {
        statusLabel.stringValue = text
        statusLabel.textColor = isError ? .systemRed : .labelColor
    }

    @objc private func startPressed() {
        guard phase == .idle, let region, let panel else { return }
        sessionID = UUID()
        let id = sessionID
        let systemAudio = systemAudioToggle.state == .on
        let microphone = microphoneToggle.state == .on
        failure = nil
        revealURL = nil
        destinationURL = nil
        workingURL = nil
        startedAt = nil
        streamHasStarted = false
        stopRequested = false
        durationLabel.stringValue = "00:00"
        fileLabel.stringValue = ""
        phase = .preparing
        setStatus("请选择 MP4 的保存位置。")
        updateControls()

        preparationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try self.checkPreparation(id: id)
                guard let url = await self.chooseDestination(in: panel) else {
                    self.resetAfterCancellation(id: id)
                    return
                }
                try self.checkPreparation(id: id)
                self.destinationURL = url
                self.fileLabel.stringValue = url.path
                self.setStatus("正在检查录屏权限…")
                try await self.authorizeCapture(microphone: microphone)
                try self.checkPreparation(id: id)
                let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                                   onScreenWindowsOnly: false)
                try self.checkPreparation(id: id)
                guard let display = content.displays.first(where: { $0.displayID == region.displayID }) else {
                    throw ScreenLeafError(message: "所选屏幕已断开。请重新选择录屏区域。")
                }
                let ownPID = ProcessInfo.processInfo.processIdentifier
                let ownApplications = content.applications.filter { $0.processID == ownPID }
                let filter: SCContentFilter
                if ownApplications.isEmpty {
                    let ownWindows = content.windows.filter { $0.owningApplication?.processID == ownPID }
                    filter = SCContentFilter(display: display, excludingWindows: ownWindows)
                } else {
                    // Excluding the application also excludes controls opened after this snapshot.
                    filter = SCContentFilter(display: display,
                                             excludingApplications: ownApplications,
                                             exceptingWindows: [])
                }
                let configuration = SCStreamConfiguration()
                configuration.sourceRect = region.sourceRect
                configuration.width = self.evenPixelDimension(region.rect.width * region.scale)
                configuration.height = self.evenPixelDimension(region.rect.height * region.scale)
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                configuration.capturesAudio = systemAudio
                configuration.captureMicrophone = microphone
                configuration.excludesCurrentProcessAudio = true
                configuration.showsCursor = true
                configuration.captureDynamicRange = .SDR
                if microphone {
                    configuration.microphoneCaptureDeviceID = AVCaptureDevice.default(for: .audio)?.uniqueID
                }

                // Record inside the sandbox; export only after the output has finished.
                let temporaryURL = RecordingFileStorage.makeWorkingURL()
                self.workingURL = temporaryURL
                let outputConfiguration = SCRecordingOutputConfiguration()
                outputConfiguration.outputURL = temporaryURL
                outputConfiguration.videoCodecType = .h264
                outputConfiguration.outputFileType = .mp4
                guard outputConfiguration.availableVideoCodecTypes.contains(.h264),
                      outputConfiguration.availableOutputFileTypes.contains(.mp4) else {
                    throw ScreenLeafError(message: "这台 Mac 当前无法写入 H.264 MP4，请重试或重新选择较小的录屏区域。")
                }
                let output = SCRecordingOutput(configuration: outputConfiguration, delegate: self)
                let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
                try stream.addRecordingOutput(output)
                self.recordingOutput = output
                self.stream = stream
                self.phase = .starting
                self.setStatus("正在开始录制…")
                self.updateControls()
                // The save sheet and permission prompts activate Patch; return keyboard
                // input to the app selected before the controls were presented.
                if let targetPID = region.targetPID,
                   targetPID != ProcessInfo.processInfo.processIdentifier,
                   let target = NSRunningApplication(processIdentifier: targetPID),
                   !target.isTerminated {
                    target.activate(options: [])
                }
                let captureStartTask = Task { try await stream.startCapture() }
                self.captureStartTask = captureStartTask
                try await captureStartTask.value
                guard self.sessionID == id, self.stream === stream, self.failure == nil else { return }
                self.streamHasStarted = true
                if self.stopRequested || Task.isCancelled {
                    self.phase = .stopping
                    self.setStatus("正在结束录制并保存文件…")
                    self.requestStreamStop()
                }
            } catch is CancellationError {
                self.cancelPreparation(id: id)
            } catch {
                self.fail(error, id: id)
            }
            if self.sessionID == id {
                self.preparationTask = nil
            }
        }
    }

    private func checkPreparation(id: UUID) throws {
        try Task.checkCancellation()
        guard id == sessionID else { throw CancellationError() }
    }

    private func cancelPreparation(id: UUID) {
        guard id == sessionID else { return }
        if stream == nil {
            resetAfterCancellation(id: id)
        } else {
            stop()
        }
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
        chooser.title = "保存录屏"
        chooser.prompt = "选择"
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
            throw ScreenLeafError(message: "请在“系统设置 → 隐私与安全性 → 屏幕与系统音频录制”中允许小贴，然后重新打开工具并重试。")
        }
        guard microphone else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil else {
                throw ScreenLeafError(message: "当前版本无法申请麦克风权限。请使用 Patch.app，或关闭麦克风开关后重试。")
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
            throw ScreenLeafError(message: "未找到可用的麦克风。请连接麦克风，或关闭麦克风开关后重试。")
        }
    }

    private func microphonePermissionError() -> ScreenLeafError {
        ScreenLeafError(message: "麦克风访问未获允许。请在“系统设置 → 隐私与安全性 → 麦克风”中允许小贴，或关闭麦克风开关后重试。")
    }

    private func requestStreamStop() {
        guard stopTask == nil, let stream else { return }
        let id = sessionID
        stopRequested = true
        stopTask = Task { [weak self] in
            do {
                try await stream.stopCapture()
                // The output delegate, not this return, confirms a successfully written file.
            } catch {
                self?.fail(error, id: id)
            }
        }
    }

    private func didStart(_ output: SCRecordingOutput) {
        guard output === recordingOutput, failure == nil else { return }
        startedAt = Date()
        if stopRequested {
            phase = .stopping
            setStatus("正在结束录制并保存文件…")
            if streamHasStarted { requestStreamStop() }
        } else {
            phase = .recording
            setStatus("正在录制。停止后会保存到所选位置。")
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.updateDuration() }
            }
        }
        updateControls()
    }

    private func updateDuration() {
        let outputSeconds = recordingOutput.map { CMTimeGetSeconds($0.recordedDuration) } ?? 0
        let seconds = outputSeconds.isFinite && outputSeconds > 0
            ? outputSeconds : startedAt.map { Date().timeIntervalSince($0) } ?? 0
        let total = max(0, Int(seconds))
        durationLabel.stringValue = total >= 3600
            ? String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func didFinish(_ output: SCRecordingOutput) {
        guard output === recordingOutput, failure == nil, finalizationTask == nil else { return }
        let id = sessionID
        updateDuration()
        timer?.invalidate()
        timer = nil
        phase = .stopping
        setStatus("录制已结束，正在保存到所选位置…")
        updateControls()
        finalizationTask = Task { [weak self] in
            guard let self else { return }
            // A delegate callback can arrive before the startCapture continuation resumes.
            _ = await self.captureStartTask?.result
            guard self.sessionID == id, self.failure == nil else { return }
            if self.stopTask == nil {
                self.requestStreamStop()
            }
            await self.stopTask?.value
            guard self.sessionID == id, self.failure == nil,
                  let temporaryURL = self.workingURL, let destination = self.destinationURL else { return }
            // Capture has finished and stopped. Ignore late capture callbacks while
            // the background export runs; keep this session busy until it completes.
            self.stream = nil
            self.recordingOutput = nil
            self.streamHasStarted = false
            do {
                try await Task.detached(priority: .userInitiated) {
                    try RecordingFileStorage.saveCompletedRecording(at: temporaryURL, to: destination)
                }.value
                guard self.sessionID == id, self.failure == nil else { return }
                self.revealURL = destination
                self.releaseSession()
                self.setStatus("录屏已保存。")
                self.fileLabel.stringValue = destination.path
                self.updateControls()
            } catch {
                self.fail(ScreenLeafError(message: "录制已完成，但无法保存到所选位置：\(error.localizedDescription)\n文件保留在：\(temporaryURL.path)"), id: id)
            }
        }
    }

    private func fail(_ error: Error, id: UUID) {
        guard id == sessionID, failure == nil, isRecording else { return }
        failure = error
        phase = .stopping
        timer?.invalidate()
        timer = nil
        setStatus("录制未完成，正在结束…", isError: true)
        updateControls()
        let currentStream = stream
        let currentStartTask = captureStartTask
        let currentStopTask = stopTask
        // Always release a failed stream before enabling a new session or letting the app quit.
        Task { [weak self] in
            _ = await currentStartTask?.result
            if let currentStopTask {
                await currentStopTask.value
            } else if let currentStream {
                try? await currentStream.stopCapture()
            }
            guard let self, self.sessionID == id else { return }
            let partialURL = self.workingURL
            self.revealURL = partialURL.flatMap {
                FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
            }
            self.releaseSession()
            self.setStatus(error.localizedDescription, isError: true)
            self.fileLabel.stringValue = self.revealURL.map { "保留的文件可能不完整：\($0.path)" } ?? ""
            self.updateControls()
        }
    }

    private func resetAfterCancellation(id: UUID) {
        guard id == sessionID else { return }
        sessionID = UUID()
        releaseSession()
        setStatus("已取消。可重新开始录制。")
        updateControls()
    }

    private func releaseSession() {
        timer?.invalidate()
        timer = nil
        stream = nil
        recordingOutput = nil
        preparationTask = nil
        captureStartTask = nil
        stopTask = nil
        finalizationTask = nil
        streamHasStarted = false
        destinationURL = nil
        workingURL = nil
        phase = .idle
    }

    @objc private func stopPressed() { stop() }

    @objc private func revealPressed() {
        guard let revealURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([revealURL])
    }

    @objc private func settingsPressed() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }
}

extension RecordingCoordinator: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isRecording else {
            stop()
            return false
        }
        return true
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
            self.fail(error, id: self.sessionID)
        }
    }
}
