import AppKit
import Carbon
import Foundation

private struct VerificationError: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw VerificationError(description: message) }
}

@MainActor
private final class FakeHotKeyBackend: HotKeyBackend {
    var callback: ((UInt32) -> Void)?
    var installStatus: Int32 = noErr
    var symbolicStatus: Int32 = noErr
    var symbolic = Set<KeyboardShortcut>()
    var blocked = Set<KeyboardShortcut>()
    var registrations: [HotKeyToken: (shortcut: KeyboardShortcut, eventID: UInt32)] = [:]
    var attempts: [KeyboardShortcut] = []
    var released: [HotKeyToken] = []
    var releaseStatus: Int32 = noErr
    private var nextToken: UInt64 = 0

    func installHandler(_ callback: @escaping (UInt32) -> Void) -> Int32 {
        self.callback = callback
        return installStatus
    }
    func register(_ shortcut: KeyboardShortcut, eventID: UInt32) -> Result<HotKeyToken, HotKeyBackendError> {
        attempts.append(shortcut)
        if blocked.contains(shortcut) || registrations.values.contains(where: { $0.shortcut == shortcut }) {
            return .failure(HotKeyBackendError(status: Int32(eventHotKeyExistsErr)))
        }
        nextToken += 1
        let token = HotKeyToken(rawValue: nextToken)
        registrations[token] = (shortcut, eventID)
        return .success(token)
    }
    func unregister(_ token: HotKeyToken) -> Int32 {
        if releaseStatus != noErr { return releaseStatus }
        guard registrations.removeValue(forKey: token) != nil else { return Int32(paramErr) }
        released.append(token)
        return noErr
    }
    func symbolicShortcuts() -> Result<Set<KeyboardShortcut>, HotKeyBackendError> {
        symbolicStatus == noErr ? .success(symbolic) : .failure(HotKeyBackendError(status: symbolicStatus))
    }
    func emit(_ shortcut: KeyboardShortcut) {
        if let entry = registrations.values.first(where: { $0.shortcut == shortcut }) { callback?(entry.eventID) }
    }
}

@MainActor
private final class RecorderFocusSink: NSView {
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {}
}

@main
private struct PreferencesVerification {
    @MainActor static func main() {
        let modelOnly = CommandLine.arguments.contains("--model-only")
        if !modelOnly {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
        }
        let modelChecks: [(String, () throws -> Void)] = [
            ("per-tool settings persist in injected memory storage without cross-tool inheritance", preferences),
            ("invalid and future preferences fall back without rewriting storage", invalidPreferences),
            ("shortcut serialization and accepted modifiers are validated", shortcutModel),
            ("five-action preferences gain the subject default without replacing custom keys", legacyShortcuts),
            ("release failures are tracked and retried without dispatching obsolete callbacks", releaseRetry)
        ]
        let checks: [(String, () throws -> Void)] = [
            ("Shift-function/navigation keys work without allowing Shift typing shortcuts", shiftShortcuts),
            ("transactional shortcut replacement and key swaps preserve action routing", transactions),
            ("failed registration rolls back all staged registrations and preserves old keys", rollback),
            ("duplicate, system-reserved and backend errors leave old keys live", conflicts),
            ("application commands cannot become global shortcuts and saved conflicts remain visible", applicationPolicy),
            ("launch registration failure leaves other keys usable and can be repaired", launchRepair),
            ("shortcut recording receives registered combinations without invoking actions", recording),
            ("Control-C routes through the native recorder first responder", nativeControlC),
            ("settings recorder saves through transaction and keeps failed drafts unpersisted", settings),
            ("settings feedback is local to affected rows and successful saves close the window", rowFeedback),
            ("failed duplicate save clears both row errors after completing a key swap", resolvedDuplicateSwap),
            ("batch edits isolate unavailable launch keys and clear committed or cancelled edit intent", batchPartialLaunch),
            ("batch same-value repairs retain failed edit intent and default restoration remains complete", batchSameValueRepair),
            ("batch swaps preserve routing beside unavailable keys and reject duplicates of saved inactive keys", batchPartialSwap),
            ("immediate recording registers, persists and retries failures without Save", immediateCommitAndRetry),
            ("immediate invalid, duplicate, application and system conflicts preserve active keys", immediateConflicts),
            ("a failed immediate candidate does not block another shortcut edit", immediateFailureIsolation),
            ("immediate edits preserve unrelated launch failures and can repair them", immediatePartialLaunch),
            ("immediate cleanup warnings retain the successful binding and retry safely", immediateCleanup),
            ("immediate default restoration commits or rolls back the complete configuration", immediateDefaults),
            ("recording an already registered Control-C chord is handled through its hotkey callback", registeredControlC),
            ("backend and cleanup failures are explained in rows without status codes", rowBackendFailures),
            ("failed staged cleanup stays local and is retried while old bindings remain usable", rollbackCleanup),
            ("settings preview and visible row bounds fit the native window", settingsPreview)
        ]
        var failed = 0
        let selectedChecks = modelChecks + (modelOnly ? [] : checks)
        for (title, check) in selectedChecks {
            do { try check(); print("PASS: \(title)") }
            catch { failed += 1; print("FAIL: \(title): \(error)") }
        }
        if failed != 0 { exit(1) }
        print("PASS: \(selectedChecks.count) preference and hotkey checks; fake backend only, no UserDefaults or system input")
    }

    @MainActor private static func preferences() throws {
        let memory = MemoryPreferencesStorage()
        let first = PreferencesStore(storage: memory)
        try require(first.annotation(for: "箭头") == AnnotationPreference(), "Unexpected new-store defaults")
        var arrow = first.annotation(for: "箭头")
        arrow.colorID = 3; arrow.width = 8
        first.setAnnotation(arrow, for: "箭头")
        var text = first.annotation(for: "文字")
        text.fontSize = 32
        first.setAnnotation(text, for: "文字")
        let writes = memory.writeCount
        let restarted = PreferencesStore(storage: memory)
        try require(restarted.annotation(for: "箭头") == arrow, "Arrow settings were lost after store reconstruction")
        try require(restarted.annotation(for: "文字") == text, "Text settings were lost after store reconstruction")
        try require(restarted.annotation(for: "圆形") == AnnotationPreference(), "Unconfigured tool inherited another tool")
        try require(memory.writeCount == writes, "Reading settings rewrote them")
        restarted.setAnnotation(arrow, for: "箭头")
        try require(memory.writeCount == writes, "Unchanged setting produced a redundant write")
        var corrected = restarted.annotation(for: "箭头")
        corrected.width = 1.5
        restarted.setAnnotation(corrected, for: "箭头")
        try require(restarted.annotation(for: "箭头").colorID == 3, "Changing one field discarded previous chosen color")
    }

    @MainActor private static func invalidPreferences() throws {
        let future = MemoryPreferencesStorage(data: Data("{\"version\":99,\"annotations\":{},\"shortcuts\":{}}".utf8))
        let futureStore = PreferencesStore(storage: future)
        try require(futureStore.shortcuts == ShortcutAction.defaultShortcuts && future.writeCount == 0,
                    "Future snapshot changed defaults or wrote during reading")
        let bad = MemoryPreferencesStorage(data: Data("invalid".utf8))
        let badStore = PreferencesStore(storage: bad)
        try require(badStore.annotation(for: "文字") == AnnotationPreference() && bad.writeCount == 0,
                    "Broken snapshot was not handled safely")
        var invalid = AnnotationPreference()
        invalid.colorID = 100; invalid.width = .infinity; invalid.fontSize = -2
        invalid.numberSize = .nan; invalid.mosaicBlockSize = 0
        badStore.setAnnotation(invalid, for: "文字")
        try require(badStore.annotation(for: "文字") == AnnotationPreference(), "Invalid numeric settings did not normalize")
    }

    @MainActor private static func shortcutModel() throws {
        try require(ShortcutAction.displayOrder == [.screenshot, .scroll, .subject, .record, .text, .pin]
                    && Set(ShortcutAction.settingsOrder) == Set(ShortcutAction.allCases)
                    && ShortcutAction.settingsOrder.count == ShortcutAction.allCases.count,
                    "Feature display order is incorrect or omits/duplicates an action")
        let memory = MemoryPreferencesStorage()
        let store = PreferencesStore(storage: memory)
        var chosen = ShortcutAction.defaultShortcuts
        chosen[.screenshot] = KeyboardShortcut(keyCode: 122, modifiers: [.command, .shift])
        chosen[.subject] = KeyboardShortcut(keyCode: 28, modifiers: [.option])
        try require(store.setShortcuts(chosen), "Valid shortcuts could not be persisted")
        try require(PreferencesStore(storage: memory).shortcuts == chosen, "Shortcuts did not survive reconstruction")
        let writes = memory.writeCount
        chosen[.scroll] = chosen[.screenshot]
        try require(!store.setShortcuts(chosen) && memory.writeCount == writes, "Duplicate shortcuts were persisted")
        for modifiers: ShortcutModifiers in [[], [.shift], ShortcutModifiers(rawValue: 32)] {
            try require(!KeyboardShortcut(keyCode: 0, modifiers: modifiers).isValid, "Unsafe modifiers accepted")
        }
        for code: UInt32 in [53, 48, 51, 117, 55, 999] {
            try require(!KeyboardShortcut(keyCode: code, modifiers: [.command]).isValid, "Reserved recorder key accepted")
        }
        let sample = KeyboardShortcut(keyCode: 122, modifiers: [.command, .shift])
        try require(sample.displayString == "⇧⌘F1", "Shortcut label does not describe saved keys")
        try require(KeyboardShortcut(keyCode: sample.keyCode, carbonModifiers: sample.carbonModifiers) == sample,
                    "Modifier conversion did not round trip")
    }

    @MainActor private static func legacyShortcuts() throws {
        let previousActions: [ShortcutAction] = [.screenshot, .scroll, .text, .pin, .record]
        try require(ShortcutAction.allCases == previousActions + [.subject, .togglePins], "The new action changed legacy launch priority")
        try require(previousActions.map(\.legacyID) == [1, 2, 3, 4, 5]
                    && previousActions.map { $0.defaultShortcut.keyCode } == [18, 19, 20, 21, 23]
                    && ShortcutAction.subject.legacyID == 6
                    && ShortcutAction.subject.defaultShortcut == KeyboardShortcut(keyCode: 22, modifiers: [.option]),
                    "Existing action IDs/defaults or the subject default changed")

        struct SavedSnapshot: Encodable {
            let version = 1
            let annotations: [String: AnnotationPreference] = [:]
            let shortcuts: [String: KeyboardShortcut]
        }
        func storage(_ shortcuts: [ShortcutAction: KeyboardShortcut]) throws -> MemoryPreferencesStorage {
            let saved = Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.key.rawValue, $0.value) })
            return MemoryPreferencesStorage(data: try JSONEncoder().encode(SavedSnapshot(shortcuts: saved)))
        }
        let oldSix = Dictionary(uniqueKeysWithValues: ShortcutAction.displayOrder.map {
            ($0, KeyboardShortcut(keyCode: $0.defaultShortcut.keyCode, modifiers: [.control, .option]))
        })
        let oldSixMemory = try storage(oldSix)
        let upgraded = PreferencesStore(storage: oldSixMemory).shortcuts
        try require(oldSix.allSatisfy { upgraded[$0.key] == $0.value }
                    && upgraded[.togglePins] == ShortcutAction.togglePins.defaultShortcut && oldSixMemory.writeCount == 0,
                    "Adding the seventh action replaced existing Control-Option bindings")
        var previous = ShortcutAction.defaultShortcuts.filter { $0.key != .subject && $0.key != .togglePins }
        previous[.screenshot] = KeyboardShortcut(keyCode: 25, modifiers: [.option])
        previous[.pin] = KeyboardShortcut(keyCode: 122, modifiers: [.shift])
        let memory = try storage(previous)
        let store = PreferencesStore(storage: memory)
        let loaded = store.shortcuts
        try require(previous.allSatisfy { loaded[$0.key] == $0.value }
                    && loaded[.subject] == ShortcutAction.subject.defaultShortcut && memory.writeCount == 0,
                    "Loading an old snapshot replaced custom keys or wrote during migration")

        var colliding = previous
        colliding[.screenshot] = ShortcutAction.subject.defaultShortcut
        let conflictMemory = try storage(colliding)
        let conflictStore = PreferencesStore(storage: conflictMemory)
        let desired = conflictStore.shortcuts
        try require(colliding.allSatisfy { desired[$0.key] == $0.value }
                    && desired[.subject] == desired[.screenshot] && conflictMemory.writeCount == 0,
                    "The subject default replaced an existing custom binding")
        let backend = FakeHotKeyBackend()
        let keys = HotKeys(backend: backend)
        var fired: [ShortcutAction] = []
        let actions = Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { action in
            (action, { fired.append(action) })
        })
        let failures = keys.installShortcuts(desired, actions: actions)
        try require(failures == [.subject: .duplicate(.screenshot, .subject)] && keys.unavailable == [6]
                    && keys.registeredShortcuts == desired.filter { $0.key != .subject } && backend.registrations.count == previousActions.count + 1,
                    "A migrated default conflict disabled or rebound an old shortcut")
        backend.emit(ShortcutAction.subject.defaultShortcut)
        try require(fired == [.screenshot], "The migrated conflict stole the old action callback")
        try require(!conflictStore.setShortcuts(desired) && conflictMemory.writeCount == 0,
                    "A migrated duplicate was persisted without repair")
        var repaired = desired
        repaired[.subject] = KeyboardShortcut(keyCode: 28, modifiers: [.option])
        try keys.applyShortcuts(repaired).get()
        try require(conflictStore.setShortcuts(repaired) && conflictMemory.writeCount == 1
                    && PreferencesStore(storage: conflictMemory).shortcuts == repaired
                    && keys.unavailable.isEmpty && keys.registeredShortcuts[.screenshot] == colliding[.screenshot],
                    "Repairing the subject key did not preserve and save the existing bindings")
        backend.emit(repaired[.subject]!)
        try require(fired == [.screenshot, .subject], "The repaired subject key lost its action callback")

        var missing = previous; missing.removeValue(forKey: .record)
        var invalid = previous; invalid[.pin] = KeyboardShortcut(keyCode: 999, modifiers: [.control])
        var duplicate = previous; duplicate[.scroll] = duplicate[.screenshot]
        var duplicateCurrent = loaded; duplicateCurrent[.subject] = duplicateCurrent[.screenshot]
        for broken in [missing, invalid, duplicate, duplicateCurrent] {
            let brokenMemory = try storage(broken)
            try require(PreferencesStore(storage: brokenMemory).shortcuts == ShortcutAction.defaultShortcuts
                        && brokenMemory.writeCount == 0,
                        "The subject migration accepted another malformed shortcut configuration")
        }
    }

    @MainActor private static func installed() throws -> (HotKeys, FakeHotKeyBackend, () -> [ShortcutAction]) {
        let backend = FakeHotKeyBackend()
        let keys = HotKeys(backend: backend)
        var fired: [ShortcutAction] = []
        let actions = Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { action in
            (action, { fired.append(action) })
        })
        try keys.applyShortcuts(ShortcutAction.defaultShortcuts, actions: actions).get()
        return (keys, backend, { fired })
    }

    @MainActor private static func transactions() throws {
        let (keys, backend, fired) = try installed()
        let defaults = ShortcutAction.defaultShortcuts
        try require(backend.registrations.count == ShortcutAction.allCases.count, "Initial registration was incomplete")
        backend.emit(defaults[.screenshot]!)
        try require(fired() == [.screenshot], "Initial action routing failed")
        let calls = backend.attempts.count
        var swapped = defaults
        swapped[.screenshot] = defaults[.scroll]
        swapped[.scroll] = defaults[.screenshot]
        try keys.applyShortcuts(swapped).get()
        try require(backend.attempts.count == calls && backend.released.isEmpty, "Swap re-registered owned combinations")
        backend.emit(defaults[.screenshot]!)
        try require(fired() == [.screenshot, .scroll], "Reused key did not route to its new action")
        let fresh = KeyboardShortcut(keyCode: 122, modifiers: [.option])
        swapped[.screenshot] = fresh
        try keys.applyShortcuts(swapped).get()
        try require(backend.registrations.count == ShortcutAction.allCases.count && backend.released.count == 1, "Replacement leaked old registrations")
        backend.emit(fresh)
        try require(fired().last == .screenshot, "New combination did not route to the intended action")
    }

    @MainActor private static func shiftShortcuts() throws {
        for code in KeyboardShortcut.shiftOnlyKeyCodes {
            try require(KeyboardShortcut(keyCode: code, modifiers: [.shift]).isValid, "Shift-only non-character key was rejected")
        }
        for code: UInt32 in [0, 8, 18, 25, 43, 49, 83] {
            let shortcut = KeyboardShortcut(keyCode: code, modifiers: [.shift])
            try require(!shortcut.isValid && shortcut.invalidReason?.contains("日常输入") == true,
                        "Shift character shortcut was accepted or has no input-conflict explanation")
        }
        let (keys, backend, fired) = try installed()
        var chosen = ShortcutAction.defaultShortcuts
        let shiftF1 = KeyboardShortcut(keyCode: 122, modifiers: [.shift])
        chosen[.screenshot] = shiftF1
        try keys.applyShortcuts(chosen).get()
        backend.emit(shiftF1)
        try require(fired() == [.screenshot], "Shift-F1 did not route to screenshot")
        let memory = MemoryPreferencesStorage()
        let store = PreferencesStore(storage: memory)
        try require(store.setShortcuts(chosen) && PreferencesStore(storage: memory).shortcuts[.screenshot] == shiftF1,
                    "Shift-F1 did not persist")
        try require(KeyboardShortcut(keyCode: 8, modifiers: [.control]).isValid
                    && !KeyboardShortcut(keyCode: 8, modifiers: [.control]).isApplicationReserved,
                    "Control-C is incorrectly treated as Command-C")
    }

    @MainActor private static func rollback() throws {
        let (keys, backend, fired) = try installed()
        let original = keys.registeredShortcuts
        let originalRefs = backend.registrations
        var proposed = original
        let staged = KeyboardShortcut(keyCode: 0, modifiers: [.command, .option])
        let occupied = KeyboardShortcut(keyCode: 2, modifiers: [.command, .option])
        proposed[.screenshot] = staged; proposed[.scroll] = occupied
        backend.blocked.insert(occupied)
        let result = keys.applyShortcuts(proposed)
        if case .success = result { throw VerificationError(description: "Occupied combination succeeded") }
        try require(keys.registeredShortcuts == original, "Failed transaction changed the active configuration")
        try require(backend.registrations.count == originalRefs.count && backend.released.count == 1,
                    "Failed transaction retained staged refs or removed old refs")
        for action in ShortcutAction.allCases { backend.emit(original[action]!) }
        try require(fired() == ShortcutAction.allCases, "Failed transaction damaged old callbacks")
        backend.emit(staged)
        try require(fired().count == ShortcutAction.allCases.count, "Rolled-back staged combination still dispatches")
    }

    @MainActor private static func conflicts() throws {
        let (keys, backend, fired) = try installed()
        let original = keys.registeredShortcuts
        let calls = backend.attempts.count
        var duplicate = original; duplicate[.scroll] = duplicate[.screenshot]
        try require(HotKeys.validate(duplicate) == .duplicate(.screenshot, .scroll), "App duplicates were not identified")
        if case .success = keys.applyShortcuts(duplicate) { throw VerificationError(description: "Duplicate application succeeded") }
        backend.symbolic.insert(KeyboardShortcut(keyCode: 11, modifiers: [.command]))
        var reserved = original; reserved[.text] = backend.symbolic.first!
        if case .failure(.systemReserved(.text)) = keys.applyShortcuts(reserved) {} else {
            throw VerificationError(description: "Enabled system shortcut was not rejected")
        }
        backend.symbolicStatus = -108
        if case .failure(.systemCheckFailed(-108)) = keys.applyShortcuts(original) {} else {
            throw VerificationError(description: "System enumeration failure was ignored")
        }
        try require(backend.attempts.count == calls && keys.registeredShortcuts == original,
                    "Validation failures modified registrations")
        backend.emit(original[.pin]!)
        try require(fired().last == .pin, "Validation failure stopped a valid old action")
        let broken = FakeHotKeyBackend(); broken.installStatus = -50
        let unavailable = HotKeys(backend: broken)
        if case .failure(.handlerFailed(-50)) = unavailable.applyShortcuts(original) {} else {
            throw VerificationError(description: "Handler installation failure was ignored")
        }
        try require(broken.attempts.isEmpty, "Registered keys without a working handler")
    }

    @MainActor private static func launchRepair() throws {
        let backend = FakeHotKeyBackend()
        let keys = HotKeys(backend: backend)
        var fired = 0
        backend.blocked.insert(ShortcutAction.scroll.defaultShortcut)
        let failures = keys.installShortcuts(ShortcutAction.defaultShortcuts, actions: [.scroll: { fired += 1 }])
        try require(failures.keys.contains(.scroll) && keys.unavailable == [2] && backend.registrations.count == ShortcutAction.allCases.count - 1,
                    "One occupied launch shortcut disabled unrelated actions")
        var fixed = ShortcutAction.defaultShortcuts
        let replacement = KeyboardShortcut(keyCode: 122, modifiers: [.command, .option])
        fixed[.scroll] = replacement
        try keys.applyShortcuts(fixed).get()
        backend.emit(replacement)
        try require(fired == 1 && keys.unavailable.isEmpty, "Repaired launch action lost its callback or unavailable state")
    }

    @MainActor private static func applicationPolicy() throws {
        let (keys, backend, fired) = try installed()
        let original = keys.registeredShortcuts
        let attempts = backend.attempts.count
        for code: UInt32 in [8, 1, 6, 7, 9, 0, 12, 43, 13, 46, 4] {
            let reserved = KeyboardShortcut(keyCode: code, modifiers: [.command])
            try require(reserved.isValid, "Application policy changed structural validity")
            var proposed = original; proposed[.screenshot] = reserved
            if case .failure(.applicationReserved(.screenshot)) = keys.applyShortcuts(proposed) {} else {
                throw VerificationError(description: "Application-reserved command was accepted: \(reserved.displayString)")
            }
        }
        for modifiers: ShortcutModifiers in [[.command, .shift], [.command, .option], [.command, .control]] {
            var proposed = original; proposed[.scroll] = KeyboardShortcut(keyCode: 6, modifiers: modifiers)
            try require(HotKeys.validate(proposed) == .applicationReserved(.scroll), "Undo/redo modifier variants were not protected")
        }
        try require(keys.registeredShortcuts == original && backend.attempts.count == attempts,
                    "Application conflict modified active registrations")
        backend.emit(original[.screenshot]!)
        try require(fired() == [.screenshot], "Application conflict damaged the old screenshot shortcut")
        var permitted = original
        permitted[.screenshot] = KeyboardShortcut(keyCode: 25, modifiers: [.command, .shift])
        try keys.applyShortcuts(permitted).get()
        try require(keys.registeredShortcuts[.screenshot]?.displayString == "⇧⌘9", "Valid Command-Shift shortcut was rejected")

        let memory = MemoryPreferencesStorage()
        let store = PreferencesStore(storage: memory)
        var previouslySaved = ShortcutAction.defaultShortcuts
        previouslySaved[.screenshot] = KeyboardShortcut(keyCode: 8, modifiers: [.command])
        try require(store.setShortcuts(previouslySaved), "Could not construct a previous-version saved conflict")
        let writes = memory.writeCount
        let reconstructed = PreferencesStore(storage: memory)
        try require(reconstructed.shortcuts == previouslySaved && memory.writeCount == writes,
                    "Reading an application-reserved stored shortcut silently replaced it")
        let launchBackend = FakeHotKeyBackend()
        let launchKeys = HotKeys(backend: launchBackend)
        let failures = launchKeys.installShortcuts(reconstructed.shortcuts, actions: [:])
        try require(failures[.screenshot] == .applicationReserved(.screenshot)
                    && launchKeys.unavailable == [1] && launchBackend.registrations.count == ShortcutAction.allCases.count - 1
                    && reconstructed.shortcuts == previouslySaved && memory.writeCount == writes,
                    "Launching with a saved application conflict lost data or disabled unrelated keys")
    }

    @MainActor private static func recording() throws {
        let (keys, backend, fired) = try installed()
        var captured: KeyboardShortcut?
        keys.beginRecording { captured = $0 }
        backend.emit(ShortcutAction.screenshot.defaultShortcut)
        try require(captured == ShortcutAction.screenshot.defaultShortcut && fired().isEmpty,
                    "Recording fired the screenshot action or missed its already-registered keys")
        keys.endRecording()
        backend.emit(ShortcutAction.screenshot.defaultShortcut)
        try require(fired() == [.screenshot], "Ending recording did not restore action dispatch")
    }

    @MainActor private static func event(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                          windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                          isARepeat: false, keyCode: code) else {
            throw VerificationError(description: "Cannot construct synthetic recorder event")
        }
        return event
    }

    @MainActor private static func settings() throws {
        let (keys, backend, _) = try installed()
        let memory = MemoryPreferencesStorage()
        let store = PreferencesStore(storage: memory)
        var changes = 0
        let controller = SettingsController(hotKeys: keys, store: store, onChange: { changes += 1 })
        controller.verificationStartRecording(.screenshot)
        try require(keys.isRecordingShortcut, "Recorder did not intercept registered hotkeys")
        let escape = try event(53)
        try require(controller.verificationCapture(escape), "Esc was not handled")
        try require(!keys.isRecordingShortcut && controller.verificationDraft == store.shortcuts,
                    "Esc changed the configuration or left recording enabled")
        controller.verificationStartRecording(.screenshot)
        _ = controller.verificationCapture(try event(0, [.shift]))
        try require(!keys.isRecordingShortcut && controller.verificationRowMessage(.screenshot).contains("日常输入")
                    && controller.verificationRecorderTitle(.screenshot) == "⇧A", "Invalid chord was not displayed and explained in its row")
        controller.verificationStartRecording(.screenshot)
        _ = controller.verificationCapture(try event(122, [.option]))
        let chosen = KeyboardShortcut(keyCode: 122, modifiers: [.option])
        try require(controller.verificationDraft[.screenshot] == chosen && !keys.isRecordingShortcut,
                    "Valid synthetic chord did not become a pending draft")
        backend.blocked.insert(chosen)
        controller.verificationSave()
        try require(store.shortcuts == ShortcutAction.defaultShortcuts && memory.writeCount == 0 && changes == 0,
                    "Failed save persisted a draft or refreshed consumers")
        backend.blocked.remove(chosen)
        controller.verificationSave()
        try require(store.shortcuts[.screenshot] == chosen && changes == 1, "Successful save did not persist and notify")
        controller.verificationRestoreDefaults()
        try require(store.shortcuts[.screenshot] == chosen && controller.verificationDraft == ShortcutAction.defaultShortcuts,
                    "Restore defaults applied without save")
        controller.verificationSave()
        try require(store.shortcuts == ShortcutAction.defaultShortcuts && changes == 2, "Default restoration was not applied")
        controller.verificationStartRecording(.record)
        let commandQ = try event(12, [.command])
        try require(controller.window?.performKeyEquivalent(with: commandQ) == true
                    && controller.verificationDraft[.record] == KeyboardShortcut(keyCode: 12, modifiers: [.command])
                    && controller.verificationStatus.contains("小贴的编辑或窗口操作保留"),
                    "Command-Q escaped recorder/menu interception or was not flagged as application reserved")
        let afterDefaults = store.shortcuts
        controller.verificationSave()
        try require(store.shortcuts == afterDefaults && changes == 2,
                    "An application-reserved draft was persisted")
        controller.verificationStartRecording(.record)
        let tab = try event(48)
        try require(!controller.verificationCapture(tab) && !keys.isRecordingShortcut,
                    "Tab did not end recording and restore keyboard navigation")
        controller.verificationStartRecording(.text)
        backend.emit(ShortcutAction.pin.defaultShortcut)
        try require(controller.verificationDraft[.text] == ShortcutAction.pin.defaultShortcut
                    && controller.verificationStatus.contains("相同快捷键"), "Already registered key was not captured/validated")
        controller.window?.close()
        try require(!keys.isRecordingShortcut, "Closing Settings left shortcut interception active")
    }

    @MainActor private static func resolvedDuplicateSwap() throws {
        let (keys, backend, fired) = try installed()
        let memory = MemoryPreferencesStorage()
        let store = PreferencesStore(storage: memory)
        var changes = 0
        let editor = ShortcutEditorSession(hotKeys: keys, store: store, onSave: { changes += 1 })
        let original = ShortcutAction.defaultShortcuts
        editor.startRecording(.screenshot)
        _ = editor.capture(try event(19, [.option]))
        try require(!editor.save() && editor.hasIssues
                    && editor.message(.screenshot).contains("相同快捷键")
                    && editor.message(.scroll).contains("相同快捷键"),
                    "Saving a duplicate did not identify both affected shortcuts")
        try require(store.shortcuts == original && keys.registeredShortcuts == original
                    && memory.writeCount == 0 && changes == 0,
                    "Failed duplicate save changed persisted or active shortcuts")

        // Fix only the other endpoint; the first captured value stays unchanged.
        editor.startRecording(.scroll)
        _ = editor.capture(try event(18, [.option]))
        try require(keys.shortcutIssues(editor.draft).isEmpty,
                    "Completing the swap still leaves a real shortcut conflict")
        try require(!editor.hasIssues && editor.message(.screenshot).isEmpty && editor.message(.scroll).isEmpty,
                    "Resolved duplicate was retained on the unchanged endpoint after the failed save")
        try require(editor.save() && changes == 1 && memory.writeCount == 1,
                    "The resolved key swap did not save as one configuration")
        try require(store.shortcuts[.screenshot] == original[.scroll]
                    && store.shortcuts[.scroll] == original[.screenshot]
                    && keys.registeredShortcuts == store.shortcuts && backend.registrations.count == ShortcutAction.allCases.count,
                    "Saved key swap has incorrect bindings or registration count")
        backend.emit(original[.scroll]!)
        backend.emit(original[.screenshot]!)
        try require(fired() == [.screenshot, .scroll], "Saved key swap dispatches the wrong actions")
    }

    @MainActor private static func partialBatchFixture() throws -> (PreferencesStore, MemoryPreferencesStorage, HotKeys, FakeHotKeyBackend, ShortcutEditorSession, () -> [ShortcutAction]) {
        let memory = MemoryPreferencesStorage(), store = PreferencesStore(storage: memory)
        let backend = FakeHotKeyBackend(), keys = HotKeys(backend: backend)
        backend.blocked.insert(ShortcutAction.subject.defaultShortcut)
        var fired: [ShortcutAction] = []
        let actions = Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { action in
            (action, { fired.append(action) })
        })
        let failures = keys.installShortcuts(store.shortcuts, actions: actions)
        try require(failures.count == 1 && failures[.subject] != nil && keys.registeredShortcuts.count == ShortcutAction.allCases.count - 1,
                    "Could not prepare the independent startup failure")
        backend.attempts = []
        return (store, memory, keys, backend, ShortcutEditorSession(hotKeys: keys, store: store), { fired })
    }

    @MainActor private static func batchPartialLaunch() throws {
        let (store, memory, keys, backend, editor, fired) = try partialBatchFixture()
        let replacement = KeyboardShortcut(keyCode: 122, modifiers: [.option])
        editor.startRecording(.screenshot)
        _ = editor.capture(try event(122, [.option]))
        try require(memory.writeCount == 0 && keys.registeredShortcuts[.screenshot] == ShortcutAction.screenshot.defaultShortcut,
                    "Batch input changed active or saved shortcuts before Done")
        try require(editor.save() && store.shortcuts[.screenshot] == replacement && keys.registeredShortcuts[.screenshot] == replacement
                    && keys.registeredShortcuts[.subject] == nil && keys.unavailable == [ShortcutAction.subject.legacyID]
                    && editor.hasIssue(.subject) && backend.attempts == [replacement] && memory.writeCount == 1,
                    "An unrelated startup failure blocked the batch edit or was falsely repaired")
        backend.emit(replacement)
        try require(fired() == [.screenshot], "Independent batch edit lost its callback")

        // Editing back to the already-saved key must not retry the unrelated failure.
        backend.attempts = []
        editor.startRecording(.screenshot); _ = editor.capture(try event(120, [.option]))
        editor.startRecording(.screenshot); _ = editor.capture(try event(122, [.option]))
        try require(editor.save() && backend.attempts.isEmpty && memory.writeCount == 1,
                    "A draft restored to its saved value retried an unrelated missing key")

        // Change live state independently after commit: a subsequent Save must not
        // replay the previously edited action. No private session state is inspected.
        try keys.applyShortcuts(keys.registeredShortcuts.filter { $0.key != .screenshot }).get()
        backend.blocked.insert(replacement); backend.attempts = []
        try require(editor.save() && backend.attempts.isEmpty && keys.registeredShortcuts[.screenshot] == nil,
                    "A successful save retained stale edited actions")
        editor.startRecording(.subject); _ = editor.capture(try event(22, [.option]))
        editor.reset()
        try require(editor.save() && backend.attempts.isEmpty && keys.registeredShortcuts[.subject] == nil,
                    "Cancelling a draft retained edited actions")

        // Old valid preferences can contain a command that is now application-reserved.
        let legacyMemory = MemoryPreferencesStorage(), legacyStore = PreferencesStore(storage: legacyMemory)
        var legacy = ShortcutAction.defaultShortcuts
        legacy[.subject] = KeyboardShortcut(keyCode: 8, modifiers: [.command])
        try require(legacyStore.setShortcuts(legacy), "Cannot construct legacy reserved preference")
        let legacyBackend = FakeHotKeyBackend(), legacyKeys = HotKeys(backend: legacyBackend)
        _ = legacyKeys.installShortcuts(legacy, actions: [:])
        let legacyEditor = ShortcutEditorSession(hotKeys: legacyKeys, store: legacyStore)
        legacyEditor.startRecording(.screenshot); _ = legacyEditor.capture(try event(122, [.option]))
        try require(legacyEditor.save() && legacyStore.shortcuts[.screenshot] == replacement
                    && legacyStore.shortcuts[.subject] == legacy[.subject] && legacyKeys.registeredShortcuts[.subject] == nil,
                    "An untouched legacy application command blocked a valid batch edit")
    }

    @MainActor private static func batchSameValueRepair() throws {
        let (store, memory, keys, backend, editor, fired) = try partialBatchFixture()
        let missing = ShortcutAction.subject.defaultShortcut, initialActive = keys.registeredShortcuts
        // A no-edit save only retries deferred cleanup, not unrelated failed launches.
        try require(editor.save() && backend.attempts.isEmpty && keys.registeredShortcuts == initialActive,
                    "No-edit save retried an unavailable launch key")
        editor.startRecording(.subject); _ = editor.capture(try event(22, [.option]))
        try require(!editor.save() && backend.attempts == [missing] && keys.registeredShortcuts == initialActive,
                    "Explicit same-value recording did not retry its failed registration")
        backend.blocked.remove(missing); backend.attempts = []
        try require(editor.save() && backend.attempts == [missing] && keys.registeredShortcuts == store.shortcuts
                    && keys.unavailable.isEmpty && store.shortcuts == ShortcutAction.defaultShortcuts,
                    "A failed same-value repair lost edit intent before retry")
        backend.emit(missing)
        try require(fired() == [.subject], "Same-value repair lost the startup callback")

        // The old Settings default button stages the entire set until Save.
        try keys.applyShortcuts(keys.registeredShortcuts.filter { $0.key != .subject }).get()
        backend.blocked.insert(missing); backend.attempts = []
        let writes = memory.writeCount
        editor.restoreDefaults()
        try require(!editor.save() && backend.attempts == [missing] && memory.writeCount == writes,
                    "Staged defaults did not attempt every default or changed preferences after failure")
        backend.blocked.remove(missing)
        try require(editor.save() && keys.registeredShortcuts == ShortcutAction.defaultShortcuts,
                    "Staged default restoration did not retain full-set retry intent")
        try keys.applyShortcuts(keys.registeredShortcuts.filter { $0.key != .subject }).get()
        backend.blocked.insert(missing); backend.attempts = []
        try require(!editor.restoreDefaultsImmediately() && !editor.defaultsWereCommitted && backend.attempts == [missing],
                    "Immediate default restoration no longer attempts the full set")
    }

    @MainActor private static func batchPartialSwap() throws {
        let (store, memory, keys, backend, editor, fired) = try partialBatchFixture()
        let original = store.shortcuts, originalActive = keys.registeredShortcuts
        editor.startRecording(.screenshot); _ = editor.capture(try event(19, [.option]))
        try require(!editor.save() && editor.hasIssue(.screenshot) && editor.hasIssue(.scroll)
                    && store.shortcuts == original && keys.registeredShortcuts == originalActive && backend.attempts.isEmpty,
                    "A partial duplicate swap changed active or persisted keys")
        editor.startRecording(.scroll); _ = editor.capture(try event(18, [.option]))
        try require(editor.save() && store.shortcuts[.screenshot] == original[.scroll]
                    && store.shortcuts[.scroll] == original[.screenshot] && keys.registeredShortcuts[.subject] == nil
                    && keys.registeredShortcuts.count == ShortcutAction.allCases.count - 1 && backend.attempts.isEmpty && memory.writeCount == 1,
                    "An unrelated launch failure blocked an atomic two-action swap")
        backend.emit(original[.scroll]!); backend.emit(original[.screenshot]!)
        try require(fired() == [.screenshot, .scroll], "A partial-registration swap lost action routing")

        let swapped = store.shortcuts, swappedActive = keys.registeredShortcuts
        editor.startRecording(.text); _ = editor.capture(try event(22, [.option]))
        try require(!editor.save() && editor.message(.text).contains("相同快捷键") && editor.hasIssue(.subject)
                    && store.shortcuts == swapped && keys.registeredShortcuts == swappedActive && backend.attempts.isEmpty,
                    "A duplicate of an inactive saved shortcut bypassed global validation")
    }

    @MainActor private static func immediateCommitAndRetry() throws {
        let (keys, backend, fired) = try installed()
        let memory = MemoryPreferencesStorage()
        let store = PreferencesStore(storage: memory)
        var changes = 0
        let editor = ShortcutEditorSession(hotKeys: keys, store: store, appliesImmediately: true, onSave: { changes += 1 })
        let old = ShortcutAction.screenshot.defaultShortcut
        let replacement = KeyboardShortcut(keyCode: 122, modifiers: [.option])
        backend.blocked.insert(replacement)
        editor.startRecording(.screenshot)
        _ = editor.capture(try event(122, [.option]))
        try require(backend.attempts.contains(replacement) && editor.hasIssue(.screenshot)
                    && editor.message(.screenshot).contains(replacement.displayString)
                    && editor.message(.screenshot).contains(old.displayString)
                    && editor.message(.screenshot).contains("不可用"),
                    "Unavailable candidate was not actually registered and explained immediately")
        try require(store.shortcuts == ShortcutAction.defaultShortcuts && memory.writeCount == 0 && changes == 0
                    && keys.registeredShortcuts[.screenshot] == old && editor.recordingTitle(.screenshot) == old.displayString
                    && editor.recordingAction == nil && !keys.isRecordingShortcut,
                    "Failed immediate registration changed preferences, active keys, displayed key or recording state")
        backend.emit(old)
        try require(fired() == [.screenshot], "Failed immediate edit disabled the previous shortcut")

        backend.blocked.remove(replacement)
        editor.startRecording(.screenshot)
        _ = editor.capture(try event(122, [.option]))
        try require(store.shortcuts[.screenshot] == replacement && keys.registeredShortcuts[.screenshot] == replacement
                    && memory.writeCount == 1 && changes == 1 && !editor.hasIssue(.screenshot)
                    && editor.recordingTitle(.screenshot) == replacement.displayString && !keys.isRecordingShortcut,
                    "Retry did not immediately persist, notify, clear feedback and end recording")
        backend.emit(old)
        backend.emit(replacement)
        try require(fired() == [.screenshot, .screenshot], "Successful immediate edit kept the old key or lost the new route")
        editor.reset()
        editor.startRecording(.screenshot)
        _ = editor.capture(try event(53))
        editor.startRecording(.screenshot)
        let tab = try event(48)
        try require(!editor.capture(tab), "Immediate Tab should retain standard keyboard navigation")
        try require(store.shortcuts[.screenshot] == replacement && editor.draft == store.shortcuts
                    && memory.writeCount == 1 && changes == 1 && !keys.isRecordingShortcut,
                    "Reset, Esc or Tab reverted an already applied shortcut")
        try require(PreferencesStore(storage: memory).shortcuts[.screenshot] == replacement,
                    "Immediate shortcut did not survive preference reconstruction")
    }

    @MainActor private static func immediateConflicts() throws {
        let (keys, backend, fired) = try installed()
        let memory = MemoryPreferencesStorage()
        let store = PreferencesStore(storage: memory)
        var changes = 0
        let editor = ShortcutEditorSession(hotKeys: keys, store: store, appliesImmediately: true, onSave: { changes += 1 })
        let old = ShortcutAction.screenshot.defaultShortcut
        let system = KeyboardShortcut(keyCode: 8, modifiers: [.control])
        backend.symbolic.insert(system)
        let cases: [(UInt16, NSEvent.ModifierFlags, String)] = [
            (0, [.shift], "Shift"),
            (12, [.command], "保留"),
            (19, [.option], "相同快捷键"),
            (8, [.control], "系统使用")
        ]
        let attempts = backend.attempts.count
        for (code, flags, reason) in cases {
            editor.startRecording(.screenshot)
            let candidateEvent = try event(code, flags)
            let candidate = KeyboardShortcut(event: candidateEvent)
            _ = editor.capture(candidateEvent)
            let message = editor.message(.screenshot)
            try require(editor.hasIssue(.screenshot) && message.contains(candidate.displayString)
                        && message.contains(old.displayString) && message.contains(reason),
                        "Immediate rejected chord was not explained with the attempted and active keys: \(candidate.displayString)")
            try require(store.shortcuts == ShortcutAction.defaultShortcuts && keys.registeredShortcuts == store.shortcuts
                        && memory.writeCount == 0 && changes == 0 && editor.recordingTitle(.screenshot) == old.displayString
                        && !keys.isRecordingShortcut && backend.attempts.count == attempts,
                        "Validation rejection changed bindings/preferences or attempted a registration")
        }
        editor.startRecording(.screenshot)
        backend.emit(ShortcutAction.scroll.defaultShortcut)
        try require(fired().isEmpty && editor.hasIssue(.screenshot) && !keys.isRecordingShortcut
                    && editor.recordingTitle(.screenshot) == old.displayString,
                    "Registered duplicate dispatched a feature or replaced the active key during immediate recording")
        backend.symbolicStatus = -108
        editor.startRecording(.screenshot)
        _ = editor.capture(try event(122, [.option]))
        try require(editor.message(.screenshot).contains("暂时无法检查系统快捷键")
                    && !editor.message(.screenshot).contains("108") && store.shortcuts == ShortcutAction.defaultShortcuts
                    && keys.registeredShortcuts == store.shortcuts && memory.writeCount == 0,
                    "Immediate system-check failure changed saved/active keys or hid its cause")
    }

    @MainActor private static func immediateFailureIsolation() throws {
        let (keys, backend, _) = try installed()
        let memory = MemoryPreferencesStorage()
        let store = PreferencesStore(storage: memory)
        var changes = 0
        let editor = ShortcutEditorSession(hotKeys: keys, store: store, appliesImmediately: true, onSave: { changes += 1 })
        let blocked = KeyboardShortcut(keyCode: 122, modifiers: [.option])
        let other = KeyboardShortcut(keyCode: 120, modifiers: [.option])
        backend.blocked.insert(blocked)
        editor.startRecording(.screenshot)
        _ = editor.capture(try event(122, [.option]))
        let attemptsAfterFailure = backend.attempts.count
        editor.startRecording(.text)
        _ = editor.capture(try event(120, [.option]))
        try require(store.shortcuts[.text] == other && keys.registeredShortcuts[.text] == other
                    && store.shortcuts[.screenshot] == ShortcutAction.screenshot.defaultShortcut
                    && keys.registeredShortcuts[.screenshot] == ShortcutAction.screenshot.defaultShortcut
                    && memory.writeCount == 1 && changes == 1,
                    "Failed candidate leaked into and blocked an unrelated immediate change")
        try require(Array(backend.attempts.dropFirst(attemptsAfterFailure)) == [other],
                    "Unrelated edit retried a previous rejected candidate")
    }

    @MainActor private static func immediatePartialLaunch() throws {
        let backend = FakeHotKeyBackend()
        let keys = HotKeys(backend: backend)
        let missing = ShortcutAction.scroll.defaultShortcut
        backend.blocked.insert(missing)
        var fired: [ShortcutAction] = []
        let actions = Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { action in
            (action, { fired.append(action) })
        })
        let failures = keys.installShortcuts(ShortcutAction.defaultShortcuts, actions: actions)
        try require(failures.keys.contains(.scroll) && backend.registrations.count == ShortcutAction.allCases.count - 1,
                    "Could not prepare an unrelated launch registration failure")
        let memory = MemoryPreferencesStorage()
        let store = PreferencesStore(storage: memory)
        var changes = 0
        let editor = ShortcutEditorSession(hotKeys: keys, store: store, appliesImmediately: true, onSave: { changes += 1 })
        editor.startRecording(.screenshot)
        _ = editor.capture(try event(19, [.option]))
        try require(memory.writeCount == 0 && editor.hasIssue(.screenshot)
                    && editor.message(.screenshot).contains("相同快捷键"),
                    "A duplicate of an unregistered saved shortcut bypassed complete preference validation")

        let before = backend.attempts.count
        let replacement = KeyboardShortcut(keyCode: 122, modifiers: [.option])
        editor.startRecording(.screenshot)
        _ = editor.capture(try event(122, [.option]))
        try require(store.shortcuts[.screenshot] == replacement && store.shortcuts[.scroll] == missing
                    && keys.registeredShortcuts[.screenshot] == replacement && keys.registeredShortcuts[.scroll] == nil
                    && keys.unavailable == [ShortcutAction.scroll.legacyID] && changes == 1 && memory.writeCount == 1,
                    "Unrelated launch failure prevented an immediate edit or was falsely marked repaired")
        try require(Array(backend.attempts.dropFirst(before)) == [replacement],
                    "Immediate edit retried an unrelated unavailable launch shortcut")
        backend.emit(replacement)
        backend.emit(ShortcutAction.subject.defaultShortcut)
        try require(fired == [.screenshot, .subject], "Partial launch edit damaged action routing")

        let repaired = KeyboardShortcut(keyCode: 120, modifiers: [.option])
        editor.startRecording(.scroll)
        _ = editor.capture(try event(120, [.option]))
        try require(store.shortcuts[.scroll] == repaired && keys.registeredShortcuts[.scroll] == repaired
                    && keys.unavailable.isEmpty && backend.registrations.count == ShortcutAction.allCases.count
                    && memory.writeCount == 2 && changes == 2,
                    "Immediate repair did not restore the unavailable launch action")
        backend.emit(repaired)
        try require(fired.last == .scroll, "Repaired launch action lost its original callback")

        // Older preferences may contain a now-reserved command. It remains
        // visible/unavailable, but must not prevent editing a different action.
        let legacyMemory = MemoryPreferencesStorage()
        let legacyStore = PreferencesStore(storage: legacyMemory)
        var legacy = ShortcutAction.defaultShortcuts
        legacy[.screenshot] = KeyboardShortcut(keyCode: 8, modifiers: [.command])
        try require(legacyStore.setShortcuts(legacy), "Could not prepare a saved legacy application conflict")
        let legacyWrites = legacyMemory.writeCount
        let legacyBackend = FakeHotKeyBackend()
        let legacyKeys = HotKeys(backend: legacyBackend)
        let legacyFailures = legacyKeys.installShortcuts(legacy, actions: [:])
        try require(legacyFailures[.screenshot] == .applicationReserved(.screenshot),
                    "Legacy application conflict did not reproduce the unavailable startup state")
        let legacyEditor = ShortcutEditorSession(hotKeys: legacyKeys, store: legacyStore, appliesImmediately: true)
        legacyEditor.startRecording(.text)
        _ = legacyEditor.capture(try event(122, [.option]))
        try require(legacyStore.shortcuts[.text] == replacement && legacyKeys.registeredShortcuts[.text] == replacement
                    && legacyStore.shortcuts[.screenshot] == legacy[.screenshot]
                    && legacyKeys.registeredShortcuts[.screenshot] == nil
                    && legacyKeys.unavailable == [ShortcutAction.screenshot.legacyID]
                    && legacyMemory.writeCount == legacyWrites + 1 && !legacyEditor.hasIssue(.text),
                    "Unrelated saved application-reserved shortcut blocked a valid immediate edit")
        legacyEditor.startRecording(.screenshot)
        _ = legacyEditor.capture(try event(120, [.option]))
        try require(legacyStore.shortcuts[.screenshot] == repaired && legacyStore.shortcuts[.text] == replacement
                    && legacyKeys.registeredShortcuts == legacyStore.shortcuts && legacyKeys.unavailable.isEmpty
                    && legacyBackend.registrations.count == ShortcutAction.allCases.count
                    && legacyMemory.writeCount == legacyWrites + 2 && !legacyEditor.hasIssues,
                    "Repairing the legacy reserved key lost the prior immediate edit or retained its unavailable state")
    }

    @MainActor private static func immediateCleanup() throws {
        let (keys, backend, fired) = try installed()
        let memory = MemoryPreferencesStorage()
        let store = PreferencesStore(storage: memory)
        var changes = 0
        let editor = ShortcutEditorSession(hotKeys: keys, store: store, appliesImmediately: true, onSave: { changes += 1 })
        let old = ShortcutAction.screenshot.defaultShortcut
        let replacement = KeyboardShortcut(keyCode: 122, modifiers: [.option])
        backend.releaseStatus = -50
        editor.startRecording(.screenshot)
        _ = editor.capture(try event(122, [.option]))
        try require(store.shortcuts[.screenshot] == replacement && keys.registeredShortcuts[.screenshot] == replacement
                    && editor.recordingTitle(.screenshot) == replacement.displayString
                    && changes == 1 && memory.writeCount == 1 && !keys.isRecordingShortcut
                    && editor.message(.screenshot).contains("快捷键释放未完成"),
                    "Cleanup warning incorrectly rolled back or failed to persist a successful immediate edit")
        try require(ShortcutAction.allCases.filter { $0 != .screenshot }.allSatisfy { editor.message($0).isEmpty },
                    "Immediate cleanup warning leaked to unrelated rows")
        backend.emit(old)
        backend.emit(replacement)
        try require(fired() == [.screenshot], "Cleanup failure left the obsolete action live or broke the new key")
        backend.releaseStatus = noErr
        editor.startRecording(.screenshot)
        backend.emit(replacement)
        try require(keys.cleanupWarnings.isEmpty && backend.registrations.count == ShortcutAction.allCases.count
                    && !editor.hasIssue(.screenshot) && store.shortcuts[.screenshot] == replacement
                    && memory.writeCount == 1 && fired() == [.screenshot] && !keys.isRecordingShortcut,
                    "Re-recording the active key did not retry cleanup safely without dispatching its action")
    }

    @MainActor private static func immediateDefaults() throws {
        let (keys, backend, fired) = try installed()
        let memory = MemoryPreferencesStorage()
        let store = PreferencesStore(storage: memory)
        var custom = ShortcutAction.defaultShortcuts
        custom[.screenshot] = KeyboardShortcut(keyCode: 122, modifiers: [.option])
        custom[.scroll] = KeyboardShortcut(keyCode: 120, modifiers: [.option])
        try keys.applyShortcuts(custom).get()
        try require(store.setShortcuts(custom), "Could not prepare custom defaults-restoration fixture")
        let writes = memory.writeCount
        let released = backend.released.count
        var changes = 0
        let editor = ShortcutEditorSession(hotKeys: keys, store: store, appliesImmediately: true, onSave: { changes += 1 })
        backend.blocked.insert(ShortcutAction.scroll.defaultShortcut)
        editor.startRecording(.subject)
        editor.restoreDefaults()
        try require(store.shortcuts == custom && keys.registeredShortcuts == custom
                    && memory.writeCount == writes && changes == 0 && !keys.isRecordingShortcut,
                    "Failed immediate default restoration partially changed preferences or active keys")
        try require(backend.registrations.count == ShortcutAction.allCases.count && backend.released.count == released + 1,
                    "Failed default restoration did not release its staged registration")
        backend.emit(custom[.screenshot]!)
        backend.emit(custom[.scroll]!)
        try require(fired() == [.screenshot, .scroll], "Failed default restoration damaged prior callbacks")
        backend.blocked.remove(ShortcutAction.scroll.defaultShortcut)
        editor.restoreDefaults()
        try require(store.shortcuts == ShortcutAction.defaultShortcuts && keys.registeredShortcuts == store.shortcuts
                    && editor.draft == store.shortcuts && memory.writeCount == writes + 1 && changes == 1
                    && !editor.hasIssues && backend.registrations.count == ShortcutAction.allCases.count,
                    "Immediate default restoration did not persist the complete default configuration")
        backend.emit(custom[.screenshot]!)
        backend.emit(ShortcutAction.screenshot.defaultShortcut)
        try require(fired() == [.screenshot, .scroll, .screenshot], "Restored defaults retained obsolete callbacks or lost defaults")
    }

    @MainActor private static func nativeControlC() throws {
        let (keys, _, fired) = try installed()
        let controller = SettingsController(hotKeys: keys, store: PreferencesStore(storage: MemoryPreferencesStorage()))
        controller.verificationStartRecording(.screenshot)
        guard let window = controller.window, let responder = window.firstResponder,
              let controlC = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control], timestamp: 0,
                                              windowNumber: window.windowNumber, context: nil,
                                              characters: "\u{3}", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8) else {
            throw VerificationError(description: "Recorder has no native first responder")
        }
        print("INFO: Control-C native responder = \(type(of: responder))")
        responder.keyDown(with: controlC)
        try require(controller.verificationDraft[.screenshot] == KeyboardShortcut(keyCode: 8, modifiers: [.control]),
                    "Native recorder did not capture Control-C")
        try require(fired().isEmpty, "Native recorder dispatched a screenshot action")
        controller.verificationStartRecording(.scroll)
        window.sendEvent(controlC)
        try require(controller.verificationDraft[.scroll] == KeyboardShortcut(keyCode: 8, modifiers: [.control]),
                    "Window sendEvent did not route Control-C to the active recorder")
        controller.verificationStartRecording(.text)
        let sink = RecorderFocusSink(frame: .zero)
        window.contentView?.addSubview(sink)
        try require(window.makeFirstResponder(sink), "Cannot reproduce native first-responder change")
        window.sendEvent(controlC)
        try require(controller.verificationDraft[.text] == KeyboardShortcut(keyCode: 8, modifiers: [.control]),
                    "Control-C was lost after native first-responder focus moved away from the button")
        controller.verificationStartRecording(.record)
        window.cancelOperation(nil)
        try require(!keys.isRecordingShortcut && controller.verificationDraft[.record] == ShortcutAction.record.defaultShortcut,
                    "Native cancelOperation did not leave recording cleanly")
        controller.verificationStartRecording(.record)
        let tab = try event(48)
        window.sendEvent(tab)
        try require(!keys.isRecordingShortcut && controller.verificationDraft[.record] == ShortcutAction.record.defaultShortcut,
                    "Native Tab did not restore standard keyboard navigation")
        controller.window?.close()
    }

    @MainActor private static func rowFeedback() throws {
        let (keys, backend, _) = try installed()
        let memory = MemoryPreferencesStorage()
        let store = PreferencesStore(storage: memory)
        var changes = 0
        var closes = 0
        let controller = SettingsController(hotKeys: keys, store: store, onChange: { changes += 1 })
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                              object: controller.window, queue: .main) { _ in closes += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        try require(ShortcutAction.allCases.allSatisfy({ controller.verificationRowMessage($0).isEmpty }),
                    "Untouched rows show persistent help/status text")
        controller.verificationStartRecording(.screenshot)
        try require(!controller.verificationRowMessage(.screenshot).isEmpty
                    && ShortcutAction.allCases.filter({ $0 != .screenshot }).allSatisfy({ controller.verificationRowMessage($0).isEmpty }),
                    "Recording instructions appear outside the active row")
        _ = controller.verificationCapture(try event(19, [.option]))
        try require(controller.verificationRowMessage(.screenshot).contains("相同快捷键")
                    && controller.verificationRowMessage(.scroll).contains("相同快捷键")
                    && [.text, .pin, .record].allSatisfy({ controller.verificationRowMessage($0).isEmpty }),
                    "Duplicate shortcut feedback does not identify exactly both affected rows")
        let controlC = KeyboardShortcut(keyCode: 8, modifiers: [.control])
        backend.symbolic.insert(controlC)
        controller.verificationStartRecording(.screenshot)
        _ = controller.verificationCapture(try event(8, [.control]))
        try require(controller.verificationRecorderTitle(.screenshot) == "⌃C"
                    && controller.verificationRowMessage(.screenshot).contains("系统使用")
                    && ShortcutAction.allCases.filter({ $0 != .screenshot }).allSatisfy({ controller.verificationRowMessage($0).isEmpty }),
                    "System shortcut conflict was not reported next to its captured value")
        controller.verificationSave()
        try require(closes == 0 && changes == 0 && store.shortcuts == ShortcutAction.defaultShortcuts,
                    "System-conflict failure closed the window or changed saved settings")
        backend.symbolic.remove(controlC)
        backend.blocked.insert(controlC)
        controller.verificationSave()
        try require(controller.verificationRowMessage(.screenshot).contains("不可用")
                    && !controller.verificationRowMessage(.screenshot).contains("9878")
                    && controller.verificationDraft[.screenshot] == controlC && closes == 0
                    && keys.registeredShortcuts == ShortcutAction.defaultShortcuts,
                    "Registration failure lost the draft/old bindings, closed Settings or exposed status codes")
        backend.blocked.remove(controlC)
        controller.verificationSave()
        try require(closes == 1 && changes == 1 && store.shortcuts[.screenshot] == controlC,
                    "Successful save did not notify consumers and close Settings")
        let writes = memory.writeCount
        controller.verificationRestoreDefaults()
        try require(controller.verificationDraft == ShortcutAction.defaultShortcuts
                    && store.shortcuts[.screenshot] == controlC && memory.writeCount == writes && changes == 1,
                    "Restoring defaults applied them without Save")
    }

    @MainActor private static func releaseRetry() throws {
        let (keys, backend, fired) = try installed()
        let old = ShortcutAction.screenshot.defaultShortcut
        let replacement = KeyboardShortcut(keyCode: 122, modifiers: [.command, .control])
        var proposed = ShortcutAction.defaultShortcuts; proposed[.screenshot] = replacement
        backend.releaseStatus = -50
        try keys.applyShortcuts(proposed).get()
        try require(keys.cleanupWarnings == [-50] && backend.registrations.count == ShortcutAction.allCases.count + 1,
                    "Release failure was not retained for cleanup")
        backend.emit(old)
        try require(fired().isEmpty, "Obsolete callback remained active after replacement")
        backend.emit(replacement)
        try require(fired() == [.screenshot], "Release failure broke the new callback")
        backend.releaseStatus = noErr
        try keys.applyShortcuts(proposed).get()
        try require(keys.cleanupWarnings.isEmpty && backend.registrations.count == ShortcutAction.allCases.count, "Pending release was not retried")
    }

    @MainActor private static func registeredControlC() throws {
        let (keys, backend, fired) = try installed()
        let controlC = KeyboardShortcut(keyCode: 8, modifiers: [.control])
        var chosen = ShortcutAction.defaultShortcuts; chosen[.screenshot] = controlC
        try keys.applyShortcuts(chosen).get()
        let store = PreferencesStore(storage: MemoryPreferencesStorage())
        try require(store.setShortcuts(chosen), "Cannot prepare saved Control-C")
        let controller = SettingsController(hotKeys: keys, store: store)
        controller.verificationStartRecording(.text)
        backend.emit(controlC)
        try require(controller.verificationDraft[.text] == controlC
                    && controller.verificationRecorderTitle(.text) == "⌃C"
                    && controller.verificationRowMessage(.text).contains("相同快捷键")
                    && controller.verificationRowMessage(.screenshot).contains("相同快捷键")
                    && fired().isEmpty && !keys.isRecordingShortcut,
                    "Registered Control-C dispatched an action or was lost by the recorder")
        controller.window?.close()
    }

    @MainActor private static func rowBackendFailures() throws {
        let (keys, backend, _) = try installed()
        let store = PreferencesStore(storage: MemoryPreferencesStorage())
        let controller = SettingsController(hotKeys: keys, store: store)
        backend.symbolicStatus = -108
        controller.verificationStartRecording(.screenshot)
        _ = controller.verificationCapture(try event(122, [.shift]))
        try require(ShortcutAction.allCases.allSatisfy {
            controller.verificationRowMessage($0).contains("暂时无法检查系统快捷键")
                && !controller.verificationRowMessage($0).contains("108")
        }, "System-check failure is hidden or exposes backend codes")
        controller.verificationSave()
        try require(store.shortcuts == ShortcutAction.defaultShortcuts && keys.registeredShortcuts == ShortcutAction.defaultShortcuts,
                    "System-check failure changed active or saved bindings")
        backend.symbolicStatus = noErr
        backend.releaseStatus = -50
        controller.verificationSave()
        try require(store.shortcuts[.screenshot] == KeyboardShortcut(keyCode: 122, modifiers: [.shift])
                    && controller.verificationRowMessage(.screenshot).contains("快捷键释放未完成")
                    && !controller.verificationRowMessage(.screenshot).contains("50"),
                    "Cleanup failure lost the accepted configuration or was not explained")
        try require(ShortcutAction.allCases.filter({ $0 != .screenshot }).allSatisfy({ controller.verificationRowMessage($0).isEmpty }),
                    "Cleanup warning appeared next to unrelated shortcut rows")
        backend.releaseStatus = noErr
        controller.verificationSave()
        try require(keys.cleanupWarnings.isEmpty && backend.registrations.count == ShortcutAction.allCases.count,
                    "Saving again did not retry cleanup")
    }

    @MainActor private static func settingsPreview() throws {
        let (keys, _, _) = try installed()
        let controller = SettingsController(hotKeys: keys, store: PreferencesStore(storage: MemoryPreferencesStorage()))
        controller.verificationStartRecording(.screenshot)
        _ = controller.verificationCapture(try event(19, [.option]))
        guard let content = controller.window?.contentView else { throw VerificationError(description: "No Settings content view") }
        content.layoutSubtreeIfNeeded()
        guard let stack = content.subviews.compactMap({ $0 as? NSStackView }).first else {
            throw VerificationError(description: "No Settings row stack")
        }
        let rowTitles = stack.arrangedSubviews.compactMap { row in
            ((row as? NSStackView)?.arrangedSubviews.first as? NSTextField)?.stringValue
        }
        try require(rowTitles == ShortcutAction.settingsOrder.map(\.title), "Settings rows do not follow feature display order")
        func inspect(_ view: NSView) throws {
            for child in view.subviews where !child.isHidden {
                let rect = content.convert(child.bounds, from: child)
                try require(content.bounds.insetBy(dx: -1, dy: -1).contains(rect), "Visible setting row/control exceeds window bounds")
                try inspect(child)
            }
        }
        try inspect(content)
        if CommandLine.arguments.count > 1 {
            guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
                throw VerificationError(description: "Cannot render synthetic Settings preview")
            }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw VerificationError(description: "Cannot encode Settings preview")
            }
            try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("settings-preview.png"))
        }
        controller.window?.close()
    }

    @MainActor private static func rollbackCleanup() throws {
        let (keys, backend, fired) = try installed()
        let memory = MemoryPreferencesStorage()
        let store = PreferencesStore(storage: memory)
        let controller = SettingsController(hotKeys: keys, store: store)
        controller.verificationStartRecording(.screenshot)
        _ = controller.verificationCapture(try event(122, [.option]))
        controller.verificationStartRecording(.scroll)
        _ = controller.verificationCapture(try event(120, [.option]))
        backend.blocked.insert(KeyboardShortcut(keyCode: 120, modifiers: [.option]))
        backend.releaseStatus = -50
        controller.verificationSave()
        try require(keys.registeredShortcuts == ShortcutAction.defaultShortcuts && memory.writeCount == 0
                    && controller.verificationRowMessage(.screenshot).contains("释放未完成")
                    && controller.verificationRowMessage(.scroll).contains("不可用")
                    && [.text, .pin, .record].allSatisfy({ controller.verificationRowMessage($0).isEmpty }),
                    "Rollback cleanup altered old bindings or warned unrelated rows")
        backend.emit(ShortcutAction.screenshot.defaultShortcut)
        try require(fired() == [.screenshot], "Cleanup failure stopped the old screenshot action")
        backend.emit(KeyboardShortcut(keyCode: 122, modifiers: [.option]))
        try require(fired() == [.screenshot], "Unreleased staged key dispatched an uncommitted action")
        backend.releaseStatus = noErr; backend.blocked.removeAll()
        controller.verificationSave()
        try require(keys.cleanupFailures.isEmpty && keys.cleanupWarnings.isEmpty && backend.registrations.count == ShortcutAction.allCases.count
                    && store.shortcuts[.screenshot]?.keyCode == 122 && store.shortcuts[.scroll]?.keyCode == 120,
                    "Retry did not clean up abandoned staging and apply the retained draft")
    }
}
