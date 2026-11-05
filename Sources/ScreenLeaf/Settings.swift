// SPDX-FileCopyrightText: 2026 caijyii
// SPDX-License-Identifier: MIT

import AppKit

@MainActor
private final class ShortcutSettingsContentView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        super.draw(dirtyRect)
    }
}

@MainActor
final class ShortcutSettingsWindow: NSWindow {
    var onRecordingKey: ((NSEvent) -> Bool)?
    var onRecordingModifiers: ((NSEvent) -> Void)?
    var onCancelRequest: (() -> Void)?
    var onPointerDown: ((NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type), onPointerDown?(event) == true { return }
        // Capture Control characters before first-responder key bindings can interpret them.
        if event.type == .keyDown, onRecordingKey?(event) == true { return }
        if event.type == .flagsChanged { onRecordingModifiers?(event) }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onRecordingKey?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) { onCancelRequest?() }
}

@MainActor
final class ShortcutRecorderButton: NSButton {
    var onClick: (() -> Void)?
    var onKey: ((NSEvent) -> Bool)?
    var onCancel: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        alignment = .center
        target = self
        action = #selector(clicked)
        toolTip = L("点击后按下新的快捷键；Esc 取消，Tab 切换。")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func clicked() { onClick?() }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKey?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

@MainActor
final class ShortcutEditorSession {
    private let hotKeys: HotKeys
    private let store: PreferencesStore
    private let onSave: () -> Void
    private let appliesImmediately: Bool
    private let keepsRecordingUntilFinished: Bool
    private(set) var draft: [ShortcutAction: KeyboardShortcut]
    private(set) var recordingAction: ShortcutAction?
    /// Outcome of the most recent immediate restore, including successful saves with cleanup warnings.
    private(set) var defaultsWereCommitted = false
    var onUpdate: (() -> Void)?
    private var recordingModifiers: String?
    private var failedBindings: [ShortcutAction: KeyboardShortcut] = [:]
    private var failedReasons: [ShortcutAction: ShortcutUpdateError] = [:]
    private var messages: [ShortcutAction: String] = [:]
    private var conciseMessages: [ShortcutAction: String] = [:]
    private var issueActions: Set<ShortcutAction> = []
    private var persistenceFailed = false
    private var rejectedInputs: [ShortcutAction: KeyboardShortcut] = [:]
    private var editedActions: Set<ShortcutAction> = []

    init(hotKeys: HotKeys, store: PreferencesStore? = nil, appliesImmediately: Bool = false, keepsRecordingUntilFinished: Bool = false,
         onSave: @escaping () -> Void = {}) {
        let store = store ?? .shared
        self.hotKeys = hotKeys
        self.store = store
        self.onSave = onSave
        self.appliesImmediately = appliesImmediately
        self.keepsRecordingUntilFinished = keepsRecordingUntilFinished
        draft = store.shortcuts
        refreshFeedback()
    }

    private(set) var hasBlockingShortcutIssues = false
    var hasIssues: Bool { !issueActions.isEmpty }
    func hasIssue(_ action: ShortcutAction) -> Bool { issueActions.contains(action) }
    func message(_ action: ShortcutAction) -> String { messages[action] ?? "" }
    func conciseMessage(_ action: ShortcutAction) -> String { conciseMessages[action] ?? "" }

    func recordingTitle(_ action: ShortcutAction) -> String {
        let saved = draft[action]?.displayString ?? L("未设置")
        if recordingAction == action && keepsRecordingUntilFinished { return recordingModifiers ?? saved }
        return recordingAction == action ? (recordingModifiers ?? LF("%@ · 录入中", saved)) : saved
    }

    func reset() {
        endRecording()
        draft = store.shortcuts
        editedActions = []
        clearFailures()
        refreshFeedback()
    }

    func startRecording(_ action: ShortcutAction) {
        endRecording()
        if appliesImmediately {
            draft = store.shortcuts
            rejectedInputs.removeValue(forKey: action)
            failedBindings.removeValue(forKey: action)
            failedReasons.removeValue(forKey: action)
        }
        recordingAction = action
        hotKeys.beginRecording { [weak self] shortcut in self?.accept(shortcut) }
        refreshFeedback()
    }

    func reflectModifiers(_ event: NSEvent) {
        guard recordingAction != nil else { return }
        var value = ""
        if event.modifierFlags.contains(.control) { value += "⌃" }
        if event.modifierFlags.contains(.option) { value += "⌥" }
        if event.modifierFlags.contains(.shift) { value += "⇧" }
        if event.modifierFlags.contains(.command) { value += "⌘" }
        recordingModifiers = value.isEmpty ? nil : value + "…"
        onUpdate?()
    }

    @discardableResult
    func capture(_ event: NSEvent) -> Bool {
        guard recordingAction != nil, event.type == .keyDown else { return false }
        if event.keyCode == 48 { stopRecording(); return false }
        if event.keyCode == 53 { stopRecording(); return true }
        if !event.isARepeat { accept(KeyboardShortcut(event: event)) }
        return true
    }

    func stopRecording() {
        endRecording()
        refreshFeedback()
    }

    func restoreDefaults() {
        endRecording()
        if appliesImmediately {
            applyDefaultsImmediately()
            return
        }
        draft = ShortcutAction.defaultShortcuts
        editedActions = Set(ShortcutAction.allCases)
        clearFailures()
        refreshFeedback()
    }

    /// Home restores immediately even while manually entered shortcuts remain drafts.
    /// A false result can also mean the defaults were saved with a cleanup warning.
    @discardableResult
    func restoreDefaultsImmediately() -> Bool {
        endRecording()
        return applyDefaultsImmediately()
    }

    /// A cleanup warning leaves the saved configuration active, but keeps the editor open for feedback.
    @discardableResult
    func save() -> Bool {
        endRecording()
        persistenceFailed = false
        // Persist a complete valid configuration, including inactive saved keys.
        // An untouched legacy application command may remain unavailable, but a
        // duplicate of that saved key must still prevent the entire transaction.
        if let invalid = ShortcutAction.allCases.first(where: { draft[$0]?.isValid != true }) {
            showFailure(.invalid(invalid))
            return false
        }
        let issues = HotKeys.validationIssues(draft)
        if let duplicate = ShortcutAction.allCases.compactMap({ issues[$0] }).first(where: {
            if case .duplicate = $0 { return true }
            return false
        }) {
            showFailure(duplicate)
            return false
        }
        // Apply every recorded action together so swaps stay atomic. Recording
        // the same value also explicitly retries an unavailable registration.
        var active = hotKeys.registeredShortcuts
        for action in editedActions { active[action] = draft[action] }
        switch hotKeys.applyShortcuts(active) {
        case .success:
            guard store.setShortcuts(draft) else {
                persistenceFailed = true
                refreshFeedback()
                return false
            }
            editedActions = []
            clearFailures()
            refreshFeedback()
            onSave()
            return hotKeys.cleanupWarnings.isEmpty
        case .failure(let error):
            showFailure(error)
            return false
        }
    }

    private func accept(_ shortcut: KeyboardShortcut) {
        guard let action = recordingAction else { return }
        if appliesImmediately {
            endRecording()
            applyImmediately(shortcut, for: action)
            return
        }
        // Even a rejected chord remains visible; active bindings change only after Save.
        draft[action] = shortcut
        editedActions.insert(action)
        failedBindings.removeValue(forKey: action)
        failedReasons.removeValue(forKey: action)
        persistenceFailed = false
        recordingModifiers = nil
        if !keepsRecordingUntilFinished { endRecording() }
        refreshFeedback()
    }

    private func applyImmediately(_ shortcut: KeyboardShortcut, for action: ShortcutAction) {
        // A rejected attempt must never leak into another feature's next update.
        var desired = store.shortcuts
        desired[action] = shortcut
        rejectedInputs.removeValue(forKey: action)
        failedReasons.removeValue(forKey: action)
        let localIssues = HotKeys.validationIssues(desired)
        if let error = localIssues[action] {
            reject(shortcut, for: action, reason: error)
            return
        }
        // Older configurations can contain an unavailable application command.
        // Keep that independent failure repairable without blocking this item.
        // Duplicate stored values still cannot be persisted, so check that
        // schema constraint before changing any live registrations.
        if let duplicate = ShortcutAction.allCases.compactMap({ localIssues[$0] }).first(where: {
            if case .duplicate = $0 { return true }
            return false
        }) {
            reject(shortcut, for: action, reason: duplicate)
            return
        }
        // Retry this feature without forcing unrelated unavailable startup keys
        // back into the registration transaction.
        var active = hotKeys.registeredShortcuts
        active[action] = shortcut
        switch hotKeys.applyShortcuts(active) {
        case .failure(let error): reject(shortcut, for: action, reason: error)
        case .success:
            guard store.setShortcuts(desired) else {
                persistenceFailed = true
                refreshFeedback()
                return
            }
            draft = desired
            persistenceFailed = false
            refreshFeedback()
            onSave()
        }
    }

    private func reject(_ shortcut: KeyboardShortcut, for action: ShortcutAction, reason: ShortcutUpdateError) {
        draft = store.shortcuts
        rejectedInputs[action] = shortcut
        failedReasons[action] = reason
        refreshFeedback()
    }

    @discardableResult
    private func applyDefaultsImmediately() -> Bool {
        defaultsWereCommitted = false
        editedActions = []
        let defaults = ShortcutAction.defaultShortcuts
        clearFailures()
        switch hotKeys.applyShortcuts(defaults) {
        case .success:
            guard store.setShortcuts(defaults) else {
                persistenceFailed = true
                refreshFeedback()
                return false
            }
            draft = defaults
            defaultsWereCommitted = true
            refreshFeedback()
            onSave()
            return hotKeys.cleanupWarnings.isEmpty
        case .failure(let error):
            // Restoring defaults is one transaction: any rejection keeps every
            // previous saved and active binding intact.
            let affected: [ShortcutAction]
            switch error {
            case .invalid(let action), .applicationReserved(let action), .systemReserved(let action), .registrationFailed(let action, _): affected = [action]
            case .duplicate(let first, let second): affected = [first, second]
            case .systemCheckFailed, .handlerFailed: affected = ShortcutAction.allCases
            }
            for action in affected {
                rejectedInputs[action] = defaults[action]
                failedReasons[action] = error
            }
            draft = store.shortcuts
            refreshFeedback()
            return false
        }
    }

    private func endRecording() {
        if recordingAction != nil { hotKeys.endRecording() }
        recordingAction = nil
        recordingModifiers = nil
    }

    private func clearFailures() {
        failedBindings = [:]
        failedReasons = [:]
        persistenceFailed = false
        rejectedInputs = [:]
    }

    private func showFailure(_ error: ShortcutUpdateError) {
        let affected: [ShortcutAction]
        switch error {
        case .invalid(let action), .applicationReserved(let action), .systemReserved(let action), .registrationFailed(let action, _):
            affected = [action]
        // Duplicate feedback depends on both current values and is recomputed below.
        // Caching it per action would survive when only the other endpoint changes.
        case .duplicate: affected = []
        case .systemCheckFailed, .handlerFailed: affected = ShortcutAction.allCases
        }
        for action in affected { failedBindings[action] = draft[action]; failedReasons[action] = error }
        refreshFeedback()
    }

    private func refreshFeedback() {
        var issues = hotKeys.shortcutIssues(draft)
        // Known invalid/conflicting chords must be corrected before submission.
        // Operational failures remain retryable; cached failures from a rejected
        // default restore do not describe the current draft.
        hasBlockingShortcutIssues = issues.values.contains { issue in
            switch issue {
            case .invalid, .duplicate, .applicationReserved, .systemReserved: return true
            case .registrationFailed, .systemCheckFailed, .handlerFailed: return false
            }
        }
        // Immediate default restoration can reject a chord in either editor mode.
        // Stored values stay visible while feedback describes the rejected attempt.
        for action in ShortcutAction.allCases where rejectedInputs[action] != nil {
            if let failure = failedReasons[action] { issues[action] = failure }
        }
        for action in ShortcutAction.allCases where issues[action] == nil {
            if failedBindings[action] == draft[action], let failure = failedReasons[action] { issues[action] = failure }
            else if draft[action] == store.shortcuts[action], let unavailable = hotKeys.unavailableReasons[action] {
                issues[action] = unavailable
            }
        }
        issueActions = Set(issues.keys)
        for action in ShortcutAction.allCases {
            var message: String
            let concise: String
            if persistenceFailed { concise = L("保存失败") }
            else if let issue = issues[action] {
                switch issue {
                case .duplicate, .applicationReserved, .systemReserved: concise = L("快捷键冲突")
                case .invalid: concise = L("组合无效")
                case .registrationFailed: concise = L("快捷键不可用")
                case .systemCheckFailed: concise = L("暂时无法检查")
                case .handlerFailed: concise = L("需重启 Patch")
                }
            } else if hotKeys.cleanupFailures[action] != nil { concise = L("需重启 Patch") }
            else { concise = "" }
            conciseMessages[action] = concise
            if persistenceFailed {
                message = L("配置未保存，请重新选择快捷键。")
                issueActions.insert(action)
            } else if let input = rejectedInputs[action], let issue = failedReasons[action] {
                let reason: String
                if case .invalid = issue { reason = input.invalidReason ?? issue.localizedDescription }
                else { reason = issue.localizedDescription }
                let retained = store.shortcuts[action]?.displayString ?? L("原配置")
                let status = hotKeys.registeredShortcuts[action] == store.shortcuts[action] ? LF("仍使用 %@。", retained) : LF("原配置 %@ 未更改。", retained)
                message = "\(input.displayString)：\(reason)\n\(status)"
            } else if let issue = issues[action] {
                if case .invalid = issue { message = draft[action]?.invalidReason ?? issue.localizedDescription }
                else { message = issue.localizedDescription }
            } else if recordingAction == action {
                message = L("按下快捷键；Esc 取消，Tab 切换。")
            } else { message = "" }
            if hotKeys.cleanupFailures[action] != nil {
                message += (message.isEmpty ? "" : "\n") + L("快捷键释放未完成，请重新打开小贴。")
                issueActions.insert(action)
            }
            messages[action] = message
        }
        onUpdate?()
    }
}

@MainActor
final class SettingsController: NSWindowController, NSWindowDelegate {
    private let session: ShortcutEditorSession
    private var recorders: [ShortcutAction: ShortcutRecorderButton] = [:]
    private var notes: [ShortcutAction: NSTextField] = [:]
    private let stack = NSStackView()

    init(hotKeys: HotKeys, store: PreferencesStore? = nil, onChange: @escaping () -> Void = {}) {
        session = ShortcutEditorSession(hotKeys: hotKeys, store: store, onSave: onChange)
        let window = ShortcutSettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 470),
                                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        PatchWindowTitle.apply(to: window, title: L("Patch · 设置"))
        window.isReleasedWhenClosed = false
        window.contentView = ShortcutSettingsContentView(frame: NSRect(x: 0, y: 0, width: 640, height: 470))
        super.init(window: window)
        window.delegate = self
        window.onRecordingKey = { [weak self] event in self?.session.capture(event) ?? false }
        window.onRecordingModifiers = { [weak self] event in self?.session.reflectModifiers(event) }
        window.onCancelRequest = { [weak self] in self?.cancelRecordingOrClose() }
        session.onUpdate = { [weak self] in self?.refreshFeedback() }
        buildContent()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func showWindow(_ sender: Any?) {
        if window?.isVisible != true {
            session.reset()
        }
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22)
        ])
        let title = NSTextField(labelWithString: L("快捷键"))
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        stack.addArrangedSubview(title)
        for action in ShortcutAction.settingsOrder {
            let label = NSTextField(labelWithString: action.title)
            label.font = .systemFont(ofSize: 13)
            label.widthAnchor.constraint(equalToConstant: 248).isActive = true
            let recorder = ShortcutRecorderButton()
            recorder.widthAnchor.constraint(equalToConstant: 320).isActive = true
            recorder.heightAnchor.constraint(equalToConstant: 30).isActive = true
            recorder.setAccessibilityLabel(LF("%@快捷键", action.title))
            recorder.onClick = { [weak self] in self?.startRecording(action) }
            recorder.onKey = { [weak self] event in self?.session.capture(event) ?? false }
            recorder.onCancel = { [weak self] in self?.cancelRecordingOrClose() }
            recorders[action] = recorder
            let note = NSTextField(wrappingLabelWithString: "")
            note.font = .systemFont(ofSize: 11)
            note.textColor = .systemOrange
            note.widthAnchor.constraint(equalToConstant: 320).isActive = true
            note.setAccessibilityLabel(LF("%@快捷键提示", action.title))
            notes[action] = note
            let entry = NSStackView(views: [recorder, note])
            entry.orientation = .vertical
            entry.alignment = .leading
            entry.spacing = 4
            let row = NSStackView(views: [label, entry])
            row.alignment = .top
            row.spacing = 24
            stack.addArrangedSubview(row)
        }
        let defaults = NSButton(title: L("恢复默认"), target: self, action: #selector(restoreDefaults))
        defaults.bezelStyle = .rounded
        let save = NSButton(title: L("保存"), target: self, action: #selector(save))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        let close = NSButton(title: L("关闭"), target: self, action: #selector(closeSettings))
        close.bezelStyle = .rounded
        let actions = NSStackView(views: [defaults, close, save])
        actions.spacing = 12
        stack.addArrangedSubview(actions)
        refreshFeedback()
    }

    private func refreshFeedback() {
        for action in ShortcutAction.allCases {
            let message = session.message(action)
            notes[action]?.stringValue = message
            notes[action]?.isHidden = message.isEmpty
            notes[action]?.textColor = session.hasIssue(action) ? .systemOrange : .secondaryLabelColor
            recorders[action]?.title = session.recordingTitle(action)
        }
        layoutWindow()
    }

    private func layoutWindow() {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let height = max(312, stack.fittingSize.height + 44)
        let difference = height - content.bounds.height
        guard abs(difference) > 1 else { return }
        var frame = window.frame
        frame.origin.y -= difference
        frame.size.height += difference
        window.setFrame(frame, display: window.isVisible)
    }

    private func startRecording(_ action: ShortcutAction) {
        session.startRecording(action)
        window?.makeFirstResponder(recorders[action])
    }

    private func cancelRecordingOrClose() {
        if session.recordingAction != nil { session.stopRecording() }
        else { window?.close() }
    }

    @objc private func save() {
        if session.save() { window?.close() }
    }

    @objc private func restoreDefaults() { session.restoreDefaults() }

    @objc private func closeSettings() { window?.close() }
    func windowWillClose(_ notification: Notification) { session.stopRecording() }
    func windowDidResignKey(_ notification: Notification) {
        if session.recordingAction != nil { session.stopRecording() }
    }

    // Hooks exercise local view events and the injected fake backend only.
    var verificationStatus: String { ShortcutAction.allCases.compactMap { notes[$0]?.stringValue }.filter { !$0.isEmpty }.joined(separator: "\n") }
    var verificationDraft: [ShortcutAction: KeyboardShortcut] { session.draft }
    func verificationRowMessage(_ action: ShortcutAction) -> String { notes[action]?.isHidden == false ? notes[action]?.stringValue ?? "" : "" }
    func verificationRecorderTitle(_ action: ShortcutAction) -> String { recorders[action]?.title ?? "" }
    func verificationStartRecording(_ action: ShortcutAction) { startRecording(action) }
    func verificationCapture(_ event: NSEvent) -> Bool { session.capture(event) }
    func verificationSave() { save() }
    func verificationRestoreDefaults() { restoreDefaults() }
}
