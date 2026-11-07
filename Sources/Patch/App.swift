// SPDX-FileCopyrightText: 2026 caijyii
// SPDX-License-Identifier: MIT

import AppKit
import Carbon
import Darwin

@main
struct PatchMain {
    static func main() {
        // Keep this process's effective language stable while restart-only settings change.
        AppLocalization.language = AppLocalization.resolvesToEnglish(PreferencesStore.shared.languagePreference) ? .english : .simplifiedChinese
        let app = NSApplication.shared
        if ProcessInfo.processInfo.arguments.contains("--ocr-self-check") {
            let passed = ImageToolsDiagnostics.checkOCR(DemoImage.make())
            exit(passed ? 0 : 1)
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        WindowActivationDiagnostics.startIfRequested()
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var statusControls: StatusBarControls!
    private var pauseRecordingItem: NSMenuItem?
    private var showRecordingControlsItem: NSMenuItem?
    private var recordingMenuSeparator: NSMenuItem?
    private var homeController: HomeWindowController?
    private let selector = RegionSelector()
    private let captureService: CaptureService
    private let imageTools = ImageToolsCoordinator()
    private let recording = RecordingCoordinator()
    private var hotKeys: HotKeys!
    private let preferences: PreferencesStore
    private let hotKeyBackend: HotKeyBackend?
    private var menuActions: [ShortcutAction: NSMenuItem] = [:]
    private var pinVisibilityMenuItem: NSMenuItem?
    private lazy var recentContent = RecentContentStore()
    private lazy var clipboardMonitor = RecentClipboardMonitor(store: recentContent)
    private var recentController: RecentContentWindowController?
    private let monitorsClipboard: Bool

    init(preferences: PreferencesStore? = nil, hotKeyBackend: HotKeyBackend? = nil,
         monitorsClipboard: Bool = true, captureService: CaptureService? = nil) {
        self.preferences = preferences ?? .shared
        self.hotKeyBackend = hotKeyBackend
        self.monitorsClipboard = monitorsClipboard
        self.captureService = captureService ?? CaptureService()
        super.init()
    }
    private var lastExternalApplication: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?
    private var quitTimer: Timer?
    private lazy var scrollCapture: ScrollCaptureCoordinator = ScrollCaptureCoordinator(capture: { [weak self] region in
        guard let self else { throw PatchError(message: "截图任务已关闭。") }
        return try await self.captureService.capture(region, hidePins: self.preferences.hidePinsWhenCapturing)
    }, onReselect: { [weak self] region, onCancel in
        guard let self else { onCancel(); return }
        let target = region.targetPID.flatMap { NSRunningApplication(processIdentifier: $0) }
        self.selector.select(purpose: .scroll, initialMode: .rectangle, targetApplication: target,
            capture: { [weak self] region in
                guard let self else { throw PatchError(message: "截图任务已关闭。") }
                return try await self.captureService.capture(region, hidePins: self.preferences.hidePinsWhenCapturing)
            }, onCancel: onCancel) { [weak self] action, region, image in
                self?.performSelectionAction(action, region: region, image: image)
            }
    }, onComplete: { [weak self] image, action in
        guard let self else { throw PatchError(message: "截图任务已关闭。") }
        switch action {
        case .copy: try ImageToolsUI.copyPNG(image, pixelScale: self.scrollCapture.outputPixelScale)
        case .pin: self.imageTools.pinImage(image, pixelScale: self.scrollCapture.outputPixelScale)
        case .ocr: self.imageTools.recognize(image)
        case .save: break // Saved by the capture coordinator, which retains cancelled exports.
        case .annotate: self.imageTools.showEditor(image, pixelScale: self.scrollCapture.outputPixelScale)
        }
    })

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = IconArtwork.applicationImage()
        let current = NSWorkspace.shared.frontmostApplication
        if current?.processIdentifier != ProcessInfo.processInfo.processIdentifier { lastExternalApplication = current }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                               object: nil, queue: .main) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            MainActor.assumeIsolated { self?.lastExternalApplication = app }
        }
        ImageToolsUI.onCompletedImage = { [weak self] image, scale in self?.recentContent.addImage(image, pixelScale: scale) }
        ImageToolsUI.onCompletedText = { [weak self] text in self?.recentContent.addText(text) }
        ImageToolsUI.onCompletedRichText = { [weak self] text in self?.recentContent.addText(text) }
        imageTools.onPinStateChange = { [weak self] in
            self?.refreshPinVisibilityAction()
            self?.recording.pinsDidChange()
        }
        recording.hidePinsPreference = { [weak self] in self?.preferences.hidePinsWhenRecording ?? true }
        recording.onStateChange = { [weak self] in self?.refreshRecordingActions() }
        recording.onCompletedVideo = { [weak self] in self?.recentContent.addVideo($0) }
        recentContent.onChange = { [weak self] in
            if self?.recentController?.window?.isVisible == true { self?.recentController?.reload() }
            self?.homeController?.refreshShortcuts()
        }
        applyOptions()
        clipboardMonitor.setEnabled(monitorsClipboard)
        installMenu()
        installShortcuts()
        showHome()
        if ProcessInfo.processInfo.arguments.contains("--demo") { showDemo() }
        if ProcessInfo.processInfo.arguments.contains("--smoke-test") {
            imageTools.showEditor(DemoImage.make())
            imageTools.pinImage(DemoImage.make())
            imageTools.pinText("小贴文字贴图\n可以编辑、选中文字并整体缩放。")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                print("Patch smoke test: menu, home, editor, image pin and text pin initialized")
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !WindowActivationCoordinator.shared.restoreWindow() { showHome() }
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) { homeController?.refreshPermissions() }

    private func installMenu() {
        let menu = GlobalShortcutMenu()
        for action in ShortcutAction.displayOrder {
            let item = NSMenuItem(title: L(action.title), action: selector(for: action), keyEquivalent: "")
            item.target = self
            menuActions[action] = item
            menu.addItem(item)
        }
        let pinItem = NSMenuItem(title: L("隐藏全部贴图"), action: #selector(togglePins), keyEquivalent: "")
        pinItem.target = self
        pinVisibilityMenuItem = pinItem
        menuActions[.togglePins] = pinItem
        menu.addItem(pinItem)
        let recordingSeparator = NSMenuItem.separator()
        menu.addItem(recordingSeparator); recordingMenuSeparator = recordingSeparator
        let pauseItem = NSMenuItem(title: L("暂停录制"), action: #selector(toggleRecordingPause), keyEquivalent: "")
        pauseItem.target = self; menu.addItem(pauseItem); pauseRecordingItem = pauseItem
        let controlsItem = NSMenuItem(title: L("显示控制窗"), action: #selector(showRecordingControls), keyEquivalent: "")
        controlsItem.target = self; menu.addItem(controlsItem); showRecordingControlsItem = controlsItem
        menu.addItem(.separator())
        for (title, action, key) in [("设置", #selector(showSettings), ","), ("退出", #selector(quit), "q")] {
            let item = NSMenuItem(title: L(title), action: action, keyEquivalent: key)
            item.target = self
            menu.addItem(item)
        }
        statusControls = StatusBarControls(menu: menu)
        refreshPinVisibilityAction()
        refreshRecordingActions()
        let appMenu = NSMenu()
        let rootItem = NSMenuItem()
        let applicationMenu = NSMenu()
        let quitItem = NSMenuItem(title: L("退出"), action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        let settingsItem = NSMenuItem(title: L("设置"), action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        applicationMenu.addItem(settingsItem)
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(quitItem)
        rootItem.submenu = applicationMenu
        appMenu.addItem(rootItem)
        // Standard editing shortcuts also work in editable text pins and OCR results.
        let editItem = NSMenuItem(title: L("编辑"), action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: L("编辑"))
        for (title, action, key) in [("撤销", Selector(("undo:")), "z"), ("剪切", #selector(NSText.cut(_:)), "x"),
                                   ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"),
                                   ("全选", #selector(NSText.selectAll(_:)), "a")] {
            editMenu.addItem(NSMenuItem(title: L(title), action: action, keyEquivalent: key))
        }
        editItem.submenu = editMenu
        appMenu.addItem(editItem)
        NSApp.mainMenu = appMenu
    }

    private func installShortcuts() {
        hotKeys = HotKeys(backend: hotKeyBackend)
        let actions: [ShortcutAction: () -> Void] = [
            .screenshot: { [weak self] in self?.screenshot() },
            .scroll: { [weak self] in self?.longScreenshot() },
            .text: { [weak self] in self?.ocrScreenshot() },
            .pin: { [weak self] in self?.pinClipboard() },
            .record: { [weak self] in self?.recordScreen() },
            .subject: { [weak self] in self?.subjectScreenshot() },
            .togglePins: { [weak self] in self?.togglePins() },
            .recentContent: { [weak self] in self?.showRecentContent() },
            .pinRecent: { [weak self] in self?.pinRecentContent() }
        ]
        hotKeys.installBindings(preferences.shortcutBindings, actions: actions)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(retryUnavailableShortcuts),
            name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        refreshShortcutLabels()
    }

    @objc private func retryUnavailableShortcuts() {
        hotKeys.retryUnavailableBindings()
        refreshShortcutLabels()
    }

    private func selector(for action: ShortcutAction) -> Selector {
        switch action {
        case .screenshot: return #selector(screenshot)
        case .scroll: return #selector(longScreenshot)
        case .text: return #selector(ocrScreenshot)
        case .pin: return #selector(pinClipboard)
        case .record: return #selector(recordScreen)
        case .subject: return #selector(subjectScreenshot)
        case .togglePins: return #selector(togglePins)
        case .recentContent: return #selector(showRecentContent)
        case .pinRecent: return #selector(pinRecentContent)
        }
    }

    private func refreshShortcutLabels() {
        (statusControls.menu as? GlobalShortcutMenu)?.globalShortcuts = Set(hotKeys.registeredBindings.values.flatMap { $0 })
        for action in ShortcutAction.allCases {
            let unavailable = hotKeys.unavailable.contains(action.legacyID)
            let suffix = unavailable ? L(" · 不可用") : ""
            let title = action == .pinRecent ? preferences.pinRecentTitle : action.title
            menuActions[action]?.title = "\(title)\(suffix)"
            if let item = menuActions[action] { updateMenuShortcut(item, action: action) }
        }
        refreshPinVisibilityAction()
        refreshRecordingActions()
        homeController?.refreshShortcuts()
    }

    @objc private func showSettings() {
        showHome()
    }

    private func applyOptions() {
        NSApp.appearance = preferences.appearancePreference.appearance
        if hotKeys != nil { refreshShortcutLabels() }
    }

    @objc private func showRecentContent() {
        guard homeController?.finishEditing() != false else { return }
        if recentController == nil {
            recentController = RecentContentWindowController(store: recentContent,
                onCopy: { [weak self] in self?.clipboardMonitor.acknowledgeCopy() }) { [weak self] item in
                self?.pinRecentItem(item, anchor: NSEvent.mouseLocation)
            }
        }
        recentController?.showWindow(nil)
    }

    @objc private func pinRecentContent() {
        guard homeController?.finishEditing() != false else { return }
        let anchor = NSEvent.mouseLocation
        let items = Array(recentContent.items.filter(\.isPinnable).prefix(preferences.pinRecentCount))
        // Open the latest record last, so it remains above the older staggered pins.
        for (index, item) in items.enumerated().reversed() {
            pinRecentItem(item, anchor: anchor, batchIndex: index)
        }
    }

    private func pinRecentItem(_ item: RecentContentStore.Item, anchor: NSPoint, batchIndex: Int = 0) {
        switch item.content {
        case .image(let data, _, let scale):
            guard let image = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            imageTools.pinImage(image, pixelScale: scale, recordsHistory: false, anchor: anchor, batchIndex: batchIndex)
        case .text(let text):
            if let rich = item.richText { imageTools.pinText(rich, recordsHistory: false, anchor: anchor, batchIndex: batchIndex) }
            else { imageTools.pinText(text, recordsHistory: false, anchor: anchor, batchIndex: batchIndex) }
        case .video: break // Video playback is handled by the history window, never by batch pinning.
        }
    }

    private func requestScreenPermission() {
        _ = captureService.ensurePermission()
        homeController?.refreshPermissions()
    }

    private func refreshPinVisibilityAction() {
        let title = L(imageTools.arePinsHidden ? "显示全部贴图" : "隐藏全部贴图")
        let suffix = hotKeys?.unavailable.contains(ShortcutAction.togglePins.legacyID) == true ? L(" · 不可用") : ""
        pinVisibilityMenuItem?.title = "\(title)\(suffix)"
        if let item = pinVisibilityMenuItem { updateMenuShortcut(item, action: .togglePins) }
        pinVisibilityMenuItem?.isEnabled = imageTools.canTogglePins
        homeController?.refreshShortcuts()
    }

    private func updateMenuShortcut(_ item: NSMenuItem, action: ShortcutAction) {
        // Menu construction precedes hotkey registration during application startup.
        // Leave the equivalent empty until installShortcuts refreshes the menu.
        let shortcut = hotKeys?.registeredBindings[action]?.first
        item.keyEquivalent = shortcut?.menuKeyEquivalent ?? ""
        item.keyEquivalentModifierMask = shortcut?.menuModifierFlags ?? []
        item.allowsAutomaticKeyEquivalentLocalization = false
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleRecordingPause) { return recording.canPauseOrResume }
        if menuItem.action == #selector(showRecordingControls) { return recording.canShowControls }
        if menuItem.action == #selector(pinRecentContent) { return recentContent.items.contains(where: \.isPinnable) }
        guard menuItem.action == #selector(togglePins) else { return true }
        refreshPinVisibilityAction()
        return imageTools.canTogglePins
    }

    @objc private func screenshot() { selectRegion(purpose: .screenshot) }
    @objc private func subjectScreenshot() { selectRegion(purpose: .screenshot, initialMode: .subject) }
    @objc private func ocrScreenshot() { selectRegion(purpose: .text) }
    @objc private func longScreenshot() { selectRegion(purpose: .scroll) }
    @objc private func recordScreen() {
        homeController?.editor.stopRecording()
        if recording.isRecording { recording.stop(); return }
        selectRegion(purpose: .record)
    }
    @objc private func toggleRecordingPause() { recording.togglePause() }
    @objc private func showRecordingControls() { recording.showControls() }

    private func refreshRecordingActions() {
        let active = recording.isRecording
        pauseRecordingItem?.isHidden = !active
        pauseRecordingItem?.title = L(recording.isPaused ? "继续录制" : "暂停录制")
        pauseRecordingItem?.isEnabled = recording.canPauseOrResume
        showRecordingControlsItem?.isHidden = !recording.canShowControls
        recordingMenuSeparator?.isHidden = !active
        let unavailable = hotKeys?.unavailable.contains(ShortcutAction.record.legacyID) == true ? L(" · 不可用") : ""
        menuActions[.record]?.title = L(active ? "停止录制" : "录屏") + unavailable
    }
    @objc private func pinClipboard() {
        homeController?.editor.stopRecording()
        imageTools.pinClipboard()
    }
    @objc private func togglePins() {
        imageTools.togglePins()
    }
    @objc private func showDemo() { imageTools.showEditor(DemoImage.make()) }
    @objc private func quit() { NSApp.terminate(nil) }

    private func selectRegion(purpose: CaptureSelectionPurpose, initialMode: ScreenshotSelectionMode = .window) {
        homeController?.editor.stopRecording()
        guard !scrollCapture.isActive else {
            showError(PatchError(message: "请先完成或取消正在进行的长截图。"))
            return
        }
        let permitted = captureService.ensurePermission()
        homeController?.refreshPermissions()
        guard permitted else { return }
        if purpose == .scroll, !ScrollCapturePermission.ensurePermission() { return }
        let target = NSWorkspace.shared.frontmostApplication
        selector.authorizeScroll = { ScrollCapturePermission.ensurePermission() }
        selector.select(purpose: purpose, initialMode: initialMode, targetApplication: target, capture: { [weak self] region in
            guard let self else { throw PatchError(message: "截图任务已关闭。") }
            return try await self.captureService.capture(region, hidePins: purpose == .record ? self.preferences.hidePinsWhenRecording : self.preferences.hidePinsWhenCapturing)
        }) { [weak self] action, region, image in
            self?.performSelectionAction(action, region: region, image: image)
        }
    }

    private func performSelectionAction(_ action: CaptureSelectionAction, region: CaptureRegion, image: CGImage?) {
        if action == .scroll { scrollCapture.start(region: region, initialFrame: image); return }
        if action == .record { recording.showControls(region: region); return }
        guard let image else { return }
        do {
            switch action {
            case .copy: try ImageToolsUI.copyPNG(image, pixelScale: region.scale)
            case .pin: imageTools.pinImage(image, pixelScale: region.scale)
            case .cutout: imageTools.showSubjectSelection(image, pixelScale: region.scale)
            case .ocr: imageTools.recognize(image)
            case .save, .scroll, .record: break
            }
        } catch {
            showError(error)
        }
    }

    @objc private func showHome() {
        if homeController == nil {
            homeController = HomeWindowController(hotKeys: hotKeys, store: preferences,
                onSave: { [weak self] in self?.refreshShortcutLabels() },
                onLaunch: { [weak self] action in
                    guard let self else { return }
                    switch action {
                    case .screenshot: self.screenshot()
                    case .scroll: self.longScreenshot()
                    case .text: self.ocrScreenshot()
                    case .pin: self.pinClipboard()
                    case .record: self.recordScreen()
                    case .subject: self.subjectScreenshot()
                    case .togglePins: self.togglePins()
                    case .recentContent: self.showRecentContent()
                    case .pinRecent: self.pinRecentContent()
                    }
                }, pinState: { [weak self] in (self?.imageTools.canTogglePins ?? false, self?.imageTools.arePinsHidden ?? false) },
                onQuit: { [weak self] in self?.quit() },
                onRecentContent: { [weak self] in self?.showRecentContent() },
                screenPermission: { [weak self] in self?.captureService.hasPermission ?? false },
                onRequestScreenPermission: { [weak self] in self?.requestScreenPermission() },
                onOptionsChanged: { [weak self] in self?.applyOptions() },
                hasRecentContent: { [weak self] in self?.recentContent.items.contains(where: \.isPinnable) ?? false })
        }
        homeController?.showHomePage()
        homeController?.showWindow(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if homeController?.finishEditing() == false {
            homeController?.showWindow(nil)
            return .terminateCancel
        }
        selector.cancel()
        scrollCapture.cancel()
        guard recording.isRecording else { return .terminateNow }
        recording.stop()
        quitTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, !self.recording.isRecording else { return }
                timer.invalidate()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusControls?.remove()
        clipboardMonitor.setEnabled(false)
        recentContent.clear()
        ImageToolsUI.onCompletedImage = nil; ImageToolsUI.onCompletedText = nil; ImageToolsUI.onCompletedRichText = nil
        recentController?.close()
        imageTools.closeAll()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }
}

/// Global bindings use the native right-hand menu column, but Carbon owns dispatch.
/// Keep ordinary application commands (Settings / Quit) on AppKit's normal path.
@MainActor
private final class GlobalShortcutMenu: NSMenu {
    var globalShortcuts: Set<KeyboardShortcut> = []
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if globalShortcuts.contains(KeyboardShortcut(event: event)) { return false }
        return super.performKeyEquivalent(with: event)
    }
}

extension KeyboardShortcut {
    var menuModifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        return flags
    }

    var menuKeyEquivalent: String {
        let special: [UInt32: Int] = [
            36: 13, 49: 32, 76: 3, 71: NSClearLineFunctionKey,
            115: NSHomeFunctionKey, 116: NSPageUpFunctionKey, 119: NSEndFunctionKey,
            121: NSPageDownFunctionKey, 123: NSLeftArrowFunctionKey, 124: NSRightArrowFunctionKey,
            125: NSDownArrowFunctionKey, 126: NSUpArrowFunctionKey
        ]
        if let value = special[keyCode], let scalar = UnicodeScalar(value) { return String(scalar) }
        guard let name = Self.keyNames[keyCode] else { return "" }
        if name.hasPrefix("F"), let number = Int(name.dropFirst()), (1...20).contains(number),
           let scalar = UnicodeScalar(NSF1FunctionKey + number - 1) { return String(scalar) }
        let key = name.replacingOccurrences(of: "数字键 ", with: "")
            .replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: "′", with: "'")
        return key.lowercased()
    }
}
