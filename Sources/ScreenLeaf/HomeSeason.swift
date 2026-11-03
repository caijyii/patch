// SPDX-FileCopyrightText: 2026 caijyii
// SPDX-License-Identifier: MIT

import Foundation

/// The built-in scenery follows northern-hemisphere calendar seasons locally.
enum HomeSeason: String, CaseIterable {
    case spring, summer, autumn, winter

    static func current(at date: Date = Date(), timeZone: TimeZone = .current) -> HomeSeason {
        let month = calendar(in: timeZone).component(.month, from: date)
        switch month {
        case 3...5: return .spring
        case 6...8: return .summer
        case 9...11: return .autumn
        default: return .winter
        }
    }

    /// Always returns a future boundary, including when called exactly at one.
    static func nextTransition(after date: Date, timeZone: TimeZone = .current) -> Date {
        let calendar = calendar(in: timeZone)
        let boundaries = [3, 6, 9, 12].compactMap { month in
            calendar.nextDate(after: date,
                              matching: DateComponents(month: month, day: 1, hour: 0,
                                                       minute: 0, second: 0),
                              matchingPolicy: .nextTime,
                              repeatedTimePolicy: .first,
                              direction: .forward)
        }
        // These four recurring Gregorian dates exist in every year. Calendar
        // resolves an exceptional missing midnight to the first available time.
        return boundaries.min()!
    }

    private static func calendar(in timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}
