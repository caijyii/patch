import Foundation
import Darwin

private struct VerificationFailure: Error, CustomStringConvertible {
    let description: String
}

@main
@MainActor
enum ScrollPermissionVerification {
    typealias Permission = ScrollCapturePermission
    private static var checks = 0

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw VerificationFailure(description: message) }
    }

    static func main() {
        do {
            try grantedIsSilent()
            try requestOnce(accessibility: false, postEvents: false, expected: "accessibility")
            try requestOnce(accessibility: false, postEvents: true, expected: "accessibility")
            try requestOnce(accessibility: true, postEvents: false, expected: "postEvents")
            try explicitChoice(.openSettings, expected: ["alert", "settings"])
            try explicitChoice(.later, expected: ["alert"])
            try freshAttemptAfterRequest()
            try relaunchGuidance()
            print("PASS: \(checks) scroll permission checks; injected snapshots/actions only, no TCC requests or Settings launch")
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }

    private static func grantedIsSilent() throws {
        var operations = 0
        let granted = Permission.ensurePermission(snapshot: .init(accessibilityTrusted: true, canPostEvents: true),
            choose: { _ in operations += 1; return .request },
            request: { _ in operations += 1 }, openSettings: { operations += 1 })
        try require(granted && operations == 0, "Fully granted access must proceed without any UI or request")
        checks += 1
    }

    private static func requestOnce(accessibility: Bool, postEvents: Bool, expected: String) throws {
        var events: [String] = []
        let granted = Permission.ensurePermission(snapshot: .init(accessibilityTrusted: accessibility, canPostEvents: postEvents),
            choose: { snapshot in
                events.append("alert")
                if snapshot.accessibilityTrusted != accessibility || snapshot.canPostEvents != postEvents { events.append("wrongSnapshot") }
                return .request
            }, request: { events.append($0 == .accessibility ? "accessibility" : "postEvents") },
            openSettings: { events.append("settings") })
        try require(!granted, "A permission request must not enter selection during the same attempt")
        try require(events == ["alert", expected, "settings"], "Expected exactly one matching OS request followed by Settings: \(events)")
        checks += 1
    }

    private static func explicitChoice(_ choice: Permission.Choice, expected: [String]) throws {
        var events: [String] = []
        let granted = Permission.ensurePermission(snapshot: .init(accessibilityTrusted: false, canPostEvents: false),
            choose: { _ in events.append("alert"); return choice }, request: { _ in events.append("unexpectedRequest") },
            openSettings: { events.append("settings") })
        try require(!granted && events == expected, "Settings/later choice must not implicitly request consent: \(events)")
        checks += 1
    }

    private static func freshAttemptAfterRequest() throws {
        var current = Permission.Snapshot(accessibilityTrusted: false, canPostEvents: false)
        var requests = 0, opened = 0, prompts = 0
        let first = Permission.ensurePermission(snapshot: current, choose: { _ in prompts += 1; return .request },
            request: { _ in requests += 1; current = .init(accessibilityTrusted: true, canPostEvents: true) },
            openSettings: { opened += 1 })
        try require(!first, "Even a synchronous grant must stop this attempt before selecting the Settings window")
        let retry = Permission.ensurePermission(snapshot: current, choose: { _ in prompts += 1; return .later },
            request: { _ in requests += 1 }, openSettings: { opened += 1 })
        try require(retry && requests == 1 && opened == 1 && prompts == 1, "An explicit retry with fresh granted permissions must proceed silently")
        checks += 1
    }

    private static func relaunchGuidance() throws {
        let stale = Permission.Snapshot(accessibilityTrusted: true, canPostEvents: false)
        try require(stale.explanation.contains("退出并重新打开"), "Trusted AX but denied event posting must explain a possible relaunch")
        checks += 1
    }
}
