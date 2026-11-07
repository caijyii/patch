import AppKit
import Darwin

@MainActor private final class OptionsHotKeys: HotKeyBackend {
    func installHandler(_ callback: @escaping (UInt32) -> Void) -> Int32 { 0 }
    func register(_ shortcut: KeyboardShortcut, eventID: UInt32) -> Result<HotKeyToken, HotKeyBackendError> { .success(HotKeyToken(rawValue: UInt64(eventID))) }
    func unregister(_ token: HotKeyToken) -> Int32 { 0 }
    func symbolicShortcuts() -> Result<Set<KeyboardShortcut>, HotKeyBackendError> { .success([]) }
}
@main private struct VerifyHomeOptions {
    @MainActor static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { print("FAIL: \(message)"); exit(1) }
    }
    @MainActor static func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
    @MainActor static func visibleButtons(_ view: NSView) -> [NSButton] {
        all(view).compactMap { $0 as? NSButton }.filter { !$0.isHiddenOrHasHiddenAncestor }
    }
    @MainActor static func render(_ view: NSView, _ name: String) {
        view.needsLayout = true; view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            require(false, "Cannot allocate Home options preview: \(name)"); return
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            require(false, "Cannot encode Home options preview: \(name)"); return
        }
        do {
            try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(name + ".png"))
        } catch {
            require(false, "Cannot save Home options preview \(name): \(error)")
        }
    }
    @MainActor static func permissionLayout(_ page: AppOptionsView, granted: Bool) {
        page.layoutSubtreeIfNeeded()
        let views = all(page)
        let label = views.first { $0.identifier?.rawValue == "options.permission-label" }!
        let state = views.first { $0.identifier?.rawValue == "options.permission-state" } as! NSTextField
        let hint = views.first { $0.identifier?.rawValue == "options.permission-hint" } as! NSTextField
        let button = views.first { $0.identifier?.rawValue == "options.authorize" } as! NSButton
        let control = page.appearanceControl.frame
        require(button.image == nil && button.imagePosition == .noImage, "Settings authorization must remain a text-only button")
        require(abs(state.frame.minY + state.firstBaselineOffsetFromTop - label.frame.minY - label.firstBaselineOffsetFromTop) < 0.01 && !state.frame.intersects(label.frame),
                "Permission label and state are not aligned without overlap")
        require(button.frame.maxX == control.maxX && abs(button.frame.midY - label.frame.midY) <= 1,
                "Authorization button does not stay in the compact permission row")
        require(state.frame.minX == label.frame.maxX + 12 && state.alignment == .left && state.font == languageRestartHint(page).font,
                "Permission state does not share the inline restart-hint style")
        require(hint.frame.minY >= max(button.frame.maxY, label.frame.maxY) && !hint.frame.intersects(button.frame),
                "Permission explanation overlaps its compact authorization row")
        let textSize = (hint.stringValue as NSString).boundingRect(with: CGSize(width: hint.bounds.width, height: 1000),
            options: [.usesLineFragmentOrigin], attributes: [.font: hint.font!])
        require(textSize.height <= hint.bounds.height, "Permission explanation is truncated")
        require(button.isHidden == granted && state.textColor == (granted ? HomeWindowPalette.muted : .systemOrange),
                "Permission status does not use the expected color or button visibility")
    }
    @MainActor static func compactOptionsLayout(_ page: AppOptionsView) {
        page.layoutSubtreeIfNeeded()
        let views = all(page)
        let language = views.first { $0.identifier?.rawValue == "options.language-label" }!
        let hint = languageRestartHint(page)
        let rows = [page.appearanceControl, page.languageControl, page.countControl]
        require(rows[1].frame.minY - rows[0].frame.minY == 44
                && rows[2].frame.minY - rows[1].frame.minY == 44,
                "Language restart guidance leaves an extra vertical gap between settings")
        require(hint.frame.minX >= language.frame.maxX + 12 && hint.frame.maxX <= page.languageControl.frame.minX - 20
                && abs(hint.frame.minY + hint.firstBaselineOffsetFromTop - language.frame.minY - language.firstBaselineOffsetFromTop) < 0.01,
                "Restart guidance must stay alongside the language label")
        require(hint.fittingSize.width <= hint.frame.width && hint.fittingSize.height <= hint.frame.height,
                "Localized inline restart guidance is truncated")
        for view in page.subviews where !view.isHidden {
            require(page.bounds.contains(view.frame), "Compact settings clips a visible control: \(view.identifier?.rawValue ?? "label")")
        }
        require(page.hidePinsControl.frame.maxX == rows[0].frame.maxX
                && abs(page.hidePinsControl.frame.midY - 188) < 0.5,
                "Capture switch must align with the settings right edge and its row")
        let captureLabel = views.first { $0.identifier?.rawValue == "options.hide-pins-label" } as! NSTextField
        require(captureLabel.fittingSize.width <= captureLabel.frame.width && !captureLabel.frame.intersects(page.hidePinsControl.frame),
                "Localized capture label is clipped or overlaps its selector")
        let recordingLabel = views.first { $0.identifier?.rawValue == "options.hide-recording-pins-label" } as! NSTextField
        require(page.hideRecordingPinsControl.frame.maxX == page.hidePinsControl.frame.maxX
                && page.hideRecordingPinsControl.frame.midY - page.hidePinsControl.frame.midY == 44
                && recordingLabel.fittingSize.width <= recordingLabel.frame.width,
                "Recording switch must align with capture switch without clipping its localized label")
        let close = views.first { $0.identifier?.rawValue == "options.close" }!
        let permissionHint = views.first { $0.identifier?.rawValue == "options.permission-hint" }!
        require(close.frame.minY - permissionHint.frame.maxY >= 12,
                "Compact settings content collides with its footer")
    }
    @MainActor static func dropdownConfiguration(_ page: AppOptionsView) {
        for control in [page.appearanceControl, page.languageControl] {
            require(control.pullsDown && !control.usesItemFromMenu,
                    "Settings selector still anchors its menu to the selected item")
            require(control.preferredEdge == (control.isFlipped ? .maxY : .minY),
                    "Settings selector does not prefer its bottom edge")
            require(control.itemArray.allSatisfy { !$0.isHidden && $0.isEnabled },
                    "Pull-down conversion hides or disables a setting option")
            require(control.title == control.selectedItem?.title && control.itemArray.filter { $0.state == .on }.count == 1
                    && control.selectedItem?.state == .on, "Setting title or selected checkmark is stale")
            require(control.accessibilityLabel()?.isEmpty == false && control.accessibilityValue() as? String == control.title,
                    "Settings selector lost its accessible name or current value")
            require(control.acceptsFirstResponder, "Settings selector no longer accepts keyboard focus")
        }
        require(page.appearanceControl.numberOfItems == AppAppearancePreference.allCases.count
                && page.languageControl.numberOfItems == AppLanguagePreference.allCases.count
                && page.countControl.numberOfItems == 20, "Pull-down conversion lost an option or added a dummy row")

    }
    @MainActor static func languageRestartHint(_ page: AppOptionsView) -> NSTextField {
        all(page).compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "options.language-restart-hint" }!
    }
    @MainActor static func verifyRestartHintLifecycle() {
        let originalLanguage = AppLocalization.language
        defer { AppLocalization.language = originalLanguage }
        for (systemLanguages, appLanguages, expectedEnglish) in [(["zh-Hans-CN"], ["en"], false), (["en-US"], ["zh-Hans"], true)] {
            let system = AppLocalization.systemPreferredLanguages(globalLanguages: systemLanguages, fallback: appLanguages)
            require(AppLocalization.resolvesToEnglish(.system, preferredLanguages: system) == expectedEnglish,
                    "Follow System incorrectly inherits the app's language override")
        }
        require(AppLocalization.systemPreferredLanguages(globalLanguages: nil, fallback: ["en"]) == ["en"]
                && AppLocalization.systemPreferredLanguages(globalLanguages: [], fallback: ["zh-Hans"]) == ["zh-Hans"],
                "Missing global languages lost the locale fallback")
        for startup in AppLanguagePreference.allCases {
            let effective: AppLanguagePreference = AppLocalization.resolvesToEnglish(startup) ? .english : .simplifiedChinese
            // Match the app entry point: .system resolves once for the running process.
            AppLocalization.language = effective
            let preferences = PreferencesStore(storage: MemoryPreferencesStorage())
            preferences.setLanguagePreference(startup)
            func newPage() -> AppOptionsView {
                let page = AppOptionsView(preferences: preferences, onBack: {}, onChange: {}, onRequestPermission: {})
                page.frame = CGRect(x: 0, y: 0, width: 752, height: AppOptionsView.preferredContentHeight)
                page.refreshPermissions(granted: false)
                return page
            }
            func choose(_ value: AppLanguagePreference, in page: AppOptionsView) {
                page.languageControl.selectItem(at: AppLanguagePreference.allCases.firstIndex(of: value)!)
                page.languageControl.sendAction(page.languageControl.action, to: page.languageControl.target)
            }
            let page = newPage()
            require(languageRestartHint(page).isHidden, "Unchanged startup language incorrectly requests a restart")
            compactOptionsLayout(page)
            let initialRowFrames = [page.appearanceControl.frame, page.languageControl.frame, page.countControl.frame]
            let alternate: AppLanguagePreference = effective == .english ? .simplifiedChinese : .english
            choose(alternate, in: page)
            require(!languageRestartHint(page).isHidden && languageRestartHint(page).textColor == .systemOrange
                    && AppLocalization.language == effective, "Changing language must show orange restart guidance without changing the current session")
            compactOptionsLayout(page)
            require(initialRowFrames == [page.appearanceControl.frame, page.languageControl.frame, page.countControl.frame],
                    "Showing the restart guidance moves surrounding configuration rows")
            let reopened = newPage()
            require(!languageRestartHint(reopened).isHidden, "Reopening settings lost the pending language restart")
            choose(startup, in: reopened)
            require(languageRestartHint(reopened).isHidden && languageRestartHint(newPage()).isHidden,
                    "Reverting to the startup language retained the restart guidance")
            choose(effective, in: reopened)
            require(languageRestartHint(reopened).isHidden,
                    "An equivalent explicit language requires a restart despite matching the running interface")
            choose(.system, in: reopened)
            require(languageRestartHint(reopened).isHidden == (AppLocalization.resolvesToEnglish(.system) == AppLocalization.isEnglish),
                    "Follow System restart guidance compares stored preferences instead of effective languages")
        }
        print("PASS: restart guidance reflects effective language, survives reopened settings, and hides after reverting")
    }
    @MainActor static func footerAlignment(_ home: HomeWindowController) {
        let content = home.window!.contentView!
        home.showHomePage(); content.layoutSubtreeIfNeeded()
        let homeClose = visibleButtons(content).first { $0.title == L("关闭") }!
        let homeFrame = homeClose.convert(homeClose.bounds, to: content)
        let homeWindowFrame = home.window!.frame
        let homeContentSize = content.bounds.size
        home.showOptions(); content.layoutSubtreeIfNeeded()
        require(content.bounds.height == 48 + AppOptionsView.preferredContentHeight
                && content.bounds.height < homeContentSize.height
                && content.bounds.width == homeContentSize.width
                && abs(home.window!.frame.maxY - homeWindowFrame.maxY) < 0.5,
                "More Settings must shrink the same window while preserving its top edge and width")
        let optionsClose = visibleButtons(content).first { $0.identifier?.rawValue == "options.close" }!
        let optionsBack = visibleButtons(content).first { $0.title == L("返回首页") }!
        let closeFrame = optionsClose.convert(optionsClose.bounds, to: content)
        require(closeFrame.maxX == homeFrame.maxX
                && content.bounds.maxX - closeFrame.maxX == HomeFooterLayout.horizontalInset,
                "Settings Close does not share Home's window-right inset")
        for control in [optionsClose, optionsBack] {
            let frame = control.convert(control.bounds, to: content)
            require(frame.height == homeFrame.height,
                    "Compact settings changed the standard footer button height")
            require(content.bounds.maxY - frame.maxY == HomeFooterLayout.bottomInset,
                    "Settings footer has a different window-bottom inset")
        }
        home.showHomePage(); content.layoutSubtreeIfNeeded()
        require(content.bounds.size == homeContentSize && home.window!.frame == homeWindowFrame,
                "Returning from compact settings did not restore Home's size and position")
        home.showOptions(); content.layoutSubtreeIfNeeded()
    }
    @MainActor static func nativeDropdown(_ control: SettingsSelector) {
        nativeCountDropdown(control)
    }
    @MainActor static func nativeCountDropdown(_ control: SettingsSelector, name: String = "count-list", selectLast: Bool = false, keyboard: Bool = false) {
        let host = control.window!
        host.makeKeyAndOrderFront(nil)
        if keyboard {
            control.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: host.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 125)!)
        } else { control.performClick(nil) }
        guard let popup = control.listPanel else { require(false, "List failed to open"); return }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        let button = host.convertToScreen(control.convert(control.bounds, to: nil))
        require(abs(popup.frame.minX - button.minX) < 0.1 && abs(popup.frame.width - button.width) < 0.1,
                "Selector and list edges do not align")
        let frame = popup.frame
        render(popup.contentView!, "neutral-list-" + (AppLocalization.isEnglish ? "en" : "zh") + "-" + (host.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light"))
        require(control.focusRingType == .none && !control.showsKeyboardFocus, "Mouse/programmatic list activation left a focus ring")
        let rows = all(popup.contentView!).compactMap { $0 as? NSButton }
        rows.last?.scrollToVisible(rows.last!.bounds)
        require(popup.frame == frame && frame.height <= 232, "Scrolling expanded the list")
        guard let screen = host.screen?.visibleFrame else {
            require(false, "Desktop screen unavailable for native selector verification"); return
        }
        if button.minY - screen.minY >= frame.height + 4 {
            require(frame.maxY <= button.minY, "List did not open below")
        } else if screen.maxY - button.maxY >= frame.height + 4 {
            require(frame.minY >= button.maxY, "List did not open above")
        }
        if selectLast { rows.last!.performClick(nil) }
        else {
            popup.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: popup.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!)
        }
        require(control.listPanel == nil, "Selection/Escape did not close the list")
        print("PASS: aligned selector list, fixed scrolling height, selection and dismissal")
    }
    @MainActor static func nativeStatusMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for index in 1...14 { menu.addItem(withTitle: "Menu item \(index)", action: nil, keyEquivalent: "") }
        let controls = StatusBarControls(menu: menu)
        defer { controls.remove() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        var initialFrame: CGRect?, observations = 0
        let timer = Timer(timeInterval: 0.1, repeats: true) { timer in
            MainActor.assumeIsolated {
                let current = controls.menu.accessibilityFrame()
                guard !current.isEmpty else { return }
                if let initialFrame { require(current == initialFrame, "Status menu moved or grew after hovering its top edge") }
                else { initialFrame = current }
                require(current.contains(controls.menu.items.first!.accessibilityFrame())
                        && current.contains(controls.menu.items.last!.accessibilityFrame()),
                        "Status menu unnecessarily clips a menu item despite sufficient screen space")
                if observations == 0, let popup = NSApp.windows.first(where: {
                    $0.isVisible && String(describing: type(of: $0)) == "NSPopupMenuWindow"
                }) {
                    let point = popup.convertPoint(fromScreen: CGPoint(x: current.midX, y: current.maxY - 3))
                    let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: popup.windowNumber,
                        context: nil, eventNumber: 1, clickCount: 0, pressure: 0)!
                    NSApp.postEvent(event, atStart: false)
                }
                observations += 1
                if observations == 3 { timer.invalidate(); controls.menu.cancelTrackingWithoutAnimation() }
            }
        }
        RunLoop.main.add(timer, forMode: .eventTracking); RunLoop.main.add(timer, forMode: .default)
        controls.menuButton.performClick(nil)
        timer.invalidate()
        require(observations == 3, "Native status menu did not complete the hover geometry check")
        require(controls.menuButton.bounds.width == StatusBarControls.buttonWidth && controls.item.menu === controls.menu,
                "Patch unexpectedly exposes an extra Stop icon")
        print("PASS: native status menu shows first/last items and stays at \(initialFrame!) after top-edge hover")
    }
    @MainActor static func main() {
        let captureStorage = MemoryPreferencesStorage()
        let capturePreferences = PreferencesStore(storage: captureStorage)
        require(capturePreferences.hidePinsWhenCapturing && capturePreferences.hidePinsWhenRecording, "New preference must default to hiding pins")
        let capturePage = AppOptionsView(preferences: capturePreferences, onBack: {}, onChange: {}, onRequestPermission: {})
        for index in [1, 0] {
            capturePage.hidePinsControl.state = index == 0 ? .on : .off
            capturePage.hidePinsControl.sendAction(capturePage.hidePinsControl.action, to: capturePage.hidePinsControl.target)
            require(PreferencesStore(storage: captureStorage).hidePinsWhenCapturing == (index == 0),
                    "Capture switch change must persist both values")
        }
        capturePage.hideRecordingPinsControl.state = .off
        capturePage.hideRecordingPinsControl.sendAction(capturePage.hideRecordingPinsControl.action, to: capturePage.hideRecordingPinsControl.target)
        require(!PreferencesStore(storage: captureStorage).hidePinsWhenRecording && capturePreferences.hidePinsWhenCapturing,
                "Recording switch must persist independently of screenshot preference")
        capturePage.hideRecordingPinsControl.state = .on
        capturePage.hideRecordingPinsControl.sendAction(capturePage.hideRecordingPinsControl.action, to: capturePage.hideRecordingPinsControl.target)
        require(PreferencesStore(storage: captureStorage).hidePinsWhenRecording, "Recording switch must persist On")
        let legacyStorage = MemoryPreferencesStorage(data: Data(#"{"version":1,"annotations":{},"shortcuts":{},"pinRecentCount":7}"#.utf8))
        let legacy = PreferencesStore(storage: legacyStorage)
        require(legacy.hidePinsWhenCapturing && legacy.hidePinsWhenRecording && legacy.pinRecentCount == 7, "Existing preferences must migrate without losing values")

        let previewBundle = Bundle.main.bundleIdentifier?.hasPrefix("dev.screenleaf.options-menu-preview") == true
        let preview = previewBundle || CommandLine.arguments.contains("--preview")
        if !preview {
            // macOS can reopen probes without their fixture arguments. Return before creating windows.
            guard (2...3).contains(CommandLine.arguments.count), CommandLine.arguments[1].hasPrefix("/"),
                  CommandLine.arguments.count == 2 || CommandLine.arguments[2] == "--english" else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
                fputs("FAIL: Home options verification timed out\n", stderr)
                exit(1)
            }
        }
        AppLocalization.language = CommandLine.arguments.contains("--english") || (previewBundle && Bundle.main.bundleIdentifier?.hasSuffix(".en") == true)
            ? .english : .simplifiedChinese
        _ = NSApplication.shared
        var granted = false, requests = 0, hasRecent = false
        var launches: [ShortcutAction] = []
        let preferences = PreferencesStore(storage: MemoryPreferencesStorage())
        let home = HomeWindowController(hotKeys: HotKeys(backend: OptionsHotKeys()), store: preferences,
            onSave: {}, onLaunch: { launches.append($0) }, screenPermission: { granted },
            onRequestScreenPermission: { requests += 1; granted = true },
            onOptionsChanged: { NSApp.appearance = preferences.appearancePreference.appearance }, hasRecentContent: { hasRecent })
        defer { home.close(); NSApp.appearance = nil }
        home.showWindow(nil)
        if preview {
            let menu = NSMenu(), appItem = NSMenuItem(), appMenu = NSMenu(title: "Options Preview")
            appMenu.addItem(withTitle: "Quit Preview", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            appItem.submenu = appMenu; menu.addItem(appItem); NSApp.mainMenu = menu
            NSApp.setActivationPolicy(.regular)
            home.showOptions(); NSApp.activate(ignoringOtherApps: true)
            NSApp.run()
            return
        }
        verifyRestartHintLifecycle()
        let originalWindow = home.window!, content = originalWindow.contentView!
        content.layoutSubtreeIfNeeded()
        require(requests == 0, "Opening Home requested screen access")
        let authorization = visibleButtons(content).first { $0.identifier?.rawValue == "home.authorize" }!
        require(authorization.image != nil && authorization.bezelStyle == .rounded, "Authorization button does not use Home's icon-and-title style")
        require(home.allTiles.count == 10 && home.allTiles[4].frame.minY == home.allTiles[0].frame.minY && home.allTiles[5].frame.minY > home.allTiles[0].frame.maxY, "Home is not a five-column two-row grid")
        require(authorization.convert(authorization.bounds, to: content).minY >= 484, "Screen access prompt is still above the window")
        require(!home.tiles[.pinRecent]!.launchButton.isEnabled && home.tiles[.pinRecent]!.shortcutButton.isEnabled, "Empty clipboard history cannot retain an editable shortcut")
        home.tiles[.recentContent]!.launchButton.performClick(nil)
        require(launches == [.recentContent], "Clipboard history pane does not dispatch its action")
        hasRecent = true; home.refreshShortcuts()
        home.tiles[.pinRecent]!.launchButton.performClick(nil)
        require(launches == [.recentContent, .pinRecent], "Batch pin pane does not dispatch its action")
        render(content, "home-permission-light")
        authorization.performClick(nil)
        require(requests == 1 && !visibleButtons(content).contains { $0.identifier?.rawValue == "home.authorize" }, "Granting permission did not refresh the Home prompt")
        granted = false; home.refreshPermissions()
        visibleButtons(content).first { $0.title == "更多设置" }!.performClick(nil)
        require(home.isShowingOptions && home.window === originalWindow, "Settings creates a second window")
        require(!visibleButtons(content).contains { $0.title == "截图" }, "Hidden Home launch controls remain visible on settings page")
        let page = all(content).compactMap { $0 as? AppOptionsView }.first!
        let labels = all(page).compactMap { $0 as? NSTextField }.map(\.stringValue)
        require(!labels.contains(L("更多设置")) && !labels.contains(RecentContentPresentation.historyExplanation),
                "Settings repeats its title or includes clipboard retention details")
        require(originalWindow.title == L("Patch · 更多设置"), "Removing the body heading removed the native settings title")
        let popups = all(page).compactMap { $0 as? NSPopUpButton }
        require(popups.count == 3 && popups.allSatisfy { $0 is SettingsSelector },
                "Settings must expose appearance, language, bounded batch pin count and capture visibility")
        dropdownConfiguration(page); footerAlignment(home); compactOptionsLayout(page)
        nativeDropdown(page.appearanceControl)
        nativeDropdown(page.languageControl)
        nativeCountDropdown(page.countControl, selectLast: true)
        require(preferences.pinRecentCount == 20 && home.tiles[.pinRecent]!.launchButton.title == preferences.pinRecentTitle,
                "Choosing row 20 did not immediately save the count and update Home")
        let savedFrame = originalWindow.frame
        let selectorFrame = originalWindow.convertToScreen(page.appearanceControl.convert(page.appearanceControl.bounds, to: nil))
        var lowerFrame = savedFrame
        lowerFrame.origin.y += originalWindow.screen!.visibleFrame.minY + 8 - selectorFrame.minY
        originalWindow.setFrame(lowerFrame, display: true)
        nativeDropdown(page.appearanceControl)
        originalWindow.setFrame(savedFrame, display: true)
        let countFrame = originalWindow.convertToScreen(page.countControl.convert(page.countControl.bounds, to: nil))
        var bottomFrame = savedFrame
        bottomFrame.origin.y += originalWindow.screen!.visibleFrame.minY + 8 - countFrame.minY
        originalWindow.setFrame(bottomFrame, display: true)
        nativeCountDropdown(page.countControl, name: "count-list-above", keyboard: true)
        originalWindow.setFrame(savedFrame, display: true)
        nativeStatusMenu()
        for mode in [AppAppearancePreference.light, .dark] {
            page.appearanceControl.menu!.performActionForItem(at: AppAppearancePreference.allCases.firstIndex(of: mode)!)
            require(preferences.appearancePreference == mode, "Appearance change was not saved")
            render(content, "options-\(mode.rawValue)")
            nativeDropdown(page.languageControl)
            permissionLayout(page, granted: false)
            compactOptionsLayout(page)
            dropdownConfiguration(page)
            require(content.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == (mode == .dark ? .darkAqua : .aqua), "The current settings page did not apply appearance immediately")
            let selectors: [NSControl] = popups + [page.countControl]
            require(selectors.allSatisfy { $0.frame.width == page.appearanceControl.frame.width
                && $0.frame.height == page.appearanceControl.frame.height
                && $0.frame.maxX == page.appearanceControl.frame.maxX }, "Settings dropdown sizes or right edges differ")
            for control in visibleButtons(content) {
                require(content.bounds.contains(control.convert(control.bounds, to: content)), "A settings control is clipped")
            }
            home.showHomePage(); render(content, "home-\(mode.rawValue)")
            home.showOptions()
        }
        page.countControl.selectItem(at: 16)
        page.countControl.sendAction(page.countControl.action, to: page.countControl.target)
        require(preferences.pinRecentCount == 17 && home.tiles[.pinRecent]!.launchButton.title == preferences.pinRecentTitle, "Batch count change did not refresh Home")
        page.languageControl.menu!.performActionForItem(at: AppLanguagePreference.allCases.firstIndex(of: .english)!)
        dropdownConfiguration(page)
        require(preferences.languagePreference == .english && AppLocalization.language == .simplifiedChinese, "Language choice did not persist or changed the active session unexpectedly")
        require(!languageRestartHint(page).isHidden && languageRestartHint(page).textColor == .systemOrange,
                "Settings language change did not show orange restart guidance")
        visibleButtons(content).first { $0.identifier?.rawValue == "options.authorize" }!.performClick(nil)
        require(requests == 2 && !visibleButtons(content).contains { $0.identifier?.rawValue == "options.authorize" }, "Settings authorization did not update")
        permissionLayout(page, granted: true)
        compactOptionsLayout(page)
        visibleButtons(content).first { $0.title == "返回首页" }!.performClick(nil)
        require(!home.isShowingOptions && visibleButtons(content).contains { $0.title == "截图" }, "Return did not restore Home")
        home.showOptions()
        require(!languageRestartHint(page).isHidden, "Returning to settings cleared the pending language restart")
        let closeSettings = visibleButtons(content).first { $0.identifier?.rawValue == "options.close" }!
        let backSettings = visibleButtons(content).first { $0.title == "返回首页" }!
        let closeFrame = closeSettings.convert(closeSettings.bounds, to: content)
        let backFrame = backSettings.convert(backSettings.bounds, to: content)
        require(closeFrame.minX > content.bounds.midX && closeFrame.minY > content.bounds.height - 70 && backFrame.maxX < closeFrame.minX && backFrame.minY == closeFrame.minY, "Settings Back and Close are not bottom right")
        closeSettings.performClick(nil)
        require(!originalWindow.isVisible && NSApp.windows.contains(originalWindow), "Settings Close did not preserve the reusable Home window")
        home.showHomePage(); home.showWindow(nil)
        require(originalWindow.isVisible, "Settings Close prevented Home reopening")
        print("PASS: five-column Home, batch controls, same-window settings, bottom permissions and reusable Close")

        // Exercise the actual pane drawing branches without touching the user's accessibility settings.
        var reduced = false
        let tile = HomeFeatureTile(action: .screenshot, reducedTransparency: { reduced })
        tile.appearance = NSAppearance(named: .aqua)
        tile.frame = CGRect(x: 0, y: 0, width: 240, height: 180)
        let window = NSWindow(contentRect: tile.frame, styleMask: [.titled], backing: .buffered, defer: false)
        let background = NSView(frame: tile.frame); background.wantsLayer = true
        background.layer?.backgroundColor = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 1).cgColor
        background.addSubview(tile); window.contentView = background; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        tile.resetInteraction(); tile.layoutSubtreeIfNeeded()
        require(abs((tile.surface.backgroundColor?.alpha ?? 0) - 0.64) < 0.001, "Ordinary pane is unexpectedly opaque")
        render(background, "glass-translucent")
        let normal = background.bitmapImageRepForCachingDisplay(in: background.bounds)!
        background.cacheDisplay(in: background.bounds, to: normal)
        let normalColor = normal.colorAt(x: 15, y: 15)!.usingColorSpace(.sRGB)!
        reduced = true; tile.resetInteraction()
        require(tile.surface.backgroundColor?.alpha == 1, "Reduced transparency is not respected")
        render(background, "glass-reduced-transparency")
        let opaque = background.bitmapImageRepForCachingDisplay(in: background.bounds)!
        background.cacheDisplay(in: background.bounds, to: opaque)
        let opaqueColor = opaque.colorAt(x: 15, y: 15)!.usingColorSpace(.sRGB)!
        require(opaqueColor.redComponent > normalColor.redComponent + 0.1, "Rendered reduced-transparency pane did not replace the visible background")
        reduced = false; tile.resetInteraction()
        require(abs((tile.surface.backgroundColor?.alpha ?? 0) - 0.64) < 0.001, "Changing accessibility state leaves stale opaque glass")
        tile.appearance = NSAppearance(named: .darkAqua); tile.resetInteraction()
        let dark = NSColor(cgColor: tile.surface.backgroundColor!)!.usingColorSpace(.sRGB)!
        require(abs(dark.redComponent - dark.greenComponent) < 0.005 && abs(dark.greenComponent - dark.blueComponent) < 0.005, "Night glass retains a green cast")
        tile.effectiveAppearance.performAsCurrentDrawingAppearance {
            let edge = HomeWindowPalette.edge.usingColorSpace(.sRGB)!
            require(edge.redComponent > edge.greenComponent && edge.greenComponent > edge.blueComponent, "Night window edges lack warm light")
            let background = HomeWindowPalette.background.usingColorSpace(.sRGB)!
            require(background.redComponent > 0.12 && abs(background.redComponent - background.blueComponent) < 0.005, "Night room has a full-frame yellow tint or remains too dim")
        }
        print("PASS: glass alpha, state refresh, neutral room and glass with warm window edges")
        AppLocalization.language = .english
        let english = HomeWindowController(hotKeys: HotKeys(backend: OptionsHotKeys()), store: preferences,
            onSave: {}, onLaunch: { _ in }, screenPermission: { false })
        english.showWindow(nil)
        render(english.window!.contentView!, "home-english-dark")
        let englishContent = english.window!.contentView!
        let footer = visibleButtons(englishContent).filter { $0.convert($0.bounds, to: englishContent).minY >= 484 }
        require(footer.count == 4, "English Home footer settings, permission, reset or close action is missing")
        for (index, control) in footer.enumerated() {
            require(control.bounds.width >= control.fittingSize.width, "An English Home footer caption is truncated: \(control.title)")
            let frame = control.convert(control.bounds, to: englishContent)
            require(englishContent.bounds.contains(frame), "An English Home footer exceeds the window")
            for other in footer.dropFirst(index + 1) {
                require(!frame.intersects(other.convert(other.bounds, to: englishContent)), "English Home footer actions overlap")
            }
        }
        let permissionNote = all(englishContent).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "home.permission-status" }!
        require(permissionNote.textColor == .systemOrange && !permissionNote.isHiddenOrHasHiddenAncestor, "Missing permission message lost its orange emphasis")
        let permissionFrame = permissionNote.convert(permissionNote.bounds, to: englishContent)
        require(englishContent.bounds.contains(permissionFrame) && footer.allSatisfy { !permissionFrame.intersects($0.convert($0.bounds, to: englishContent)) }, "English permission text overlaps footer controls")
        require(english.tiles[.togglePins]!.launchButton.title == L("隐藏全部贴图"), "Pin visibility caption was shortened")
        let permissionTextSize = (permissionNote.stringValue as NSString).boundingRect(with: CGSize(width: permissionNote.bounds.width, height: 1000), options: [.usesLineFragmentOrigin], attributes: [.font: permissionNote.font!])
        require(permissionTextSize.height <= permissionNote.bounds.height, "English permission message is truncated vertically")
        english.beginEditing(.screenshot)
        let duplicateEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .option, timestamp: 0,
            windowNumber: english.window!.windowNumber, context: nil, characters: "2", charactersIgnoringModifiers: "2", isARepeat: false, keyCode: 19)!
        _ = english.window!.performKeyEquivalent(with: duplicateEvent)
        require(english.isEditing && english.editor.hasIssue(.screenshot), "Cannot prepare English shortcut conflict")
        render(englishContent, "home-english-conflict")
        let conflict = all(englishContent).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "home.shortcut-status" }!
        let conflictFrame = conflict.convert(conflict.bounds, to: englishContent)
        require(!conflict.isHiddenOrHasHiddenAncestor && permissionNote.isHiddenOrHasHiddenAncestor, "Conflict and permission messages collide")
        require(visibleButtons(englishContent).filter { $0.convert($0.bounds, to: englishContent).minY >= 484 }.allSatisfy {
            !conflictFrame.intersects($0.convert($0.bounds, to: englishContent)) && $0.bounds.width >= $0.fittingSize.width
        }, "English conflict overlaps an edit action or truncates its caption")
        english.cancelEditing()
        english.showOptions(); render(english.window!.contentView!, "options-english-dark")
        let englishPage = all(english.window!.contentView!).compactMap { $0 as? AppOptionsView }.first!
        permissionLayout(englishPage, granted: false)
        compactOptionsLayout(englishPage)
        dropdownConfiguration(englishPage); footerAlignment(english)
        for control in visibleButtons(english.window!.contentView!) {
            require(english.window!.contentView!.bounds.contains(control.convert(control.bounds, to: english.window!.contentView!)), "An English setting control is clipped")
            require(control.bounds.width >= control.fittingSize.width, "An English setting caption is truncated")
        }
        english.close(); AppLocalization.language = .simplifiedChinese
        print("PASS: language choice persists for restart; English Home and settings render without clipped controls")
        print("PASS: Home options verification completed")
    }
}
