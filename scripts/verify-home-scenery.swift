import AppKit

@MainActor private final class AmbientProbeView: NSView {
    var redrawRequests = 0
    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set {
            if newValue { redrawRequests += 1 }
            super.needsDisplay = newValue
        }
    }
}

@main
struct VerifyHomeScenery {
    @MainActor static func main() {
        _ = NSApplication.shared
        let iso = ISO8601DateFormatter()
        var now = iso.date(from: "2026-02-28T15:59:59Z")!
        var zone = TimeZone(identifier: "Asia/Shanghai")!
        let view = HomeSceneryView(frame: NSRect(x: 0, y: 0, width: 720, height: 480),
            dateProvider: { now }, timeZoneProvider: { zone })
        precondition(view.season == .winter, "Initial theme must follow the local date")

        var wallSeason = view.season
        var changes = 0
        view.onSeasonChanged = { wallSeason = $0; changes += 1 }
        now = iso.date(from: "2026-02-28T16:00:00Z")!
        NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
        precondition(view.season == .spring, "A local day change must refresh the theme")

        now = iso.date(from: "2026-06-01T00:30:00Z")!
        zone = TimeZone(identifier: "America/Los_Angeles")!
        NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
        precondition(view.season == .spring, "Timezone changes must use the new local month")
        zone = TimeZone(identifier: "Asia/Shanghai")!
        NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
        precondition(view.season == .summer, "Timezone changes can cross a season boundary")

        now = iso.date(from: "2026-09-01T08:00:00Z")!
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        precondition(view.season == .autumn, "Waking after a season change must refresh the theme")

        now = iso.date(from: "2026-12-01T08:00:00Z")!
        NotificationCenter.default.post(name: .NSSystemClockDidChange, object: nil)
        precondition(view.season == .winter, "Clock adjustments must refresh the theme")
        precondition(view.nextSeasonRefresh == nil, "An invisible home should not schedule refresh work")

        now = iso.date(from: "2027-04-15T08:00:00Z")!
        view.setMotionActive(false)
        precondition(view.season == .spring, "Season updates must not depend on animation being enabled")
        view.setMotionActive(true)
        precondition(view.nextSeasonRefresh == nil, "Detached views should not run timers")
        precondition(wallSeason == .spring && changes == 5, "The wall must follow each season change, without duplicate updates")
        let wall = AmbientProbeView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let image = NSImage(size: wall.bounds.size)
        image.lockFocus()
        WindowAmbientBackground.draw(in: wall)
        image.unlockFocus()
        for name in [NSNotification.Name.NSCalendarDayChanged, .NSSystemClockDidChange,
                     .NSSystemTimeZoneDidChange, NSApplication.didBecomeActiveNotification] {
            wall.redrawRequests = 0
            NotificationCenter.default.post(name: name, object: nil)
            precondition(wall.redrawRequests == 1, "Functional windows must refresh after date/context changes")
        }
        wall.redrawRequests = 0
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        precondition(wall.redrawRequests == 1, "Functional windows must refresh after waking")
        print("PASS: shared ambient backgrounds refresh on day, clock, timezone, activation and wake")
        print("PASS: home scenery initialization, day/clock/timezone/wake refresh and inactive lifecycle")
    }
}
