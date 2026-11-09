import XCTest
@testable import SievePilot

final class AppModelTests: XCTestCase {
    func testExposesMenuBarCopy() {
        XCTAssertEqual(AppModel.productName, "SievePilot")
        XCTAssertEqual(AppModel.coreStatus, "Core engine ready")
    }
}
