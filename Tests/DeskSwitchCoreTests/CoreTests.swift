import XCTest
@testable import DeskSwitchCore

final class CoreTests: XCTestCase {
    func testVersion() {
        XCTAssertEqual(deskswitchVersion, "0.1.0")
    }
}
