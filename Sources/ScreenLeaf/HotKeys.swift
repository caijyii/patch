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
    private struct Registration {
        let token: HotKeyToken
        let eventID: UInt32
    }
    private struct PendingRelease {
        let token: HotKeyToken
        let actions: [ShortcutAction]
    }

    private let backend: HotKeyBackend
    private var handlerStatus: Int32 = noErr
    private var registrations: [KeyboardShortcut: Registration] = [:]
    private var callbacks: [ShortcutAction: () -> Void] = [:]
    private var eventActions: [UInt32: ShortcutAction] = [:]
    private var nextEventID: UInt32 = 100
    private var recordingHandler: ((KeyboardShortcut) -> Void)?
    private var unavailableActions: Set<ShortcutAction> = []
    private(set) var unavailableReasons: [ShortcutAction: ShortcutUpdateError] = [:]
    private var pendingRelease: [PendingRelease] = []
    private(set) var cleanupWarnings: [Int32] = []
    private(set) var cleanupFailures: [ShortcutAction: Int32] = [:]
    private(set) var registeredShortcuts: [ShortcutAction: KeyboardShortcut] = [:]

    var unavailable: [UInt32] { unavailableActions.map(\.legacyID).sorted() }
    var isRecordingShortcut: Bool { recordingHandler != nil }

    init(backend: HotKeyBackend? = nil) {
        self.backend = backend ?? CarbonHotKeyBackend()
        handlerStatus = self.backend.installHandler { [weak self] eventID in self?.handle(eventID) }
    }

    /// Compatibility for the old App delegate; new callers should install saved shortcuts.
    func register(id: UInt32, keyCode: Int, action: @escaping () -> Void) {
        guard let destination = ShortcutAction(legacyID: id), keyCode >= 0, keyCode <= Int(UInt32.max) else { return }
        let shortcut = KeyboardShortcut(keyCode: UInt32(keyCode), modifiers: [.control, .option])
        var proposed = registeredShortcuts
        proposed[destination] = shortcut
        var actions = callbacks
        actions[destination] = action
        if case .failure(let error) = applyShortcuts(proposed, actions: actions) {
            unavailableActions.insert(destination); unavailableReasons[destination] = error
        }
    }

    /// Launch each saved action independently so one unavailable key does not disable the rest.
    @discardableResult
    func installShortcuts(_ desired: [ShortcutAction: KeyboardShortcut],
                          actions: [ShortcutAction: () -> Void]) -> [ShortcutAction: ShortcutUpdateError] {
        // Keep callbacks for failed launch registrations so Settings can repair them later.
        callbacks.merge(actions) { _, new in new }
        var failures: [ShortcutAction: ShortcutUpdateError] = [:]
        for destination in ShortcutAction.allCases {
            guard let shortcut = desired[destination] else { continue }
            var proposed = registeredShortcuts
            proposed[destination] = shortcut
            var nextActions = callbacks
            nextActions[destination] = actions[destination]
            if case .failure(let error) = applyShortcuts(proposed, actions: nextActions) {
                failures[destination] = error
                unavailableActions.insert(destination)
                unavailableReasons[destination] = error
            }
        }
        return failures
    }

    /// Stage new registrations while old ones stay live. Swapped combinations reuse their refs.
    /// A registration failure never changes current callbacks, registrations or saved preferences.
    @discardableResult
    func applyShortcuts(_ proposed: [ShortcutAction: KeyboardShortcut],
                        actions: [ShortcutAction: () -> Void]? = nil) -> Result<Void, ShortcutUpdateError> {
        cleanupWarnings = []
        cleanupFailures = [:]
        retryPendingRelease()
        if handlerStatus != noErr { return .failure(.handlerFailed(handlerStatus)) }
        if let error = Self.validate(proposed) { return .failure(error) }
        let symbolic: Set<KeyboardShortcut>
        switch backend.symbolicShortcuts() {
        case .success(let shortcuts): symbolic = shortcuts
        case .failure(let error): return .failure(.systemCheckFailed(error.status))
        }
        for destination in ShortcutAction.allCases {
            if let shortcut = proposed[destination], symbolic.contains(shortcut) {
                return .failure(.systemReserved(destination))
            }
        }

        var staged: [KeyboardShortcut: Registration] = [:]
        for destination in ShortcutAction.allCases {
            guard let shortcut = proposed[destination], registrations[shortcut] == nil else { continue }
            let eventID = freshEventID()
            switch backend.register(shortcut, eventID: eventID) {
            case .success(let token): staged[shortcut] = Registration(token: token, eventID: eventID)
            case .failure(let error):
                for (shortcut, registration) in staged {
                    release(registration.token, actions: proposed.filter { $0.value == shortcut }.map(\.key))
                }
                return .failure(.registrationFailed(destination, error.status))
            }
        }

        let desiredKeys = Set(proposed.values)
        let previousBindings = registeredShortcuts
        let removed = registrations.filter { !desiredKeys.contains($0.key) }
        let retained = registrations.filter { desiredKeys.contains($0.key) }
        registrations = retained.merging(staged) { _, new in new }
        registeredShortcuts = proposed
        if let actions { callbacks.merge(actions) { _, new in new } }
        eventActions = Dictionary(uniqueKeysWithValues: proposed.compactMap { destination, shortcut in
            registrations[shortcut].map { ($0.eventID, destination) }
        })
        unavailableActions = unavailableActions.filter { proposed[$0] == nil }
        unavailableReasons = unavailableReasons.filter { proposed[$0.key] == nil }
        for (shortcut, registration) in removed {
            release(registration.token, actions: previousBindings.filter { $0.value == shortcut }.map(\.key))
        }
        return .success(())
    }

    static func validate(_ shortcuts: [ShortcutAction: KeyboardShortcut]) -> ShortcutUpdateError? {
        let issues = validationIssues(shortcuts)
        return ShortcutAction.allCases.compactMap { issues[$0] }.first
    }

    static func validationIssues(_ shortcuts: [ShortcutAction: KeyboardShortcut]) -> [ShortcutAction: ShortcutUpdateError] {
        var issues: [ShortcutAction: ShortcutUpdateError] = [:]
        var owners: [KeyboardShortcut: [ShortcutAction]] = [:]
        for action in ShortcutAction.allCases {
            guard let shortcut = shortcuts[action] else { continue }
            if !shortcut.isValid { issues[action] = .invalid(action) }
            else if shortcut.isApplicationReserved { issues[action] = .applicationReserved(action) }
            else { owners[shortcut, default: []].append(action) }
        }
        for duplicates in owners.values where duplicates.count > 1 {
            for action in duplicates {
                guard let other = duplicates.first(where: { $0 != action }) else { continue }
                let first = action.legacyID < other.legacyID ? action : other
                let second = action.legacyID < other.legacyID ? other : action
                issues[action] = .duplicate(first, second)
            }
        }
        return issues
    }

    /// Read-only preflight for row-level feedback. Registration still happens only when saved.
    func shortcutIssues(_ proposed: [ShortcutAction: KeyboardShortcut]) -> [ShortcutAction: ShortcutUpdateError] {
        var issues = Self.validationIssues(proposed)
        if handlerStatus != noErr {
            for action in proposed.keys where issues[action] == nil { issues[action] = .handlerFailed(handlerStatus) }
            return issues
        }
        switch backend.symbolicShortcuts() {
        case .success(let symbolic):
            for (action, shortcut) in proposed where issues[action] == nil && symbolic.contains(shortcut) {
                issues[action] = .systemReserved(action)
            }
        case .failure(let error):
            for action in proposed.keys where issues[action] == nil { issues[action] = .systemCheckFailed(error.status) }
        }
        return issues
    }

    func beginRecording(_ handler: @escaping (KeyboardShortcut) -> Void) { recordingHandler = handler }
    func endRecording() { recordingHandler = nil }

    private func handle(_ eventID: UInt32) {
        guard let destination = eventActions[eventID], let shortcut = registeredShortcuts[destination] else { return }
        if let recordingHandler { recordingHandler(shortcut) }
        else { callbacks[destination]?() }
    }

    private func freshEventID() -> UInt32 {
        repeat { nextEventID &+= 1 } while nextEventID == 0 || eventActions[nextEventID] != nil
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
        let previous = pendingRelease
        pendingRelease = []
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
