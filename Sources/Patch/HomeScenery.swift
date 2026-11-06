// SPDX-FileCopyrightText: 2026 caijyii
// SPDX-License-Identifier: MIT

import AppKit

/// One continuous outdoor scene; the home view supplies the arch, glass and controls.
@MainActor
final class HomeSceneryView: NSView {
    private(set) var season: HomeSeason
    var onSeasonChanged: ((HomeSeason) -> Void)?
    private let dateProvider: () -> Date
    private let timeZoneProvider: () -> TimeZone
    private(set) var nextSeasonRefresh: Date?
    private var seasonTimer: Timer?
    private static let frameInterval: TimeInterval = 1.0 / 12.0
    private var motionRequested = false
    private var motionTimer: Timer?
    private var motionTime: TimeInterval = 0
    private var lastTick: TimeInterval = 0

    override convenience init(frame frameRect: NSRect) {
        self.init(frame: frameRect, dateProvider: Date.init, timeZoneProvider: { .current })
    }

    init(frame frameRect: NSRect, dateProvider: @escaping () -> Date,
         timeZoneProvider: @escaping () -> TimeZone) {
        self.dateProvider = dateProvider
        self.timeZoneProvider = timeZoneProvider
        season = HomeSeason.current(at: dateProvider(), timeZone: timeZoneProvider())
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(false)

        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification] {
            center.addObserver(self, selector: #selector(windowStateChanged(_:)), name: name, object: nil)
        }
        center.addObserver(self, selector: #selector(windowWillClose(_:)),
                           name: NSWindow.willCloseNotification, object: nil)
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            center.addObserver(self, selector: #selector(applicationStateChanged(_:)), name: name, object: nil)
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(accessibilityChanged(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        for name in [NSNotification.Name.NSCalendarDayChanged, .NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            center.addObserver(self, selector: #selector(dateContextChanged(_:)), name: name, object: nil)
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(dateContextChanged(_:)),
            name: NSWorkspace.didWakeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        motionTimer?.invalidate()
        seasonTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The owner controls whether the home experience is active. Window and
    /// accessibility conditions are enforced here even if the owner leaves it on.
    func setMotionActive(_ active: Bool) {
        motionRequested = active
        updateMotion()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        stopMotion()
        stopSeasonTimer()
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateMotion()
    }

    override func viewDidHide() {
        super.viewDidHide()
        stopMotion()
        stopSeasonTimer()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateMotion()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    @objc private func windowStateChanged(_ notification: Notification) {
        guard let changed = notification.object as? NSWindow, changed === window else { return }
        updateMotion()
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        stopMotion()
        stopSeasonTimer()
    }

    @objc private func applicationStateChanged(_ notification: Notification) { updateMotion() }

    @objc private func dateContextChanged(_ notification: Notification) { refreshSeason() }

    /// Re-evaluate wall-clock time independently of animation/accessibility settings.
    func refreshSeason() {
        let now = dateProvider(), timeZone = timeZoneProvider()
        let current = HomeSeason.current(at: now, timeZone: timeZone)
        if current != season {
            season = current
            needsDisplay = true
            onSeasonChanged?(current)
        }
        guard motionRequested, !isHiddenOrHasHiddenAncestor,
              let window, window.isVisible, !window.isMiniaturized else {
            stopSeasonTimer()
            return
        }
        let next = HomeSeason.nextTransition(after: now, timeZone: timeZone)
        guard seasonTimer == nil || nextSeasonRefresh != next else { return }
        stopSeasonTimer()
        nextSeasonRefresh = next
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.seasonTimer = nil
                self?.nextSeasonRefresh = nil
                self?.refreshSeason()
            }
        }
        seasonTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopSeasonTimer() {
        seasonTimer?.invalidate()
        seasonTimer = nil
        nextSeasonRefresh = nil
    }

    @objc private func accessibilityChanged(_ notification: Notification) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            motionTime = 0
            needsDisplay = true
        }
        updateMotion()
    }

    private var permitsMotion: Bool {
        guard motionRequested, !isHiddenOrHasHiddenAncestor,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              NSApp.isActive, let window, window.isVisible, window.isKeyWindow,
              !window.isMiniaturized, window.occlusionState.contains(.visible) else { return false }
        return true
    }

    private func updateMotion() {
        refreshSeason()
        guard permitsMotion else { stopMotion(); return }
        guard motionTimer == nil else { return }
        lastTick = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: Self.frameInterval, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                guard self.permitsMotion else { self.stopMotion(); return }
                let now = ProcessInfo.processInfo.systemUptime
                guard now - self.lastTick >= Self.frameInterval else { return }
                self.motionTime += min(0.25, max(0, now - self.lastTick))
                self.lastTick = now
                self.needsDisplay = true
            }
        }
        timer.tolerance = Self.frameInterval * 0.15
        motionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopMotion() {
        motionTimer?.invalidate()
        motionTimer = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        HomeSceneryArtwork.draw(in: context, bounds: bounds, season: season, dark: dark,
            motionTime: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : motionTime)
    }
}
