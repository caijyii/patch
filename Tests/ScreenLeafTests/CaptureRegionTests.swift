import XCTest
import CoreGraphics
@testable import ScreenLeaf

final class CaptureRegionTests: XCTestCase {
    func testAppKitRegionConvertsToTopLeftScreenCoordinates() {
        let region = CaptureRegion(rect: CGRect(x: 100, y: 200, width: 400, height: 300),
                                   displayID: 1, screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                   scale: 2, targetPID: nil)
        XCTAssertEqual(region.sourceRect, CGRect(x: 100, y: 400, width: 400, height: 300))
    }

    func testSecondaryDisplayWithNegativeOriginUsesItsOwnFrame() {
        let region = CaptureRegion(rect: CGRect(x: -1300, y: 200, width: 400, height: 300),
                                   displayID: 2, screenFrame: CGRect(x: -1440, y: 100, width: 1440, height: 900),
                                   scale: 1, targetPID: nil)
        XCTAssertEqual(region.sourceRect, CGRect(x: 140, y: 500, width: 400, height: 300))
    }
}
