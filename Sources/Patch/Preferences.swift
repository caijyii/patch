// SPDX-FileCopyrightText: 2026 caijyii
// SPDX-License-Identifier: MIT

import Foundation
import AppKit

/// Annotation sizes are stored in screen points, independent of display scale.
struct AnnotationPreference: Codable, Equatable {
    var colorID: Int = 0
    var width: Double = 3
    var fontSize: Double = 18
    var numberSize: Double = 24
    var mosaicBlockSize: Double = 12

    var validated: AnnotationPreference {
        var result = self
        let defaults = AnnotationPreference()
        if !(0..<5).contains(colorID) { result.colorID = defaults.colorID }
        if !width.isFinite || !(0.5...40).contains(width) { result.width = defaults.width }
        if !fontSize.isFinite || !(8...256).contains(fontSize) { result.fontSize = defaults.fontSize }
        if !numberSize.isFinite || !(8...256).contains(numberSize) { result.numberSize = defaults.numberSize }
        if !mosaicBlockSize.isFinite || !(1...128).contains(mosaicBlockSize) { result.mosaicBlockSize = defaults.mosaicBlockSize }
        return result
    }
}

struct ShortcutModifiers: OptionSet, Codable, Hashable {
    let rawValue: UInt32

    static let command = ShortcutModifiers(rawValue: 1 << 0)
    static let control = ShortcutModifiers(rawValue: 1 << 1)
    static let option = ShortcutModifiers(rawValue: 1 << 2)
    static let shift = ShortcutModifiers(rawValue: 1 << 3)
    static let supported: ShortcutModifiers = [.command, .control, .option, .shift]
}

struct KeyboardShortcut: Codable, Hashable {
    var keyCode: UInt32
    var modifiers: ShortcutModifiers

    var isValid: Bool {
        Self.keyNames[keyCode] != nil
            && modifiers.rawValue & ~ShortcutModifiers.supported.rawValue == 0
            && (!modifiers.intersection([.command, .control, .option]).isEmpty
                || (modifiers == [.shift] && Self.shiftOnlyKeyCodes.contains(keyCode)))
    }

    var invalidReason: String? {
        guard !isValid else { return nil }
        if modifiers == [.shift], Self.keyNames[keyCode] != nil {
            return L("这个 Shift 组合会影响日常输入，请加上 ⌘、⌃ 或 ⌥。")
        }
        return L("请使用修饰键加一个按键；Shift 可单独配合功能键或方向键。")
    }

    static let shiftOnlyKeyCodes: Set<UInt32> = [
        64, 79, 80, 90, 96, 97, 98, 99, 100, 101, 103, 105, 106, 107, 109, 111, 113,
        115, 116, 118, 119, 120, 121, 122, 123, 124, 125, 126
    ]

    var displayString: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        let key = Self.keyNames[keyCode] ?? LF("键 %d", keyCode)
        return result + (AppLocalization.isEnglish && key.hasPrefix("数字键 ") ? key.replacingOccurrences(of: "数字键 ", with: "Num ") : L(key))
    }

    /// Policy is separate from structural validity so previously saved bindings remain visible.
    var isApplicationReserved: Bool {
        // The screenshot view handles Command-C/S/Z regardless of additional modifiers.
        if modifiers.contains(.command), [UInt32(8), 1, 6].contains(keyCode) { return true }
        // Cut, paste, select all, quit, settings, close, minimize and hide.
        if modifiers == [.command], [UInt32(7), 9, 0, 12, 43, 13, 46, 4].contains(keyCode) { return true }
        // Native close-all-windows and hide-other-applications commands.
        if modifiers == [.command, .option], [UInt32(13), 4].contains(keyCode) { return true }
        return false
    }

    // Virtual key codes, rather than translated characters, are what Carbon registers.
    // Escape, Tab and Delete remain available for cancelling/navigating the recorder.
    static let keyNames: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        10: "§", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
        27: "−", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        36: "↩", 37: "L", 38: "J", 39: "′", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "N", 46: "M", 47: ".", 49: "空格", 50: "`",
        64: "F17", 65: "数字键 .", 67: "数字键 *", 69: "数字键 +", 71: "数字键清除", 75: "数字键 /",
        76: "⌤", 78: "数字键 −", 79: "F18", 80: "F19", 81: "数字键 =", 82: "数字键 0", 83: "数字键 1",
        84: "数字键 2", 85: "数字键 3", 86: "数字键 4", 87: "数字键 5", 88: "数字键 6",
        89: "数字键 7", 90: "F20", 91: "数字键 8", 92: "数字键 9",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        105: "F13", 106: "F16", 107: "F14", 109: "F10", 111: "F12", 113: "F15",
        115: "Home", 116: "Page Up", 118: "F4", 119: "End", 120: "F2", 121: "Page Down",
        122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑"
    ]
}

enum ShortcutAction: String, CaseIterable, Codable, Hashable {
    case screenshot, scroll, text, pin, record, subject, togglePins, recentContent, pinRecent

    /// Presentation order is independent of legacy hotkey installation priority.
    static let displayOrder: [ShortcutAction] = [.screenshot, .scroll, .subject, .record, .text, .pin, .recentContent, .pinRecent]

    static let settingsOrder = displayOrder + [ShortcutAction.togglePins]

    var title: String {
        switch self {
        case .screenshot: return L("截图")
        case .scroll: return L("长截图")
        case .text: return L("提取文字")
        case .pin: return L("贴图")
        case .record: return L("录屏")
        case .subject: return L("主体截图")
        case .togglePins: return L("显示／隐藏全部贴图")
        case .recentContent: return L("剪贴记录")
        case .pinRecent: return L("批量贴出")
        }
    }

    var legacyID: UInt32 {
        switch self {
        case .screenshot: return 1
        case .scroll: return 2
        case .text: return 3
        case .pin: return 4
        case .record: return 5
        case .subject: return 6
        case .togglePins: return 7
        case .recentContent: return 8
        case .pinRecent: return 9
        }
    }

    init?(legacyID: UInt32) {
        guard let action = Self.allCases.first(where: { $0.legacyID == legacyID }) else { return nil }
        self = action
    }

    var defaultShortcut: KeyboardShortcut {
        let keyCodes: [UInt32] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        return KeyboardShortcut(keyCode: keyCodes[Self.settingsOrder.firstIndex(of: self)!], modifiers: [.option])
    }

    /// Legacy IDs remain registration identities, independent of visual order and defaults.
    static let legacyActions: [ShortcutAction] = [.screenshot, .scroll, .text, .pin, .record, .subject, .togglePins]
    static var legacyDefaultShortcuts: [ShortcutAction: KeyboardShortcut] {
        let codes: [UInt32] = [18, 19, 20, 21, 23, 22, 26]
        return Dictionary(uniqueKeysWithValues: zip(legacyActions, codes).map { ($0.0, KeyboardShortcut(keyCode: $0.1, modifiers: [.option])) })
    }

    static var defaultShortcuts: [ShortcutAction: KeyboardShortcut] {
        Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.defaultShortcut) })
    }
}

protocol PreferencesStorage: AnyObject {
    func read() -> Data?
    func write(_ data: Data)
}

final class UserDefaultsPreferencesStorage: PreferencesStorage {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "patch.preferences.v1") {
        self.defaults = defaults
        self.key = key
    }

    func read() -> Data? { defaults.data(forKey: key) }
    func write(_ data: Data) { defaults.set(data, forKey: key) }
    func setPreferredLanguage(_ language: AppLanguagePreference) {
        if language == .system { defaults.removeObject(forKey: "AppleLanguages") }
        else { defaults.set([language.rawValue], forKey: "AppleLanguages") }
    }
}

/// No UserDefaults domain is touched by tests using this storage.
final class MemoryPreferencesStorage: PreferencesStorage {
    private(set) var data: Data?
    private(set) var writeCount = 0

    init(data: Data? = nil) { self.data = data }
    func read() -> Data? { data }
    func write(_ data: Data) { self.data = data; writeCount += 1 }
}

enum AppAppearancePreference: String, Codable, CaseIterable {
    case system, light, dark
    var title: String { switch self { case .system: return L("跟随系统"); case .light: return L("浅色"); case .dark: return L("深色") } }
    var appearance: NSAppearance? { switch self { case .system: return nil; case .light: return NSAppearance(named: .aqua); case .dark: return NSAppearance(named: .darkAqua) } }
}

@MainActor
final class PreferencesStore {
    static let shared = PreferencesStore(storage: UserDefaultsPreferencesStorage())

    private struct Snapshot: Codable {
        var version = 1
        var appearance: AppAppearancePreference?
        var language: AppLanguagePreference?
        var pinRecentCount: Int?
        var shortcutLayoutVersion: Int?
        var stickerOrder: [String]?
        var annotations: [String: AnnotationPreference] = [:]
        var shortcuts: [String: KeyboardShortcut] = [:]
        var shortcutBindings: [String: [KeyboardShortcut]]?
    }

    private let storage: PreferencesStorage
    private var snapshot: Snapshot

    init(storage: PreferencesStorage) {
        self.storage = storage
        if let data = storage.read(), let decoded = try? JSONDecoder().decode(Snapshot.self, from: data), decoded.version == 1 {
            snapshot = decoded
        } else { snapshot = Snapshot() }
    }

    var appearancePreference: AppAppearancePreference { snapshot.appearance ?? .system }
    var languagePreference: AppLanguagePreference { snapshot.language ?? .system }
    var pinRecentCount: Int { min(20, max(1, snapshot.pinRecentCount ?? 5)) }
    var pinRecentTitle: String {
        pinRecentCount == 1 ? L("贴出最近 1 条") : LF("贴出最近 %d 条", pinRecentCount)
    }
    func setPinRecentCount(_ value: Int) {
        guard (1...20).contains(value), value != pinRecentCount else { return }
        snapshot.pinRecentCount = value; persist()
    }
    func setLanguagePreference(_ value: AppLanguagePreference) {
        guard value != languagePreference else { return }
        snapshot.language = value; persist()
        (storage as? UserDefaultsPreferencesStorage)?.setPreferredLanguage(value)
    }
    func setAppearancePreference(_ value: AppAppearancePreference) {
        guard value != appearancePreference else { return }
        snapshot.appearance = value; persist()
    }

    static let stickerOrderDidChange = Notification.Name("PatchStickerOrderDidChange")

    /// Stable identifiers keep reordering separate from the current drawing selection.
    func orderedStickerIdentifiers(defaults: [String], canonicalize: (String) -> String = { $0 }) -> [String] {
        Self.normalizedStickerOrder(snapshot.stickerOrder ?? [], defaults: defaults, canonicalize: canonicalize)
    }
    func setStickerOrder(_ identifiers: [String], defaults: [String], canonicalize: (String) -> String = { $0 }) {
        let normalized = Self.normalizedStickerOrder(identifiers, defaults: defaults, canonicalize: canonicalize)
        guard normalized != orderedStickerIdentifiers(defaults: defaults, canonicalize: canonicalize) else { return }
        snapshot.stickerOrder = normalized == defaults ? nil : normalized
        persist()
        NotificationCenter.default.post(name: Self.stickerOrderDidChange, object: self)
    }
    private static func normalizedStickerOrder(_ identifiers: [String], defaults: [String], canonicalize: (String) -> String) -> [String] {
        let available = Set(defaults)
        var seen = Set<String>()
        var result = identifiers.map(canonicalize).filter { available.contains($0) && seen.insert($0).inserted }
        // Keep the relative order of saved items. A newly added pattern belongs
        // beside its default neighbour, rather than after every unrelated group.
        for (index, identifier) in defaults.enumerated() where seen.insert(identifier).inserted {
            if let previous = defaults[..<index].reversed().first(where: { result.contains($0) }),
               let position = result.firstIndex(of: previous) {
                result.insert(identifier, at: position + 1)
            } else if let next = defaults.dropFirst(index + 1).first(where: { result.contains($0) }),
                      let position = result.firstIndex(of: next) {
                result.insert(identifier, at: position)
            } else { result.append(identifier) }
        }
        return result
    }

    func annotation(for tool: String) -> AnnotationPreference {
        if let saved = snapshot.annotations[tool] { return saved.validated }
        var defaults = AnnotationPreference()
        switch tool {
        case "箭头", "画笔", "方框", "圆形": defaults.width = 3.5
        case "贴纸": defaults.fontSize = 36
        case "马赛克": defaults.mosaicBlockSize = 8
        default: break
        }
        return defaults
    }

    /// Call only after the user changes a setting, never when selecting an existing object.
    func setAnnotation(_ preference: AnnotationPreference, for tool: String) {
        let preference = preference.validated
        guard snapshot.annotations[tool] != preference else { return }
        snapshot.annotations[tool] = preference
        persist()
    }

    var shortcuts: [ShortcutAction: KeyboardShortcut] { shortcutBindings.compactMapValues(\.first) }

    var shortcutBindings: [ShortcutAction: [KeyboardShortcut]] {
        guard let saved = snapshot.shortcutBindings else { return legacyShortcuts.mapValues { [$0] } }
        var result: [ShortcutAction: [KeyboardShortcut]] = [:]
        var seen = Set<KeyboardShortcut>()
        for action in ShortcutAction.allCases {
            // An explicit empty array disables only this action's hotkeys.
            let values = saved[action.rawValue] ?? [action.defaultShortcut]
            guard values.count <= 2, values.allSatisfy(\.isValid),
                  values.allSatisfy({ seen.insert($0).inserted }) else {
                return ShortcutAction.defaultShortcuts.mapValues { [$0] }
            }
            result[action] = values
        }
        return result
    }

    private var legacyShortcuts: [ShortcutAction: KeyboardShortcut] {
        if snapshot.shortcuts.isEmpty { return ShortcutAction.defaultShortcuts }
        let isLegacy = (snapshot.shortcutLayoutVersion ?? 1) < 2
        let legacyDefaults = ShortcutAction.legacyDefaultShortcuts
        let savedActions = Set(snapshot.shortcuts.keys.compactMap(ShortcutAction.init(rawValue:)))
        let oldestActions = Set(ShortcutAction.legacyActions.prefix(5))
        if isLegacy, oldestActions.isSubset(of: savedActions), savedActions.isSubset(of: Set(ShortcutAction.legacyActions)),
           savedActions.count == snapshot.shortcuts.count,
           savedActions.allSatisfy({ snapshot.shortcuts[$0.rawValue] == legacyDefaults[$0] }) {
            // Only an entirely unchanged old layout adopts the new reading order.
            return ShortcutAction.defaultShortcuts
        }
        let missingDefaults = Set([ShortcutAction.subject, .togglePins, .recentContent, .pinRecent].filter { snapshot.shortcuts[$0.rawValue] == nil })
        var result: [ShortcutAction: KeyboardShortcut] = [:]
        for action in ShortcutAction.allCases {
            if missingDefaults.contains(action) {
                result[action] = isLegacy ? (legacyDefaults[action] ?? action.defaultShortcut) : action.defaultShortcut
                continue
            }
            guard let shortcut = snapshot.shortcuts[action.rawValue], shortcut.isValid else {
                return ShortcutAction.defaultShortcuts
            }
            result[action] = shortcut
        }
        if !missingDefaults.isEmpty {
            let existing = result.filter { !missingDefaults.contains($0.key) }
            guard Set(existing.values).count == existing.count else { return ShortcutAction.defaultShortcuts }
            // Existing actions register first. A new default conflicting with a custom
            // binding is reported for repair without stealing the existing shortcut.
            return result
        }
        return Set(result.values).count == result.count ? result : ShortcutAction.defaultShortcuts
    }

    /// HotKeys must successfully apply this configuration before it is persisted.
    @discardableResult
    func setShortcuts(_ shortcuts: [ShortcutAction: KeyboardShortcut]) -> Bool {
        guard shortcuts.count == ShortcutAction.allCases.count,
              ShortcutAction.allCases.allSatisfy({ shortcuts[$0]?.isValid == true }),
              Set(shortcuts.values).count == shortcuts.count else { return false }
        return setShortcutBindings(shortcuts.mapValues { [$0] })
    }

    @discardableResult
    func setShortcutBindings(_ bindings: [ShortcutAction: [KeyboardShortcut]]) -> Bool {
        let values = bindings.values.flatMap { $0 }
        guard bindings.count == ShortcutAction.allCases.count,
              ShortcutAction.allCases.allSatisfy({ bindings[$0] != nil && bindings[$0]!.count <= 2 }),
              values.allSatisfy(\.isValid), Set(values).count == values.count else { return false }
        let encoded = Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
        guard snapshot.shortcutBindings != encoded || snapshot.shortcutLayoutVersion != 3 else { return true }
        snapshot.shortcutBindings = encoded
        snapshot.shortcuts = encoded.compactMapValues(\.first)
        snapshot.shortcutLayoutVersion = 3
        persist()
        return true
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(snapshot) { storage.write(data) }
    }
}

/// Semantic colors resolve against each view's effective appearance, including manual overrides.
enum AppTheme {
    static func color(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
}
