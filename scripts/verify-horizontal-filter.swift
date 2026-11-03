import AppKit
import CoreGraphics
import Foundation

/// Object-only verification: does not post input, install taps or request permissions.
@main
@MainActor
enum HorizontalFilterVerification {
    private struct Fixture {
        let name: String
        let unit: CGScrollEventUnit
        let vertical: Int32
        let horizontal: Int32
        let scrollPhase: Int64
        let momentumPhase: Int64
    }

    private struct ProtectedValues: Equatable {
        let vertical: [Double]
        let metadata: [Int64]
        let location: CGPoint
        let timestamp: CGEventTimestamp
        let flags: UInt64
    }

    private static let horizontalFields: [(String, CGEventField)] = [
        ("line", .scrollWheelEventDeltaAxis2),
        ("fixed", .scrollWheelEventFixedPtDeltaAxis2),
        ("point", .scrollWheelEventPointDeltaAxis2),
        ("accelerated", .scrollWheelEventAcceleratedDeltaAxis2),
        ("raw", .scrollWheelEventRawDeltaAxis2)
    ]
    private static let verticalFields: [CGEventField] = [
        .scrollWheelEventDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1,
        .scrollWheelEventPointDeltaAxis1, .scrollWheelEventAcceleratedDeltaAxis1,
        .scrollWheelEventRawDeltaAxis1
    ]
    private static let metadataFields: [CGEventField] = [
        .scrollWheelEventIsContinuous, .scrollWheelEventScrollPhase,
        .scrollWheelEventMomentumPhase, .scrollWheelEventMomentumOptionPhase,
        .scrollWheelEventScrollCount, .eventSourceUserData, .eventSourceStateID
    ]

    static func main() {
        #if LEGACY_FILTER
        print("旧三字段过滤复现：预期因 raw / accelerated 水平残留而失败。")
        #else
        print("HorizontalScrollFilter 对象验证：不投递输入、不安装 tap、不读取应用内容。")
        #endif
        var failures = 0
        var fixtures: [Fixture] = []
        for unit in [CGScrollEventUnit.pixel, .line] {
            let mode = unit == .pixel ? "pixel" : "line"
            fixtures.append(Fixture(name: "\(mode) 对角滚动", unit: unit,
                                    vertical: -120, horizontal: 45, scrollPhase: 2, momentumPhase: 0))
            fixtures.append(Fixture(name: "\(mode) 纯横向", unit: unit,
                                    vertical: 0, horizontal: -37, scrollPhase: 1, momentumPhase: 0))
            fixtures.append(Fixture(name: "\(mode) 纯竖向", unit: unit,
                                    vertical: 83, horizontal: 0, scrollPhase: 4, momentumPhase: 0))
            fixtures.append(Fixture(name: "\(mode) 惯性滚动", unit: unit,
                                    vertical: -60, horizontal: 18, scrollPhase: 0, momentumPhase: 2))
        }

        for fixture in fixtures {
            let initialFailures = failures
            guard let event = makeEvent(fixture) else {
                failures += 1
                print("FAIL \(fixture.name)：无法创建事件对象")
                continue
            }
            let protectedBefore = protectedValues(event)
            let nsBefore = NSEvent(cgEvent: event)
            #if LEGACY_FILTER
            // Exact three setters used by the original application callback.
            event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: 0)
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: 0)
            event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: 0)
            #else
            HorizontalScrollFilter.apply(to: event)
            #endif
            for field in horizontalFields {
                let remaining = event.getDoubleValueField(field.1)
                if remaining != 0 {
                    failures += 1
                    print("  FAIL \(fixture.name)：\(field.0) 水平残留 \(remaining)")
                }
            }
            if protectedValues(event) != protectedBefore {
                failures += 1
                print("  FAIL \(fixture.name)：竖向、phase、UserData 或其他受保护元数据改变")
            }
            if let before = nsBefore, let after = NSEvent(cgEvent: event) {
                if after.deltaX != 0 || after.scrollingDeltaX != 0 {
                    failures += 1
                    print("  FAIL \(fixture.name)：NSEvent 仍有水平量")
                }
                if after.deltaY != before.deltaY || after.scrollingDeltaY != before.scrollingDeltaY ||
                    after.phase != before.phase || after.momentumPhase != before.momentumPhase ||
                    after.hasPreciseScrollingDeltas != before.hasPreciseScrollingDeltas {
                    failures += 1
                    print("  FAIL \(fixture.name)：NSEvent 竖向或手势状态改变")
                }
            } else {
                failures += 1
                print("  FAIL \(fixture.name)：无法转换 NSEvent 对象")
            }
            print("\(initialFailures == failures ? "PASS" : "FAIL") \(fixture.name)")
        }
        print("验证结果：\(fixtures.count) 个场景，\(failures) 项失败。")
        exit(failures == 0 ? 0 : 1)
    }

    private static func makeEvent(_ fixture: Fixture) -> CGEvent? {
        guard let event = CGEvent(scrollWheelEvent2Source: CGEventSource(stateID: .privateState),
                                  units: fixture.unit, wheelCount: 2,
                                  wheel1: fixture.vertical, wheel2: fixture.horizontal, wheel3: 0) else { return nil }
        // Explicitly seed each modern channel instead of assuming the constructor fills it.
        event.setDoubleValueField(.scrollWheelEventAcceleratedDeltaAxis2,
                                  value: Double(fixture.horizontal) * 0.875)
        event.setDoubleValueField(.scrollWheelEventRawDeltaAxis2,
                                  value: Double(fixture.horizontal) * 1.375)
        event.setDoubleValueField(.scrollWheelEventAcceleratedDeltaAxis1,
                                  value: Double(fixture.vertical) * 1.125)
        event.setDoubleValueField(.scrollWheelEventRawDeltaAxis1,
                                  value: Double(fixture.vertical) * 1.625)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: fixture.scrollPhase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: fixture.momentumPhase)
        event.setIntegerValueField(.scrollWheelEventMomentumOptionPhase, value: fixture.momentumPhase)
        event.setIntegerValueField(.scrollWheelEventScrollCount, value: 7)
        event.setIntegerValueField(.eventSourceUserData, value: 987_654)
        event.flags = [.maskAlternate]
        event.location = CGPoint(x: 123.5, y: 456.75)
        event.timestamp = 123_456_789
        return event
    }

    private static func protectedValues(_ event: CGEvent) -> ProtectedValues {
        ProtectedValues(vertical: verticalFields.map { event.getDoubleValueField($0) },
                        metadata: metadataFields.map { event.getIntegerValueField($0) },
                        location: event.location, timestamp: event.timestamp,
                        flags: event.flags.rawValue)
    }
}
