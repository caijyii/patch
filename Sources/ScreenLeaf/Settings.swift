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
    private struct Slot: Hashable { let action: ShortcutAction; let index: Int }
    private let hotKeys: HotKeys
    private let store: PreferencesStore
    private let onSave: () -> Void
    private let appliesImmediately: Bool
    private let keepsRecordingUntilFinished: Bool
    private(set) var bindingDraft: [ShortcutAction: [KeyboardShortcut]]
    var draft: [ShortcutAction: KeyboardShortcut] { bindingDraft.compactMapValues(\.first) }
    private(set) var recordingAction: ShortcutAction?
    private(set) var recordingIndex: Int?
    private(set) var defaultsWereCommitted = false
    var onUpdate: (() -> Void)?
    private var recordingModifiers: String?
    private var recordedBindings: [Slot: KeyboardShortcut] = [:]
    private var strictCandidates: Set<KeyboardShortcut> { Set(recordedBindings.values) }
    private var failedBindings: [Slot: KeyboardShortcut] = [:]
    private var failedReasons: [Slot: ShortcutUpdateError] = [:]
    private var rejectedInputs: [Slot: KeyboardShortcut] = [:]
    private var slotMessages: [Slot: String] = [:]
    private var slotIssues: [Slot: ShortcutUpdateError] = [:]
    private var persistenceFailed = false
    private(set) var hasBlockingShortcutIssues = false
    var hasIssues: Bool { !slotIssues.isEmpty || persistenceFailed || !hotKeys.cleanupWarnings.isEmpty }

    init(hotKeys: HotKeys, store: PreferencesStore? = nil, appliesImmediately: Bool = false,
         keepsRecordingUntilFinished: Bool = false, onSave: @escaping () -> Void = {}) {
        let store = store ?? .shared
        self.hotKeys = hotKeys; self.store = store; self.onSave = onSave
        self.appliesImmediately = appliesImmediately; self.keepsRecordingUntilFinished = keepsRecordingUntilFinished
        bindingDraft = store.shortcutBindings
        refreshFeedback()
    }
    func hasIssue(_ action: ShortcutAction) -> Bool {
        persistenceFailed || slotIssues.keys.contains { $0.action == action } || hotKeys.cleanupFailures[action] != nil
    }
    func hasIssue(_ action: ShortcutAction, index: Int) -> Bool {
        persistenceFailed || slotIssues[Slot(action: action, index: index)] != nil || hotKeys.cleanupFailures[action] != nil
    }
    func message(_ action: ShortcutAction) -> String {
        (0..<max(1, bindingDraft[action, default: []].count)).map { message(action, index: $0) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }
    func message(_ action: ShortcutAction, index: Int) -> String { slotMessages[Slot(action: action, index: index)] ?? "" }
    func conciseMessage(_ action: ShortcutAction) -> String {
        if persistenceFailed { return L("保存失败") }
        let issue = (0..<2).compactMap { slotIssues[Slot(action: action, index: $0)] }.first
        if let issue {
            switch issue {
            case .duplicate, .applicationReserved, .systemReserved: return L("快捷键冲突")
            case .invalid: return L("组合无效")
            case .registrationFailed: return L("快捷键不可用")
            case .systemCheckFailed: return L("暂时无法检查")
            case .handlerFailed: return L("需重启 Patch")
            }
        }
        return hotKeys.cleanupFailures[action] == nil ? "" : L("需重启 Patch")
    }
    func recordingTitle(_ action: ShortcutAction) -> String { recordingTitle(action, index: 0) }
    func recordingTitle(_ action: ShortcutAction, index: Int) -> String {
        let values = bindingDraft[action, default: []]
        let saved = values.indices.contains(index) ? values[index].displayString : L("未设置")
        guard recordingAction == action && recordingIndex == index else { return saved }
        if !values.indices.contains(index) { return recordingModifiers ?? L("按组合键") }
        if keepsRecordingUntilFinished { return recordingModifiers ?? saved }
        return recordingModifiers ?? LF("%@ · 录入中", saved)
    }
    func reset() {
        endRecording(); bindingDraft = store.shortcutBindings; recordedBindings = [:]; clearFailures(); refreshFeedback()
    }
    func retryUnavailableBindings() {
        guard recordingAction == nil else { return }
        hotKeys.retryUnavailableBindings(); refreshFeedback(); onSave()
    }
    func refreshAvailability() { refreshFeedback(notify: false) }
    func startRecording(_ action: ShortcutAction, index: Int = 0) {
        guard index >= 0, index < 2, index <= bindingDraft[action, default: []].count else { return }
        endRecording()
        if appliesImmediately { bindingDraft = store.shortcutBindings; clearFailures() }
        recordingAction = action; recordingIndex = index
        hotKeys.beginRecording { [weak self] in self?.accept($0) }
        refreshFeedback()
    }
    func removeShortcut(_ action: ShortcutAction, index: Int) {
        guard bindingDraft[action, default: []].indices.contains(index) else { return }
        endRecording()
        bindingDraft[action]!.remove(at: index)
        var reindexed: [Slot: KeyboardShortcut] = [:]
        for (slot, key) in recordedBindings {
            if slot.action != action || slot.index < index { reindexed[slot] = key }
            else if slot.index > index { reindexed[Slot(action: action, index: slot.index - 1)] = key }
        }
        recordedBindings = reindexed; clearFailures(); refreshFeedback()
    }
    func reflectModifiers(_ event: NSEvent) {
        guard recordingAction != nil else { return }
        var value = ""
        if event.modifierFlags.contains(.control) { value += "⌃" }
        if event.modifierFlags.contains(.option) { value += "⌥" }
        if event.modifierFlags.contains(.shift) { value += "⇧" }
        if event.modifierFlags.contains(.command) { value += "⌘" }
        recordingModifiers = value.isEmpty ? nil : value + "…"; onUpdate?()
    }
    @discardableResult func capture(_ event: NSEvent) -> Bool {
        guard recordingAction != nil, event.type == .keyDown else { return false }
        if event.keyCode == 48 { stopRecording(); return false }
        if event.keyCode == 53 { stopRecording(); return true }
        if !event.isARepeat { accept(KeyboardShortcut(event: event)) }; return true
    }
    func stopRecording() { endRecording(); refreshFeedback() }
    func restoreDefaults() {
        endRecording()
        if appliesImmediately { _ = applyDefaultsImmediately(); return }
        bindingDraft = ShortcutAction.defaultShortcuts.mapValues { [$0] }
        recordedBindings = Dictionary(uniqueKeysWithValues: bindingDraft.flatMap { action, keys in
            keys.enumerated().map { (Slot(action: action, index: $0.offset), $0.element) }
        })
        clearFailures(); refreshFeedback()
    }
    @discardableResult func restoreDefaultsImmediately() -> Bool { endRecording(); return applyDefaultsImmediately() }
    private var toleratedSavedKeys: Set<KeyboardShortcut> {
        Set(store.shortcutBindings.values.flatMap { $0 }).subtracting(strictCandidates)
    }
    @discardableResult func save() -> Bool {
        endRecording(); persistenceFailed = false
        refreshFeedback()
        // Validation covers the complete draft; operational failures of unchanged
        // saved chords remain independent of edits to another chord.
        guard !hasBlockingShortcutIssues else { return false }
        switch hotKeys.applyBindings(bindingDraft, allowingUnavailable: toleratedSavedKeys) {
        case .success:
            guard store.setShortcutBindings(bindingDraft) else { persistenceFailed = true; refreshFeedback(); return false }
            recordedBindings = [:]; clearFailures(); refreshFeedback(); onSave()
            return hotKeys.cleanupWarnings.isEmpty
        case .failure(let error): showFailure(error); return false
        }
    }
    private func accept(_ shortcut: KeyboardShortcut) {
        guard let action = recordingAction, let index = recordingIndex else { return }
        let slot = Slot(action: action, index: index)
        if appliesImmediately { endRecording(); applyImmediately(shortcut, slot: slot); return }
        if bindingDraft[action, default: []].indices.contains(index) { bindingDraft[action]![index] = shortcut }
        else { bindingDraft[action, default: []].append(shortcut) }
        recordedBindings[slot] = shortcut; failedBindings.removeValue(forKey: slot); failedReasons.removeValue(forKey: slot)
        persistenceFailed = false; recordingModifiers = nil
        if !keepsRecordingUntilFinished { endRecording() }
        refreshFeedback()
    }
    private func applyImmediately(_ shortcut: KeyboardShortcut, slot: Slot) {
        var desired = store.shortcutBindings
        if desired[slot.action, default: []].indices.contains(slot.index) { desired[slot.action]![slot.index] = shortcut }
        else { desired[slot.action, default: []].append(shortcut) }
        rejectedInputs.removeValue(forKey: slot); failedReasons.removeValue(forKey: slot)
        let tolerated = Set(store.shortcutBindings.values.flatMap { $0 }).subtracting([shortcut])
        switch hotKeys.applyBindings(desired, allowingUnavailable: tolerated) {
        case .failure(let error):
            bindingDraft = store.shortcutBindings; rejectedInputs[slot] = shortcut; failedReasons[slot] = error; refreshFeedback()
        case .success:
            guard store.setShortcutBindings(desired) else { persistenceFailed = true; refreshFeedback(); return }
            bindingDraft = desired; persistenceFailed = false; refreshFeedback(); onSave()
        }
    }
    @discardableResult private func applyDefaultsImmediately() -> Bool {
        defaultsWereCommitted = false; recordedBindings = [:]; clearFailures()
        let defaults = ShortcutAction.defaultShortcuts.mapValues { [$0] }
        switch hotKeys.applyBindings(defaults) {
        case .success:
            guard store.setShortcutBindings(defaults) else { persistenceFailed = true; refreshFeedback(); return false }
            bindingDraft = defaults; defaultsWereCommitted = true; refreshFeedback(); onSave()
            return hotKeys.cleanupWarnings.isEmpty
        case .failure(let error):
            for action in affectedActions(error) {
                let slot = Slot(action: action, index: 0)
                rejectedInputs[slot] = defaults[action]?.first; failedReasons[slot] = error
            }
            bindingDraft = store.shortcutBindings; refreshFeedback(); return false
        }
    }
    private func endRecording() {
        if recordingAction != nil { hotKeys.endRecording() }
        recordingAction = nil; recordingIndex = nil; recordingModifiers = nil
    }
    private func clearFailures() { failedBindings = [:]; failedReasons = [:]; rejectedInputs = [:]; persistenceFailed = false }
    private func affectedActions(_ error: ShortcutUpdateError) -> [ShortcutAction] {
        switch error {
        case .invalid(let action), .applicationReserved(let action), .systemReserved(let action), .registrationFailed(let action, _): return [action]
        case .duplicate(let first, let second): return [first, second]
        case .systemCheckFailed, .handlerFailed: return ShortcutAction.allCases
        }
    }
    private func showFailure(_ error: ShortcutUpdateError) {
        if case .duplicate = error { refreshFeedback(); return }
        for action in affectedActions(error) { for (index, key) in bindingDraft[action, default: []].enumerated() {
            guard strictCandidates.contains(key) || hotKeys.registeredBindings[action, default: []].isEmpty else { continue }
            let slot = Slot(action: action, index: index)
            failedBindings[slot] = key; failedReasons[slot] = error
        } }
        refreshFeedback()
    }
    private func refreshFeedback(notify: Bool = true) {
        let preflight = hotKeys.bindingIssues(bindingDraft)
        hasBlockingShortcutIssues = false; slotIssues = [:]; slotMessages = [:]
        for action in ShortcutAction.allCases {
            let keys = bindingDraft[action, default: []]
            if keys.count > 2 { hasBlockingShortcutIssues = true }
            for index in 0..<max(keys.count, recordingAction == action ? (recordingIndex ?? 0) + 1 : 1) {
                let slot = Slot(action: action, index: index)
                let key = keys.indices.contains(index) ? keys[index] : nil
                var issue = key.flatMap { preflight[action]?[$0] }
                if let issue {
                    switch issue {
                    case .invalid, .duplicate: hasBlockingShortcutIssues = true
                    case .applicationReserved, .systemReserved:
                        if let key, strictCandidates.contains(key) || !store.shortcutBindings[action, default: []].contains(key) { hasBlockingShortcutIssues = true }
                    case .registrationFailed, .systemCheckFailed, .handlerFailed: break
                    }
                }
                if let failure = failedReasons[slot], rejectedInputs[slot] != nil || (key != nil && failedBindings[slot] == key) { issue = failure }
                if issue == nil, let key, store.shortcutBindings[action, default: []].contains(key) {
                    issue = hotKeys.unavailableBindingReasons[action]?[key]
                }
                if let issue { slotIssues[slot] = issue }
                var message = ""
                if persistenceFailed { message = L("配置未保存，请重新选择快捷键。") }
                else if let input = rejectedInputs[slot], let failure = failedReasons[slot] {
                    let reason: String
                    if case .invalid = failure { reason = input.invalidReason ?? failure.localizedDescription }
                    else { reason = failure.localizedDescription }
                    let retained = store.shortcutBindings[action, default: []].map(\.displayString).joined(separator: " / ")
                    let status = hotKeys.registeredBindings[action, default: []] == store.shortcutBindings[action, default: []]
                        ? LF("仍使用 %@。", retained) : LF("原配置 %@ 未更改。", retained)
                    message = "\(input.displayString)：\(reason)\n\(status)"
                } else if let issue {
                    if case .invalid = issue { message = key?.invalidReason ?? issue.localizedDescription }
                    else if case .registrationFailed = issue, let key, !strictCandidates.contains(key), store.shortcutBindings[action, default: []].contains(key) {
                        message = hotKeys.registeredBindings[action, default: []].isEmpty
                            ? L("暂时不可用，已保留快捷键，可稍后重试。") : L("暂时不可用，另一组仍可使用。")
                    } else { message = issue.localizedDescription }
                } else if recordingAction == action && recordingIndex == index { message = L("按下快捷键；Esc 取消，Tab 切换。") }
                if hotKeys.cleanupFailures[action] != nil { message += (message.isEmpty ? "" : "\n") + L("快捷键释放未完成，请重新打开小贴。") }
                slotMessages[slot] = message
            }
        }
        if notify { onUpdate?() }
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
