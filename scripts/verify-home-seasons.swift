import Foundation
import Darwin

private struct SeasonVerificationFailure: Error, CustomStringConvertible {
    let description: String
}

@main
enum HomeSeasonVerification {
    private static var checks = 0
    private static let zones = ["UTC", "Asia/Shanghai", "America/Los_Angeles"]
        .map { TimeZone(identifier: $0)! }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw SeasonVerificationFailure(description: message) }
        checks += 1
    }

    private static func localDate(_ year: Int, _ month: Int, _ day: Int = 1,
                                  _ hour: Int = 0, _ minute: Int = 0,
                                  in zone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: year, month: month, day: day,
                                                  hour: hour, minute: minute))!
    }

    static func main() {
        do {
            if CommandLine.arguments.contains("--expect-hebrew-calendar") {
                try require(Calendar.current.identifier == .hebrew,
                            "The non-Gregorian run must actually use a Hebrew user calendar")
            }
            try allMonths()
            try exactBoundaries()
            try timeZoneDifferences()
            try daylightSavingAndYearRollover()
            print("PASS: \(checks) home season checks; user calendar: \(Calendar.current.identifier)")
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }

    private static func allMonths() throws {
        let expected: [HomeSeason] = [.winter, .winter, .spring, .spring, .spring, .summer,
                                     .summer, .summer, .autumn, .autumn, .autumn, .winter]
        try require(Set(HomeSeason.allCases.map(\.rawValue)) == Set(["spring", "summer", "autumn", "winter"]),
                    "The model must expose exactly the four built-in themes")
        for zone in zones {
            for (index, season) in expected.enumerated() {
                let date = localDate(2026, index + 1, 15, 12, in: zone)
                try require(HomeSeason.current(at: date, timeZone: zone) == season,
                            "Month \(index + 1) has the wrong season in \(zone.identifier)")
                let transition = HomeSeason.nextTransition(after: date, timeZone: zone)
                try require(transition > date, "The next transition must always be strictly future")
                try require(HomeSeason.current(at: transition, timeZone: zone) != season,
                            "The next transition must actually change the displayed season")
            }
        }
    }

    private static func exactBoundaries() throws {
        let months = [3, 6, 9, 12]
        let before: [HomeSeason] = [.winter, .spring, .summer, .autumn]
        let after: [HomeSeason] = [.spring, .summer, .autumn, .winter]
        for zone in zones {
            for year in [2026, 2027, 2028] {
                for (index, month) in months.enumerated() {
                    let boundary = localDate(year, month, in: zone)
                    let justBefore = boundary.addingTimeInterval(-0.001)
                    let justAfter = boundary.addingTimeInterval(0.001)
                    let nextMonth = month == 12 ? 3 : month + 3
                    let nextYear = month == 12 ? year + 1 : year
                    let next = localDate(nextYear, nextMonth, in: zone)
                    let context = "\(year)-\(month)-01 in \(zone.identifier)"
                    try require(HomeSeason.current(at: justBefore, timeZone: zone) == before[index],
                                "Wrong season immediately before \(context)")
                    try require(HomeSeason.current(at: boundary, timeZone: zone) == after[index],
                                "Wrong season at \(context)")
                    try require(HomeSeason.current(at: justAfter, timeZone: zone) == after[index],
                                "Wrong season immediately after \(context)")
                    try require(HomeSeason.nextTransition(after: justBefore, timeZone: zone) == boundary,
                                "Skipped the imminent transition at \(context)")
                    try require(HomeSeason.nextTransition(after: boundary, timeZone: zone) == next,
                                "Exact boundary must advance to the following season at \(context)")
                    try require(HomeSeason.nextTransition(after: justAfter, timeZone: zone) == next,
                                "Wrong subsequent transition after \(context)")
                }
            }
        }
    }

    private static func timeZoneDifferences() throws {
        let utc = zones[0], shanghai = zones[1], losAngeles = zones[2]
        let earlyMarchUTC = localDate(2026, 3, 1, 0, 30, in: utc)
        try require(HomeSeason.current(at: earlyMarchUTC, timeZone: utc) == .spring,
                    "UTC must already show spring on March 1")
        try require(HomeSeason.current(at: earlyMarchUTC, timeZone: shanghai) == .spring,
                    "Shanghai must already show spring at the same instant")
        try require(HomeSeason.current(at: earlyMarchUTC, timeZone: losAngeles) == .winter,
                    "Los Angeles must retain winter until its own March 1 midnight")
        let shanghaiBoundary = localDate(2026, 2, 28, 16, in: utc)
        try require(HomeSeason.current(at: shanghaiBoundary, timeZone: shanghai) == .spring,
                    "Shanghai must change at local midnight, not UTC midnight")
        try require(HomeSeason.current(at: shanghaiBoundary, timeZone: utc) == .winter,
                    "UTC must retain winter at Shanghai's boundary")
        let earlyDecemberUTC = localDate(2026, 12, 1, 3, in: utc)
        try require(HomeSeason.current(at: earlyDecemberUTC, timeZone: losAngeles) == .autumn,
                    "Los Angeles must retain autumn until its local December boundary")
        try require(HomeSeason.current(at: earlyDecemberUTC, timeZone: utc) == .winter,
                    "UTC must have entered winter")
        for zone in zones {
            let expected = zone == losAngeles ? localDate(2026, 3, in: zone) : localDate(2026, 6, in: zone)
            try require(HomeSeason.nextTransition(after: earlyMarchUTC, timeZone: zone) == expected,
                        "Next transition must respect \(zone.identifier)'s local date")
        }
    }

    private static func daylightSavingAndYearRollover() throws {
        let zone = zones[2]
        // Los Angeles changes UTC offset within both of these seasons.
        let springStart = localDate(2026, 3, in: zone)
        let summerStart = localDate(2026, 6, in: zone)
        try require(zone.secondsFromGMT(for: springStart) != zone.secondsFromGMT(for: summerStart),
                    "DST fixture must cross a UTC offset change")
        try require(HomeSeason.nextTransition(after: springStart, timeZone: zone) == summerStart,
                    "Spring transition must land at local midnight after the DST change")
        let autumnStart = localDate(2026, 9, in: zone)
        let winterStart = localDate(2026, 12, in: zone)
        try require(zone.secondsFromGMT(for: autumnStart) != zone.secondsFromGMT(for: winterStart),
                    "Autumn fixture must cross the fall DST change")
        try require(HomeSeason.nextTransition(after: autumnStart, timeZone: zone) == winterStart,
                    "Autumn transition must land at local midnight after the DST change")
        for zone in zones {
            let newYear = localDate(2027, 1, in: zone)
            let nextSpring = localDate(2027, 3, in: zone)
            try require(HomeSeason.current(at: newYear, timeZone: zone) == .winter,
                        "A new year must remain winter")
            try require(HomeSeason.nextTransition(after: newYear.addingTimeInterval(-0.001), timeZone: zone) == nextSpring,
                        "December must advance across the year into March")
            try require(HomeSeason.nextTransition(after: newYear, timeZone: zone) == nextSpring,
                        "January must advance to March of the same year")
            let leapDay = localDate(2028, 2, 29, 23, 59, in: zone)
            try require(HomeSeason.nextTransition(after: leapDay, timeZone: zone) == localDate(2028, 3, in: zone),
                        "Leap day must advance to local March 1")
        }
    }
}
