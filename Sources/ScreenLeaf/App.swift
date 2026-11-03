// SPDX-FileCopyrightText: 2026 caijyii
// SPDX-License-Identifier: MIT

import AppKit
import Carbon
import Darwin

@main
struct ScreenLeafMain {
    static func main() {
        let app = NSApplication.shared
        if ProcessInfo.processInfo.arguments.contains("--ocr-self-check") {
            let passed = ImageToolsDiagnostics.checkOCR(DemoImage.make())
            exit(passed ? 0 : 1)
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var statusItem: NSStatusItem!
    private var homeController: HomeWindowController?
    private let selector = RegionSelector()
    private let captureService = CaptureService()
    private let imageTools = ImageToolsCoordinator()
    private let recording = RecordingCoordinator()
    private var hotKeys: HotKeys!
    private let preferences: PreferencesStore
    private let hotKeyBackend: HotKeyBackend?
    private var menuActions: [ShortcutAction: NSMenuItem] = [:]
    private var pinVisibilityMenuItem: NSMenuItem?

    init(preferences: PreferencesStore? = nil, hotKeyBackend: HotKeyBackend? = nil) {
        self.preferences = preferences ?? .shared
        self.hotKeyBackend = hotKeyBackend
        super.init()
    }
    private var lastExternalApplication: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?
    private var quitTimer: Timer?
    private lazy var scrollCapture = ScrollCaptureCoordinator(capture: { [weak self] region in
        guard let self else { throw ScreenLeafError(message: "截图任务已关闭。") }
        return try await self.captureService.capture(region)
    }, onComplete: { [weak self] image, action in
        guard let self else { throw ScreenLeafError(message: "截图任务已关闭。") }
        switch action {
        case .copy: try ImageToolsUI.copyPNG(image)
        case .annotate: self.imageTools.showEditor(image)
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
        showHome()
        return false
    }

    private func installMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = IconArtwork.menuBarImage()
        statusItem.button?.toolTip = "小贴 · Patch · 截图、长截图、贴图和录屏"
        let menu = GlobalShortcutMenu()
        for action in ShortcutAction.displayOrder {
            let item = NSMenuItem(title: action.title, action: selector(for: action), keyEquivalent: "")
            item.target = self
            menuActions[action] = item
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let pinItem = NSMenuItem(title: "隐藏全部贴图", action: #selector(togglePins), keyEquivalent: "")
        pinItem.target = self
        pinVisibilityMenuItem = pinItem
        menuActions[.togglePins] = pinItem
        menu.addItem(pinItem)
        for (title, action, key) in [("设置", #selector(showSettings), ","), ("退出", #selector(quit), "q")] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            menu.addItem(item)
        }
        statusItem.menu = menu
        refreshPinVisibilityAction()
        let appMenu = NSMenu()
        let rootItem = NSMenuItem()
        let applicationMenu = NSMenu()
        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        let settingsItem = NSMenuItem(title: "设置", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        applicationMenu.addItem(settingsItem)
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(quitItem)
        rootItem.submenu = applicationMenu
        appMenu.addItem(rootItem)
        // Standard editing shortcuts also work in editable text pins and OCR results.
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", Selector(("undo:")), "z"), ("剪切", #selector(NSText.cut(_:)), "x"),
                                   ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"),
                                   ("全选", #selector(NSText.selectAll(_:)), "a")] {
            editMenu.addItem(NSMenuItem(title: title, action: action, keyEquivalent: key))
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
            .togglePins: { [weak self] in self?.togglePins() }
        ]
        hotKeys.installShortcuts(preferences.shortcuts, actions: actions)
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
        }
    }

    private func refreshShortcutLabels() {
        (statusItem.menu as? GlobalShortcutMenu)?.globalShortcuts = Set(preferences.shortcuts.values.filter { !$0.isApplicationReserved })
        for action in ShortcutAction.allCases {
            let unavailable = hotKeys.unavailable.contains(action.legacyID)
            let suffix = unavailable ? " · 不可用" : ""
            menuActions[action]?.title = "\(action.title)\(suffix)"
            if let item = menuActions[action] { updateMenuShortcut(item, action: action) }
        }
        refreshPinVisibilityAction()
        homeController?.refreshShortcuts()
    }

    @objc private func showSettings() {
        showHome()
    }

    private func refreshPinVisibilityAction() {
        let title = imageTools.arePinsHidden ? "显示全部贴图" : "隐藏全部贴图"
        let suffix = hotKeys?.unavailable.contains(ShortcutAction.togglePins.legacyID) == true ? " · 不可用" : ""
        pinVisibilityMenuItem?.title = "\(title)\(suffix)"
        if let item = pinVisibilityMenuItem { updateMenuShortcut(item, action: .togglePins) }
        pinVisibilityMenuItem?.isEnabled = imageTools.hasPins
        homeController?.refreshShortcuts()
    }

    private func updateMenuShortcut(_ item: NSMenuItem, action: ShortcutAction) {
        let shortcut = preferences.shortcuts[action]
        item.keyEquivalent = shortcut?.menuKeyEquivalent ?? ""
        item.keyEquivalentModifierMask = shortcut?.menuModifierFlags ?? []
        item.allowsAutomaticKeyEquivalentLocalization = false
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(togglePins) else { return true }
        refreshPinVisibilityAction()
        return imageTools.hasPins
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
    @objc private func pinClipboard() {
        homeController?.editor.stopRecording()
        imageTools.pinClipboard()
    }
    @objc private func togglePins() {
        imageTools.togglePins()
        refreshPinVisibilityAction()
    }
    @objc private func showDemo() { imageTools.showEditor(DemoImage.make()) }
    @objc private func quit() { NSApp.terminate(nil) }

    private func selectRegion(purpose: CaptureSelectionPurpose, initialMode: ScreenshotSelectionMode = .window) {
        homeController?.editor.stopRecording()
        guard !scrollCapture.isActive else {
            showError(ScreenLeafError(message: "请先完成或取消正在进行的长截图。"))
            return
        }
        guard captureService.ensurePermission() else { return }
        if purpose == .scroll, !ScrollCapturePermission.ensurePermission() { return }
        homeController?.window?.orderOut(nil)
        let frontmost = NSWorkspace.shared.frontmostApplication
        let target = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? lastExternalApplication : frontmost
        selector.select(purpose: purpose, initialMode: initialMode, targetApplication: target, capture: { [weak self] region in
            guard let self else { throw ScreenLeafError(message: "截图任务已关闭。") }
            return try await self.captureService.capture(region)
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
                    }
                }, pinState: { [weak self] in (self?.imageTools.hasPins ?? false, self?.imageTools.arePinsHidden ?? false) },
                onQuit: { [weak self] in self?.quit() })
        }
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
