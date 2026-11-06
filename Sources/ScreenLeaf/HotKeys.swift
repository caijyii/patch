// SPDX-FileCopyrightText: 2026 caijyii
// SPDX-License-Identifier: MIT

import AppKit
import Carbon

struct HotKeyToken: Hashable {
    let rawValue: UInt64
}

struct HotKeyBackendError: Error, Equatable {
    let status: Int32
}

/// Tests inject a fake backend; only the production backend calls Carbon.
@MainActor
protocol HotKeyBackend: AnyObject {
    func installHandler(_ callback: @escaping (UInt32) -> Void) -> Int32
    func register(_ shortcut: KeyboardShortcut, eventID: UInt32) -> Result<HotKeyToken, HotKeyBackendError>
    func unregister(_ token: HotKeyToken) -> Int32
    func symbolicShortcuts() -> Result<Set<KeyboardShortcut>, HotKeyBackendError>
}

enum ShortcutUpdateError: Error, Equatable, LocalizedError {
    case invalid(ShortcutAction)
    case applicationReserved(ShortcutAction)
    case duplicate(ShortcutAction, ShortcutAction)
    case systemReserved(ShortcutAction)
    case systemCheckFailed(Int32)
    case handlerFailed(Int32)
    case registrationFailed(ShortcutAction, Int32)

    var errorDescription: String? {
        switch self {
        case .invalid(let action): return LF("%@：请使用有效的组合；Shift 可配合功能键或方向键。", action.title)
        case .applicationReserved(let action): return LF("%@的组合已被小贴的编辑或窗口操作保留，请换一个组合。", action.title)
        case .duplicate(let first, let second): return LF("%@与%@使用了相同快捷键。", first.title, second.title)
        case .systemReserved(let action): return LF("%@的快捷键已被系统使用，请换一个组合。", action.title)
        case .systemCheckFailed: return L("暂时无法检查系统快捷键，请稍后重试。")
        case .handlerFailed: return L("无法启用快捷键，请重新打开小贴。")
        case .registrationFailed(let action, _):
            return LF("%@的快捷键不可用，请换一个组合；原配置保留。", action.title)
        }
    }
}

@MainActor
final class HotKeys {
    private struct Registration { let token: HotKeyToken; let eventID: UInt32 }
    private struct PendingRelease { let token: HotKeyToken; let actions: [ShortcutAction] }
    private let backend: HotKeyBackend
    private var handlerStatus: Int32 = noErr
    private var registrations: [KeyboardShortcut: Registration] = [:]
    private var callbacks: [ShortcutAction: () -> Void] = [:]
    private var eventBindings: [UInt32: (ShortcutAction, KeyboardShortcut)] = [:]
    private var nextEventID: UInt32 = 100
    private var recordingHandler: ((KeyboardShortcut) -> Void)?
    private var pendingRelease: [PendingRelease] = []
    private(set) var cleanupWarnings: [Int32] = []
    private(set) var cleanupFailures: [ShortcutAction: Int32] = [:]
    private(set) var registeredBindings: [ShortcutAction: [KeyboardShortcut]] = [:]
    private(set) var configuredBindings: [ShortcutAction: [KeyboardShortcut]] = [:]
    private(set) var unavailableBindingReasons: [ShortcutAction: [KeyboardShortcut: ShortcutUpdateError]] = [:]
    var registeredShortcuts: [ShortcutAction: KeyboardShortcut] { registeredBindings.compactMapValues(\.first) }
    var unavailableReasons: [ShortcutAction: ShortcutUpdateError] {
        unavailableBindingReasons.compactMapValues { $0.values.first }
    }
    /// An action remains available if either registered chord works.
    var unavailable: [UInt32] {
        unavailableBindingReasons.keys.filter { registeredBindings[$0, default: []].isEmpty }.map(\.legacyID).sorted()
    }
    var isRecordingShortcut: Bool { recordingHandler != nil }
    init(backend: HotKeyBackend? = nil) {
        self.backend = backend ?? CarbonHotKeyBackend()
        handlerStatus = self.backend.installHandler { [weak self] eventID in self?.handle(eventID) }
    }
    func register(id: UInt32, keyCode: Int, action: @escaping () -> Void) {
        guard let destination = ShortcutAction(legacyID: id), keyCode >= 0, keyCode <= Int(UInt32.max) else { return }
        let shortcut = KeyboardShortcut(keyCode: UInt32(keyCode), modifiers: [.control, .option])
        var proposed = registeredBindings; proposed[destination] = [shortcut]
        var actions = callbacks; actions[destination] = action
        if case .failure(let error) = applyBindings(proposed, actions: actions) {
            unavailableBindingReasons[destination, default: [:]][shortcut] = error
        }
    }
    @discardableResult
    func installShortcuts(_ desired: [ShortcutAction: KeyboardShortcut], actions: [ShortcutAction: () -> Void]) -> [ShortcutAction: ShortcutUpdateError] {
        installBindings(desired.mapValues { [$0] }, actions: actions).compactMapValues { $0.values.first }
    }
    /// Startup is independent per chord, including two chords for one action.
    @discardableResult
    func installBindings(_ desired: [ShortcutAction: [KeyboardShortcut]], actions: [ShortcutAction: () -> Void]) -> [ShortcutAction: [KeyboardShortcut: ShortcutUpdateError]] {
        callbacks.merge(actions) { _, new in new }
        var failures: [ShortcutAction: [KeyboardShortcut: ShortcutUpdateError]] = [:]
        for action in ShortcutAction.allCases {
            for shortcut in desired[action, default: []] {
                var proposed = registeredBindings
                proposed[action, default: []].append(shortcut)
                if case .failure(let error) = applyBindings(proposed) { failures[action, default: [:]][shortcut] = error }
            }
        }
        configuredBindings = desired
        unavailableBindingReasons = failures
        return failures
    }
    @discardableResult
    func applyShortcuts(_ proposed: [ShortcutAction: KeyboardShortcut], actions: [ShortcutAction: () -> Void]? = nil) -> Result<Void, ShortcutUpdateError> {
        applyBindings(proposed.mapValues { [$0] }, actions: actions)
    }
    /// Newly edited chords stage atomically. Existing unavailable saved chords
    /// may be tolerated without dropping another working chord or losing their configuration.
    @discardableResult
    func applyBindings(_ proposed: [ShortcutAction: [KeyboardShortcut]], actions: [ShortcutAction: () -> Void]? = nil,
                       allowingUnavailable: Set<KeyboardShortcut> = []) -> Result<Void, ShortcutUpdateError> {
        cleanupWarnings = []; cleanupFailures = [:]; retryPendingRelease()
        if handlerStatus != noErr { return .failure(.handlerFailed(handlerStatus)) }
        let local = Self.validationBindingIssues(proposed)
        for action in ShortcutAction.allCases {
            if proposed[action, default: []].count > 2 { return .failure(.invalid(action)) }
            for key in proposed[action, default: []] {
                if let error = local[action]?[key] {
                    if case .applicationReserved = error, allowingUnavailable.contains(key) { continue }
                    return .failure(error)
                }
            }
        }
        let symbolic: Set<KeyboardShortcut>
        switch backend.symbolicShortcuts() {
        case .success(let shortcuts): symbolic = shortcuts
        case .failure(let error): return .failure(.systemCheckFailed(error.status))
        }
        var failures: [ShortcutAction: [KeyboardShortcut: ShortcutUpdateError]] = [:]
        var staged: [KeyboardShortcut: Registration] = [:]
        func rollback() {
            for (key, entry) in staged { release(entry.token, actions: proposed.filter { $0.value.contains(key) }.map(\.key)) }
        }
        for action in ShortcutAction.allCases {
            for key in proposed[action, default: []] {
                var failure = local[action]?[key]
                if failure == nil, symbolic.contains(key) { failure = .systemReserved(action) }
                if failure == nil, registrations[key] == nil, allowingUnavailable.contains(key) {
                    // An unrelated save must not retry a saved unavailable chord.
                    // Explicit repair and retryUnavailableBindings use the strict path.
                    failure = unavailableBindingReasons[action]?[key] ?? .registrationFailed(action, Int32(eventNotHandledErr))
                }
                if failure == nil, registrations[key] == nil {
                    let id = freshEventID()
                    switch backend.register(key, eventID: id) {
                    case .success(let token): staged[key] = Registration(token: token, eventID: id)
                    case .failure(let error): failure = .registrationFailed(action, error.status)
                    }
                }
                if let failure {
                    guard allowingUnavailable.contains(key) else { rollback(); return .failure(failure) }
                    failures[action, default: [:]][key] = failure
                }
            }
        }
        let desiredKeys = Set(proposed.flatMap { action, keys in keys.filter { failures[action]?[$0] == nil } })
        let previous = registeredBindings
        let removed = registrations.filter { !desiredKeys.contains($0.key) }
        registrations = registrations.filter { desiredKeys.contains($0.key) }.merging(staged) { _, new in new }
        registeredBindings = proposed.mapValues { $0.filter { registrations[$0] != nil } }
        configuredBindings = proposed
        unavailableBindingReasons = failures
        if let actions { callbacks.merge(actions) { _, new in new } }
        eventBindings = [:]
        for (action, keys) in registeredBindings { for key in keys {
            if let entry = registrations[key] { eventBindings[entry.eventID] = (action, key) }
        } }
        for (key, entry) in removed { release(entry.token, actions: previous.filter { $0.value.contains(key) }.map(\.key)) }
        return .success(())
    }
    /// Only unavailable chords are re-registered; healthy references are retained.
    func retryUnavailableBindings() {
        guard !isRecordingShortcut, !unavailableBindingReasons.isEmpty else { return }
        // Retry one pending chord at a time so an old migrated duplicate cannot
        // prevent unrelated pending chords from recovering.
        var failures = unavailableBindingReasons
        let desired = configuredBindings
        for action in ShortcutAction.allCases {
            for key in desired[action, default: []] where failures[action]?[key] != nil {
                var proposed = registeredBindings
                proposed[action, default: []].append(key)
                switch applyBindings(proposed) {
                case .success: failures[action]?.removeValue(forKey: key)
                case .failure(let error): failures[action, default: [:]][key] = error
                }
            }
        }
        configuredBindings = desired
        let active = registeredBindings
        // Keep configured slot order without assigning a migrated duplicate to
        // an action that never acquired that chord.
        registeredBindings = [:]
        for (action, keys) in desired {
            registeredBindings[action] = keys.filter { active[action, default: []].contains($0) }
        }
        unavailableBindingReasons = failures.filter { !$0.value.isEmpty }
    }
    static func validate(_ shortcuts: [ShortcutAction: KeyboardShortcut]) -> ShortcutUpdateError? {
        let issues = validationIssues(shortcuts)
        return ShortcutAction.allCases.compactMap { issues[$0] }.first
    }
    static func validationIssues(_ shortcuts: [ShortcutAction: KeyboardShortcut]) -> [ShortcutAction: ShortcutUpdateError] {
        validationBindingIssues(shortcuts.mapValues { [$0] }).compactMapValues { $0.values.first }
    }
    static func validationBindingIssues(_ bindings: [ShortcutAction: [KeyboardShortcut]]) -> [ShortcutAction: [KeyboardShortcut: ShortcutUpdateError]] {
        var issues: [ShortcutAction: [KeyboardShortcut: ShortcutUpdateError]] = [:]
        var owners: [KeyboardShortcut: [ShortcutAction]] = [:]
        for action in ShortcutAction.allCases { for key in bindings[action, default: []] {
            if !key.isValid || bindings[action, default: []].count > 2 { issues[action, default: [:]][key] = .invalid(action) }
            else if key.isApplicationReserved { issues[action, default: [:]][key] = .applicationReserved(action) }
            owners[key, default: []].append(action)
        } }
        for (key, duplicates) in owners where duplicates.count > 1 {
            for action in duplicates {
                let other = duplicates.first(where: { $0 != action }) ?? action
                let first = action.legacyID < other.legacyID ? action : other
                let second = action.legacyID < other.legacyID ? other : action
                issues[action, default: [:]][key] = .duplicate(first, second)
            }
        }
        return issues
    }
    func bindingIssues(_ proposed: [ShortcutAction: [KeyboardShortcut]]) -> [ShortcutAction: [KeyboardShortcut: ShortcutUpdateError]] {
        var issues = Self.validationBindingIssues(proposed)
        let global: ShortcutUpdateError?
        var symbolic = Set<KeyboardShortcut>()
        if handlerStatus != noErr { global = .handlerFailed(handlerStatus) }
        else {
            switch backend.symbolicShortcuts() {
            case .success(let keys): symbolic = keys; global = nil
            case .failure(let error): global = .systemCheckFailed(error.status)
            }
        }
        for (action, keys) in proposed { for key in keys where issues[action]?[key] == nil {
            if let global { issues[action, default: [:]][key] = global }
            else if symbolic.contains(key) { issues[action, default: [:]][key] = .systemReserved(action) }
        } }
        return issues
    }
    func shortcutIssues(_ proposed: [ShortcutAction: KeyboardShortcut]) -> [ShortcutAction: ShortcutUpdateError] {
        bindingIssues(proposed.mapValues { [$0] }).compactMapValues { $0.values.first }
    }
    func beginRecording(_ handler: @escaping (KeyboardShortcut) -> Void) { recordingHandler = handler }
    func endRecording() { recordingHandler = nil }
    private func handle(_ eventID: UInt32) {
        guard let (action, shortcut) = eventBindings[eventID] else { return }
        if let recordingHandler { recordingHandler(shortcut) } else { callbacks[action]?() }
    }
    private func freshEventID() -> UInt32 {
        repeat { nextEventID &+= 1 } while nextEventID == 0 || eventBindings[nextEventID] != nil
        return nextEventID
    }
    private func release(_ token: HotKeyToken, actions: [ShortcutAction]) {
        let result = backend.unregister(token)
        if result != noErr {
            cleanupWarnings.append(result)
            for action in actions { cleanupFailures[action] = result }
            pendingRelease.append(PendingRelease(token: token, actions: actions))
        }
    }
    private func retryPendingRelease() {
        let previous = pendingRelease; pendingRelease = []
        previous.forEach { release($0.token, actions: $0.actions) }
    }
}

extension KeyboardShortcut {
    init(event: NSEvent) {
        var modifiers: ShortcutModifiers = []
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        self.init(keyCode: UInt32(event.keyCode), modifiers: modifiers)
    }

    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        var modifiers: ShortcutModifiers = []
        if carbonModifiers & UInt32(cmdKey) != 0 { modifiers.insert(.command) }
        if carbonModifiers & UInt32(controlKey) != 0 { modifiers.insert(.control) }
        if carbonModifiers & UInt32(optionKey) != 0 { modifiers.insert(.option) }
        if carbonModifiers & UInt32(shiftKey) != 0 { modifiers.insert(.shift) }
        self.init(keyCode: keyCode, modifiers: modifiers)
    }
}

@MainActor
private final class CarbonHotKeyBackend: HotKeyBackend {
    private static let signature: OSType = 0x534C4546
    private var handler: EventHandlerRef?
    private var callback: ((UInt32) -> Void)?
    private var references: [HotKeyToken: EventHotKeyRef] = [:]
    private var nextToken: UInt64 = 0

    func installHandler(_ callback: @escaping (UInt32) -> Void) -> Int32 {
        self.callback = callback
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        return InstallEventHandler(GetApplicationEventTarget(), { _, event, pointer in
            guard let event, let pointer else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard status == noErr, identifier.signature == 0x534C4546 else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<CarbonHotKeyBackend>.fromOpaque(pointer).takeUnretainedValue()
            MainActor.assumeIsolated { owner.callback?(identifier.id) }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func register(_ shortcut: KeyboardShortcut, eventID: UInt32) -> Result<HotKeyToken, HotKeyBackendError> {
        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: Self.signature, id: eventID)
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, identifier,
                                        GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference)
        guard status == noErr, let reference else {
            return .failure(HotKeyBackendError(status: status == noErr ? Int32(paramErr) : status))
        }
        nextToken &+= 1
        let token = HotKeyToken(rawValue: nextToken)
        references[token] = reference
        return .success(token)
    }

    func unregister(_ token: HotKeyToken) -> Int32 {
        guard let reference = references[token] else { return Int32(paramErr) }
        let status = UnregisterEventHotKey(reference)
        if status == noErr { references.removeValue(forKey: token) }
        return status
    }

    func symbolicShortcuts() -> Result<Set<KeyboardShortcut>, HotKeyBackendError> {
        var copied: Unmanaged<CFArray>?
        let status = CopySymbolicHotKeys(&copied)
        guard status == noErr, let array = copied?.takeRetainedValue() as? [[String: Any]] else {
            return .failure(HotKeyBackendError(status: status == noErr ? Int32(paramErr) : status))
        }
        var shortcuts = Set<KeyboardShortcut>()
        for item in array {
            guard (item[kHISymbolicHotKeyEnabled as String] as? NSNumber)?.boolValue == true,
                  let code = item[kHISymbolicHotKeyCode as String] as? NSNumber,
                  let modifiers = item[kHISymbolicHotKeyModifiers as String] as? NSNumber else { continue }
            shortcuts.insert(KeyboardShortcut(keyCode: code.uint32Value, carbonModifiers: modifiers.uint32Value))
        }
        return .success(shortcuts)
    }

    deinit {
        references.values.forEach { UnregisterEventHotKey($0) }
        if let handler { RemoveEventHandler(handler) }
    }
}
