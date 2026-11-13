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
        guard (2...3).contains(CommandLine.arguments.count), CommandLine.arguments[1].hasPrefix("/"),
              CommandLine.arguments.count == 2 || CommandLine.arguments[2] == "--model-only" else {
            print("Usage: verify-preferences <absolute-output-directory> [--model-only]")
            exit(2)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
            print("FAIL: preference verification exceeded 60 seconds")
            exit(1)
        }
        let modelOnly = CommandLine.arguments.contains("--model-only")
        if !modelOnly {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
        }
        let modelChecks: [(String, () throws -> Void)] = [
            ("per-tool settings persist in injected memory storage without cross-tool inheritance", preferences),
            ("invalid and future preferences fall back without rewriting storage", invalidPreferences),
            ("shortcut serialization and accepted modifiers are validated", shortcutModel),
            ("old 5/6/7-action defaults migrate; custom bindings win conflicts with new actions", legacyShortcuts),
            ("batch count and language preferences persist independently with safe boundaries", batchAndLanguagePreferences),
            ("sticker order persists, normalizes stable IDs and inserts new items beside default neighbours", stickerOrder),
            ("release failures are tracked and retried without dispatching obsolete callbacks", releaseRetry),
            ("zero, one and two bindings persist without overwriting legacy preferences", multipleShortcutPreferences),
            ("two bindings dispatch independently and retries preserve healthy registrations", multipleShortcutBackend),
            ("multi-slot edits reject new conflicts and preserve saved unavailable alternatives", multipleShortcutEditor),
            ("correcting or deleting draft slots preserves only their current registration intent", correctedMultiSlotIntent),
            ("transactional shortcut replacement and key swaps preserve action routing", transactions),
            ("failed registration rolls back all staged registrations and preserves old keys", rollback),
            ("duplicate, system-reserved and backend errors leave old keys live", conflicts),
            ("application commands cannot become global shortcuts and saved conflicts remain visible", applicationPolicy),
            ("launch registration failure leaves other keys usable and can be repaired", launchRepair),
            ("shortcut recording receives registered combinations without invoking actions", recording),
            ("failed duplicate save clears both row errors after completing a key swap", resolvedDuplicateSwap),
            ("batch edits isolate unavailable launch keys and clear committed or cancelled edit intent", batchPartialLaunch),
            ("batch same-value repairs retain failed edit intent and default restoration remains complete", batchSameValueRepair),
            ("batch swaps preserve routing beside unavailable keys and reject duplicates of saved inactive keys", batchPartialSwap),
            ("immediate recording registers, persists and retries failures without Save", immediateCommitAndRetry),
            ("immediate invalid, duplicate, application and system conflicts preserve active keys", immediateConflicts),
            ("a failed immediate candidate does not block another shortcut edit", immediateFailureIsolation),
            ("immediate edits preserve unrelated launch failures and can repair them", immediatePartialLaunch),
            ("immediate cleanup warnings retain the successful binding and retry safely", immediateCleanup),
            ("immediate default restoration commits or rolls back the complete configuration", immediateDefaults)
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
        let modelTitles = Set(modelChecks.map { $0.0 })
        let selectedChecks = modelChecks + (modelOnly ? [] : checks.filter { !modelTitles.contains($0.0) })
        for (title, check) in selectedChecks {
            do { try check(); print("PASS: \(title)") }
            catch { failed += 1; print("FAIL: \(title): \(error)") }
        }
        if failed != 0 { exit(1) }
        print("PASS: \(selectedChecks.count) preference and hotkey checks; fake backend only, no UserDefaults or system input")
    }

    @MainActor private static func stickerOrder() throws {
        let data = Data("{\"version\":1,\"annotations\":{},\"shortcuts\":{},\"stickerOrder\":[\"old-b\",\"b\",\"removed\",\"a\"]}".utf8)
        let memory = MemoryPreferencesStorage(data: data)
        let store = PreferencesStore(storage: memory)
        let defaults = ["a", "b", "c"]
        func canonical(_ id: String) -> String { id == "old-b" ? "b" : id }
        try require(store.orderedStickerIdentifiers(defaults: defaults, canonicalize: canonical) == ["b", "c", "a"], "Legacy/duplicate/removed IDs were not normalized")
        try require(memory.writeCount == 0, "Reading order rewrote preferences")
        store.setStickerOrder(["c", "old-b", "b", "removed"], defaults: defaults, canonicalize: canonical)
        let restored = PreferencesStore(storage: memory)
        try require(restored.orderedStickerIdentifiers(defaults: defaults, canonicalize: canonical) == ["c", "a", "b"], "Sticker reorder was not persisted")
        try require(restored.orderedStickerIdentifiers(defaults: defaults + ["d"], canonicalize: canonical) == ["c", "d", "a", "b"], "New catalog content did not follow its default neighbour")
        let writes = memory.writeCount
        store.setStickerOrder(["c", "a", "b"], defaults: defaults)
        try require(memory.writeCount == writes, "An unchanged order wrote preferences again")
        restored.setStickerOrder(defaults, defaults: defaults)
        let reset = PreferencesStore(storage: memory)
        try require(reset.orderedStickerIdentifiers(defaults: defaults) == defaults, "Default order did not survive reload")
        let plain = MemoryPreferencesStorage(data: Data("{\"version\":1,\"annotations\":{},\"shortcuts\":{}}".utf8))
        try require(PreferencesStore(storage: plain).orderedStickerIdentifiers(defaults: defaults) == defaults && plain.writeCount == 0,
                    "Old settings without sticker order failed to migrate")
        let oldIDs = ["sun", "dog", "cat", "flower"]
        let before = MemoryPreferencesStorage()
        let beforeStore = PreferencesStore(storage: before)
        beforeStore.setStickerOrder(oldIDs, defaults: ["cat", "dog", "sun", "flower"])
        let expanded = ["cat", "blue-cat", "dog", "sun", "flower"]
        let migrated = PreferencesStore(storage: before).orderedStickerIdentifiers(defaults: expanded)
        try require(migrated == ["sun", "dog", "cat", "blue-cat", "flower"] && migrated.filter { $0 != "blue-cat" } == oldIDs,
                    "New blue cat did not stay with the existing cat or changed saved item order")
        beforeStore.setStickerOrder(["blue-cat"] + oldIDs, defaults: expanded)
        try require(PreferencesStore(storage: before).orderedStickerIdentifiers(defaults: expanded) == ["blue-cat"] + oldIDs,
                    "A deliberately reordered blue cat was moved back to its default neighbour")
    }

    @MainActor private static func multipleShortcutPreferences() throws {
        let legacy = try legacyStorage(ShortcutAction.defaultShortcuts, layoutVersion: 2)
        let store = PreferencesStore(storage: legacy)
        try require(store.shortcutBindings == ShortcutAction.defaultShortcuts.mapValues { [$0] } && legacy.writeCount == 0,
                    "Legacy single bindings were changed or rewritten during loading")
        let alternate = KeyboardShortcut(keyCode: 122, modifiers: [.option])
        var bindings = store.shortcutBindings
        bindings[.screenshot, default: []].append(alternate)
        bindings[.pin] = []
        try require(store.setShortcutBindings(bindings), "Zero/two binding configuration was rejected")
        let restarted = PreferencesStore(storage: legacy)
        try require(restarted.shortcutBindings == bindings && restarted.shortcuts[.pin] == nil
                    && restarted.shortcuts[.screenshot] == bindings[.screenshot]?.first,
                    "Zero/two bindings or the legacy primary projection did not survive restart")
        let writes = legacy.writeCount
        var invalid = bindings
        invalid[.screenshot]?.append(KeyboardShortcut(keyCode: 120, modifiers: [.option]))
        try require(!store.setShortcutBindings(invalid) && legacy.writeCount == writes, "A third binding was persisted")
        invalid = bindings; invalid[.scroll] = [alternate]
        try require(!store.setShortcutBindings(invalid), "A cross-action duplicate was persisted")
        invalid = bindings; invalid[.screenshot] = [alternate, alternate]
        try require(!store.setShortcutBindings(invalid) && legacy.writeCount == writes, "A duplicate within one action was persisted")
        bindings[.screenshot] = []
        try require(store.setShortcutBindings(bindings) && PreferencesStore(storage: legacy).shortcutBindings[.screenshot] == [],
                    "Deleting the last binding restored a default on restart")
    }

    @MainActor private static func multipleShortcutBackend() throws {
        let backend = FakeHotKeyBackend(), keys = HotKeys(backend: backend)
        let alternate = KeyboardShortcut(keyCode: 122, modifiers: [.option])
        var desired = ShortcutAction.defaultShortcuts.mapValues { [$0] }
        desired[.screenshot]?.append(alternate); desired[.pin] = []
        backend.blocked = [alternate]
        var fired: [ShortcutAction] = []
        let actions = Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { action in (action, { fired.append(action) }) })
        keys.installBindings(desired, actions: actions)
        try require(keys.unavailableBindingReasons[.screenshot]?[alternate] != nil && keys.unavailable.isEmpty
                    && keys.registeredBindings[.screenshot] == [ShortcutAction.screenshot.defaultShortcut]
                    && keys.registeredBindings[.pin, default: []].isEmpty,
                    "One failed alternative disabled the healthy binding or enabled an empty action")
        let healthyTokens = Set(backend.registrations.keys)
        backend.attempts = []; keys.retryUnavailableBindings()
        try require(backend.attempts == [alternate] && Set(backend.registrations.keys) == healthyTokens && backend.released.isEmpty,
                    "Retry touched healthy registrations")
        backend.blocked = []; backend.attempts = []; keys.retryUnavailableBindings()
        try require(backend.attempts == [alternate] && healthyTokens.isSubset(of: Set(backend.registrations.keys))
                    && keys.unavailableBindingReasons.isEmpty && keys.registeredBindings[.screenshot] == desired[.screenshot],
                    "The unavailable alternative did not recover independently")
        backend.emit(ShortcutAction.screenshot.defaultShortcut); backend.emit(alternate)
        try require(fired == [.screenshot, .screenshot], "Both alternatives did not dispatch their shared action")
        var captured: KeyboardShortcut?
        keys.beginRecording { captured = $0 }; backend.emit(alternate); keys.endRecording()
        try require(captured == alternate && fired.count == 2, "Secondary hotkey recording captured the primary or invoked the feature")
        let allTokens = Set(backend.registrations.keys), previousAttempts = backend.attempts.count
        let oldScroll = desired[.scroll]![0]
        desired[.screenshot]![1] = oldScroll; desired[.scroll] = [alternate]
        try keys.applyBindings(desired).get()
        try require(Set(backend.registrations.keys) == allTokens && backend.attempts.count == previousAttempts,
                    "A binding swap re-registered or released existing chords")
        backend.emit(oldScroll); backend.emit(alternate)
        try require(Array(fired.suffix(2)) == [.screenshot, .scroll], "Swapped secondary binding routed to the previous action")
        var third = desired; third[.screenshot]?.append(KeyboardShortcut(keyCode: 120, modifiers: [.option]))
        if case .failure(.invalid(.screenshot)) = keys.applyBindings(third) {} else {
            throw VerificationError(description: "Backend accepted a third shortcut")
        }
        desired[.screenshot] = []; try keys.applyBindings(desired).get()
        let count = fired.count
        backend.emit(oldScroll); backend.emit(ShortcutAction.screenshot.defaultShortcut)
        try require(fired.count == count && keys.registeredBindings[.screenshot] == [], "Deleted bindings still dispatched")
        let primary = ShortcutAction.screenshot.defaultShortcut
        let firstFailedBackend = FakeHotKeyBackend(), firstFailed = HotKeys(backend: firstFailedBackend)
        firstFailedBackend.blocked = [primary]
        firstFailed.installBindings([.screenshot: [primary, alternate]], actions: [:])
        try require(firstFailed.registeredBindings[.screenshot] == [alternate], "A failed primary disabled the second slot")
        firstFailedBackend.blocked = []; firstFailed.retryUnavailableBindings()
        try require(firstFailed.registeredBindings[.screenshot] == [primary, alternate], "Retry changed the saved slot order")
        let duplicatesBackend = FakeHotKeyBackend(), duplicates = HotKeys(backend: duplicatesBackend)
        duplicatesBackend.blocked = [alternate]
        var duplicateFired: [ShortcutAction] = []
        duplicates.installBindings([.screenshot: [primary], .scroll: [primary], .text: [alternate]],
            actions: [.screenshot: { duplicateFired.append(.screenshot) }, .scroll: { duplicateFired.append(.scroll) },
                      .text: { duplicateFired.append(.text) }])
        duplicatesBackend.blocked = []; duplicatesBackend.attempts = []; duplicates.retryUnavailableBindings()
        try require(duplicates.registeredBindings[.screenshot] == [primary] && duplicates.registeredBindings[.scroll] == []
                    && duplicates.unavailable == [ShortcutAction.scroll.legacyID] && duplicates.registeredBindings[.text] == [alternate]
                    && duplicatesBackend.attempts == [alternate], "Retry assigned a duplicate key to two actions or blocked an independent recovery")
        duplicatesBackend.emit(primary); duplicatesBackend.emit(alternate)
        try require(duplicateFired == [.screenshot, .text], "Retry changed the owner of a migrated duplicate key")
    }

    @MainActor private static func multipleShortcutEditor() throws {
        let memory = MemoryPreferencesStorage(), store = PreferencesStore(storage: memory)
        let alternate = KeyboardShortcut(keyCode: 122, modifiers: [.option])
        var saved = store.shortcutBindings; saved[.screenshot]?.append(alternate)
        try require(store.setShortcutBindings(saved), "Cannot prepare two saved bindings")
        let backend = FakeHotKeyBackend(), keys = HotKeys(backend: backend)
        backend.blocked = [alternate]; keys.installBindings(saved, actions: [:]); backend.attempts = []
        let editor = ShortcutEditorSession(hotKeys: keys, store: store)
        try require(!editor.hasIssue(.screenshot, index: 0) && editor.hasIssue(.screenshot, index: 1)
                    && !editor.hasBlockingShortcutIssues && editor.message(.screenshot, index: 1).contains("另一组"),
                    "Saved failed alternative was not a local nonblocking warning")
        let replacement = KeyboardShortcut(keyCode: 120, modifiers: [.option])
        editor.startRecording(.scroll); _ = editor.capture(try event(120, [.option]))
        try require(editor.save() && store.shortcutBindings[.screenshot] == saved[.screenshot]
                    && store.shortcutBindings[.scroll] == [replacement] && backend.attempts == [replacement],
                    "A saved unavailable alternative blocked or was retried by another edit")
        let oldStore = store.shortcutBindings, oldActive = keys.registeredBindings, oldWrites = memory.writeCount
        let blockedNew = KeyboardShortcut(keyCode: 99, modifiers: [.option]); backend.blocked.insert(blockedNew)
        editor.startRecording(.screenshot, index: 1); _ = editor.capture(try event(99, [.option]))
        try require(!editor.save() && store.shortcutBindings == oldStore && keys.registeredBindings == oldActive
                    && memory.writeCount == oldWrites, "Failed edited alternative changed saved or live bindings")
        editor.reset(); backend.blocked.remove(alternate); backend.attempts = []
        editor.retryUnavailableBindings()
        try require(backend.attempts == [alternate] && !editor.hasIssue(.screenshot, index: 1)
                    && keys.registeredBindings[.screenshot] == saved[.screenshot], "Home retry did not clear the saved warning")
        editor.startRecording(.screenshot, index: 1)
        _ = editor.capture(try event(UInt16(ShortcutAction.screenshot.defaultShortcut.keyCode), [.option]))
        try require(editor.hasBlockingShortcutIssues && editor.hasIssue(.screenshot, index: 0)
                    && editor.hasIssue(.screenshot, index: 1) && !editor.save(), "Duplicate slots within one action were allowed")
        editor.reset(); editor.removeShortcut(.screenshot, index: 0)
        try require(editor.bindingDraft[.screenshot] == [alternate] && editor.save(), "Removing the primary lost its alternative")
        editor.removeShortcut(.screenshot, index: 0)
        try require(editor.save() && store.shortcutBindings[.screenshot] == [] && keys.registeredBindings[.screenshot] == [],
                    "Removing the last shortcut was rejected")
        editor.startRecording(.screenshot, index: 0); _ = editor.capture(try event(122, [.option]))
        try require(editor.save() && PreferencesStore(storage: memory).shortcutBindings[.screenshot] == [alternate],
                    "An empty action could not regain a binding")
        editor.startRecording(.screenshot, index: 2)
        try require(editor.recordingAction == nil, "A nonexistent third recorder could be started")
    }

    @MainActor private static func correctedMultiSlotIntent() throws {
        let (store, _, keys, backend, editor, _) = try partialBatchFixture()
        let missing = ShortcutAction.subject.defaultShortcut
        editor.startRecording(.screenshot)
        _ = editor.capture(try event(UInt16(missing.keyCode), [.option]))
        try require(editor.hasBlockingShortcutIssues, "A draft duplicate of the saved unavailable key was not detected")
        editor.startRecording(.screenshot); _ = editor.capture(try event(122, [.option]))
        let corrected = KeyboardShortcut(keyCode: 122, modifiers: [.option])
        try require(editor.save() && backend.attempts == [corrected] && store.shortcuts[.screenshot] == corrected
                    && keys.registeredBindings[.subject, default: []].isEmpty,
                    "A corrected draft retained the abandoned key's strict registration intent")

        // Removing a saved owner must not clear an explicit same-chord edit in
        // another slot: that moved key still requires a successful registration.
        editor.startRecording(.text); _ = editor.capture(try event(UInt16(missing.keyCode), [.option]))
        editor.removeShortcut(.subject, index: 0); backend.attempts = []
        try require(!editor.save() && backend.attempts == [missing] && store.shortcuts[.subject] == missing,
                    "Removing a duplicate's saved owner erased another slot's registration intent")
        backend.blocked.remove(missing); backend.attempts = []
        try require(editor.save() && backend.attempts == [missing] && store.shortcutBindings[.subject] == []
                    && keys.registeredBindings[.text] == [missing], "The explicitly moved shortcut could not be repaired")
    }

    @MainActor private static func preferences() throws {
        let memory = MemoryPreferencesStorage()
        let first = PreferencesStore(storage: memory)
        let drawingDefault = AnnotationPreference(width: 3.5)
        for tool in ["箭头", "画笔", "方框", "圆形"] {
            try require(first.annotation(for: tool) == drawingDefault, "Unexpected drawing default for \(tool)")
        }
        try require(first.annotation(for: "贴纸").fontSize == 36
                    && first.annotation(for: "马赛克").mosaicBlockSize == 8
                    && first.annotation(for: "文字").fontSize == 18
                    && first.annotation(for: "序号").numberSize == 24
                    && memory.writeCount == 0, "Initial tool sizes differ or reading defaults writes preferences")
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
        try require(restarted.annotation(for: "圆形") == drawingDefault, "Unconfigured tool inherited another tool")
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
        try require(ShortcutAction.displayOrder == [.screenshot, .scroll, .subject, .record, .text, .pin, .recentContent, .pinRecent]
                    && Set(ShortcutAction.settingsOrder) == Set(ShortcutAction.allCases)
                    && ShortcutAction.settingsOrder.count == ShortcutAction.allCases.count,
                    "Feature display order is incorrect or omits/duplicates an action")
        let memory = MemoryPreferencesStorage()
        let store = PreferencesStore(storage: memory)
        var chosen = ShortcutAction.defaultShortcuts
        chosen[.screenshot] = KeyboardShortcut(keyCode: 122, modifiers: [.command, .shift])
        chosen[.subject] = KeyboardShortcut(keyCode: 28, modifiers: [.control, .option])
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

    @MainActor private static func legacyStorage(_ shortcuts: [ShortcutAction: KeyboardShortcut], layoutVersion: Int? = nil) throws -> MemoryPreferencesStorage {
        struct SavedSnapshot: Encodable {
            let version = 1
            let annotations: [String: AnnotationPreference] = [:]
            let shortcuts: [String: KeyboardShortcut]
            let shortcutLayoutVersion: Int?
        }
        let saved = Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.key.rawValue, $0.value) })
        return MemoryPreferencesStorage(data: try JSONEncoder().encode(SavedSnapshot(shortcuts: saved, shortcutLayoutVersion: layoutVersion)))
    }

    @MainActor private static func legacyShortcuts() throws {
        let oldActions = ShortcutAction.legacyActions
        let oldDefaults = ShortcutAction.legacyDefaultShortcuts
        try require(ShortcutAction.allCases == oldActions + [.recentContent, .pinRecent]
                    && oldActions.map(\.legacyID) == [1, 2, 3, 4, 5, 6, 7]
                    && oldActions.map { oldDefaults[$0]!.keyCode } == [18, 19, 20, 21, 23, 22, 26]
                    && ShortcutAction.recentContent.legacyID == 8 && ShortcutAction.pinRecent.legacyID == 9,
                    "New shortcuts changed legacy IDs or installation priority")
        try require(ShortcutAction.settingsOrder.map { $0.defaultShortcut.keyCode } == [18, 19, 20, 21, 23, 22, 26, 28, 25]
                    && ShortcutAction.settingsOrder.allSatisfy { $0.defaultShortcut.modifiers == [.option] },
                    "New defaults do not follow the visual Option-1 through Option-9 order")

        for count in [5, 6, 7] {
            let fixture = Dictionary(uniqueKeysWithValues: oldActions.prefix(count).map { ($0, oldDefaults[$0]!) })
            let memory = try legacyStorage(fixture)
            let store = PreferencesStore(storage: memory)
            try require(store.shortcuts == ShortcutAction.defaultShortcuts && memory.writeCount == 0,
                        "An unchanged old \(count)-action layout did not adopt the new default order")
            store.setPinRecentCount(7)
            try require(PreferencesStore(storage: memory).shortcuts == ShortcutAction.defaultShortcuts,
                        "Saving a separate setting changed legacy-default migration")
        }

        let oldSix = Dictionary(uniqueKeysWithValues: oldActions.prefix(6).map {
            ($0, KeyboardShortcut(keyCode: oldDefaults[$0]!.keyCode, modifiers: [.control, .option]))
        })
        let oldSixMemory = try legacyStorage(oldSix)
        let upgraded = PreferencesStore(storage: oldSixMemory).shortcuts
        try require(oldSix.allSatisfy { upgraded[$0.key] == $0.value }
                    && upgraded[.togglePins] == oldDefaults[.togglePins]
                    && upgraded[.recentContent] == ShortcutAction.recentContent.defaultShortcut
                    && upgraded[.pinRecent] == ShortcutAction.pinRecent.defaultShortcut && oldSixMemory.writeCount == 0,
                    "Migrating six custom actions replaced old bindings or omitted new actions")

        var previous = oldDefaults
        previous[.screenshot] = ShortcutAction.pinRecent.defaultShortcut
        previous[.pin] = KeyboardShortcut(keyCode: 122, modifiers: [.shift])
        let conflictMemory = try legacyStorage(previous)
        let conflictStore = PreferencesStore(storage: conflictMemory)
        let desired = conflictStore.shortcuts
        try require(previous.allSatisfy { desired[$0.key] == $0.value }
                    && desired[.recentContent] == desired[.togglePins] && desired[.pinRecent] == desired[.screenshot]
                    && conflictMemory.writeCount == 0,
                    "New defaults replaced existing custom bindings")
        let backend = FakeHotKeyBackend(), keys = HotKeys(backend: backend)
        var fired: [ShortcutAction] = []
        let actions = Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { action in
            (action, { fired.append(action) })
        })
        let failures = keys.installShortcuts(desired, actions: actions)
        try require(failures == [.recentContent: .duplicate(.togglePins, .recentContent), .pinRecent: .duplicate(.screenshot, .pinRecent)]
                    && keys.unavailable == [8, 9] && keys.registeredShortcuts == previous
                    && backend.registrations.count == oldActions.count,
                    "A newly added shortcut stole or disabled an existing binding")
        backend.emit(previous[.screenshot]!); backend.emit(previous[.togglePins]!)
        try require(fired == [.screenshot, .togglePins], "Migrated conflicts stole old action callbacks")
        try require(!conflictStore.setShortcuts(desired) && conflictMemory.writeCount == 0,
                    "An unresolved migrated duplicate was persisted")
        var repaired = desired
        repaired[.recentContent] = KeyboardShortcut(keyCode: 26, modifiers: [.control, .option])
        repaired[.pinRecent] = KeyboardShortcut(keyCode: 28, modifiers: [.control, .option])
        try keys.applyShortcuts(repaired).get()
        try require(conflictStore.setShortcuts(repaired) && conflictMemory.writeCount == 1
                    && PreferencesStore(storage: conflictMemory).shortcuts == repaired
                    && keys.unavailable.isEmpty && previous.allSatisfy { keys.registeredShortcuts[$0.key] == $0.value },
                    "Repairing new shortcuts replaced existing bindings or failed to persist")
        backend.emit(repaired[.recentContent]!); backend.emit(repaired[.pinRecent]!)
        try require(fired == [.screenshot, .togglePins, .recentContent, .pinRecent], "New repaired shortcuts lost their action callbacks")
        let encoded = try JSONSerialization.jsonObject(with: conflictMemory.data!) as! [String: Any]
        try require(encoded["shortcutLayoutVersion"] as? Int == 3, "Saving shortcuts omitted the multi-binding layout migration marker")

        // A marked layout must not be mistaken for an untouched old default layout.
        let markedMemory = try legacyStorage(oldDefaults, layoutVersion: 2)
        let marked = PreferencesStore(storage: markedMemory).shortcuts
        try require(oldDefaults.allSatisfy { marked[$0.key] == $0.value } && markedMemory.writeCount == 0,
                    "An already-versioned layout was remapped a second time")

        var fiveCustom = Dictionary(uniqueKeysWithValues: oldActions.prefix(5).map { ($0, oldDefaults[$0]!) })
        fiveCustom[.screenshot] = oldDefaults[.subject]
        let fiveMemory = try legacyStorage(fiveCustom)
        let five = PreferencesStore(storage: fiveMemory).shortcuts
        let fiveKeys = HotKeys(backend: FakeHotKeyBackend())
        let fiveFailures = fiveKeys.installShortcuts(five, actions: [:])
        try require(fiveCustom.allSatisfy { fiveKeys.registeredShortcuts[$0.key] == $0.value }
                    && fiveFailures[.subject] == .duplicate(.screenshot, .subject)
                    && fiveFailures[.recentContent] == .duplicate(.togglePins, .recentContent),
                    "Adding missing legacy/new actions stole an older custom key")

        var missing = previous; missing.removeValue(forKey: .record)
        var invalid = previous; invalid[.pin] = KeyboardShortcut(keyCode: 999, modifiers: [.control])
        var duplicate = previous; duplicate[.scroll] = duplicate[.screenshot]
        var duplicateCurrent = repaired; duplicateCurrent[.subject] = duplicateCurrent[.screenshot]
        for broken in [missing, invalid, duplicate, duplicateCurrent] {
            let brokenMemory = try legacyStorage(broken)
            try require(PreferencesStore(storage: brokenMemory).shortcuts == ShortcutAction.defaultShortcuts
                        && brokenMemory.writeCount == 0,
                        "Migration accepted another malformed shortcut configuration")
        }
    }

    @MainActor private static func batchAndLanguagePreferences() throws {
        let memory = MemoryPreferencesStorage(), store = PreferencesStore(storage: memory)
        try require(store.pinRecentCount == 5 && store.languagePreference == .system && memory.writeCount == 0,
                    "New-store batch count or language defaults are incorrect")
        for invalid in [Int.min, -1, 0, 21, Int.max] { store.setPinRecentCount(invalid) }
        try require(store.pinRecentCount == 5 && memory.writeCount == 0, "Out-of-range batch counts were stored")
        store.setPinRecentCount(1); store.setPinRecentCount(20)
        let originalRuntimeLanguage = AppLocalization.language
        store.setLanguagePreference(.english); store.setAppearancePreference(.dark)
        var shortcuts = ShortcutAction.defaultShortcuts
        shortcuts[.subject] = KeyboardShortcut(keyCode: 122, modifiers: [.control, .option])
        try require(store.setShortcuts(shortcuts), "Cannot persist independent language/count/shortcut settings")
        let writes = memory.writeCount
        let restored = PreferencesStore(storage: memory)
        try require(restored.pinRecentCount == 20 && restored.languagePreference == .english
                    && restored.appearancePreference == .dark && restored.shortcuts == shortcuts
                    && AppLocalization.language == originalRuntimeLanguage && memory.writeCount == writes,
                    "Preference reconstruction lost settings, wrote data, or switched the running interface language")
        restored.setPinRecentCount(20); restored.setLanguagePreference(.english); restored.setAppearancePreference(.dark)
        try require(memory.writeCount == writes, "Unchanged preferences were needlessly persisted")
        restored.setLanguagePreference(.system)
        try require(PreferencesStore(storage: memory).languagePreference == .system
                    && PreferencesStore(storage: memory).shortcuts == shortcuts, "Restoring system language damaged shortcuts")
        for (stored, expected) in [(-20, 1), (0, 1), (21, 20), (999, 20)] {
            let bytes = Data("{\"version\":1,\"annotations\":{},\"shortcuts\":{},\"pinRecentCount\":\(stored)}".utf8)
            let corrupt = MemoryPreferencesStorage(data: bytes)
            try require(PreferencesStore(storage: corrupt).pinRecentCount == expected && corrupt.writeCount == 0,
                        "Persisted batch count did not clamp safely without a read-time write")
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
                    && controller.verificationStatus.contains("patch 的编辑或窗口操作保留"),
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
        editor.startRecording(.subject); _ = editor.capture(try event(UInt16(ShortcutAction.subject.defaultShortcut.keyCode), [.option]))
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
        editor.startRecording(.subject); _ = editor.capture(try event(UInt16(ShortcutAction.subject.defaultShortcut.keyCode), [.option]))
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
        editor.startRecording(.text); _ = editor.capture(try event(UInt16(ShortcutAction.subject.defaultShortcut.keyCode), [.option]))
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
