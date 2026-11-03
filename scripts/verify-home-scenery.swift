import AppKit

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
        print("PASS: home scenery initialization, day/clock/timezone/wake refresh and inactive lifecycle")
    }
}
