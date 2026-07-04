import XCTest
@testable import DeskSwitchCore

final class SleepGuardTests: XCTestCase {
    func testAssertionHeldOnlyWhenHeadlessAndEnabled() {
        XCTAssertTrue(shouldHoldAssertion(headless: true, enabled: true))
        XCTAssertFalse(shouldHoldAssertion(headless: true, enabled: false))
        XCTAssertFalse(shouldHoldAssertion(headless: false, enabled: true))
        XCTAssertFalse(shouldHoldAssertion(headless: false, enabled: false))
    }
}
