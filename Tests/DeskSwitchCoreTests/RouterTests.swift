import XCTest
@testable import DeskSwitchCore

final class RouterTests: XCTestCase {
    var ddc = MockDDCEngine()
    var peer = MockPeerClient()

    func makeRouter() -> Router {
        Router(config: testConfig(), ddc: ddc, peer: peer)
    }

    func testSwitchesLocallyWhenThisMacDrivesTheMonitor() throws {
        ddc.names = ["M27Q"]
        let outcome = try makeRouter().switchMonitor("M27Q", to: "macbook")
        XCTAssertEqual(outcome, .switchedLocally)
        XCTAssertEqual(ddc.setCalls.count, 1)
        XCTAssertEqual(ddc.setCalls[0].code, 27)
        XCTAssertTrue(peer.switchCalls.isEmpty)
    }

    func testForwardsWhenPeerDrivesTheMonitor() throws {
        ddc.names = []
        let outcome = try makeRouter().switchMonitor("M27Q", to: "macmini")
        XCTAssertEqual(outcome, .forwarded)
        XCTAssertEqual(peer.switchCalls.count, 1)
        XCTAssertEqual(peer.switchCalls[0].monitor, "M27Q")
        XCTAssertTrue(peer.switchCalls[0].forwarded)
    }

    func testForwardedRequestNeverReForwards() {
        ddc.names = []
        XCTAssertThrowsError(
            try makeRouter().switchMonitor("M27Q", to: "macmini", allowForward: false)
        ) { XCTAssertEqual($0 as? RouterError, .nobodyDrives("M27Q")) }
        XCTAssertTrue(peer.switchCalls.isEmpty)
    }

    func testUnknownMonitor() {
        XCTAssertThrowsError(try makeRouter().switchMonitor("LG99", to: "macbook")) {
            XCTAssertEqual($0 as? RouterError, .unknownMonitor("LG99"))
        }
    }

    func testMissingInputCode() {
        ddc.names = ["M27Q"]
        XCTAssertThrowsError(try makeRouter().switchMonitor("M27Q", to: "ghost")) {
            XCTAssertEqual($0 as? RouterError, .missingInputCode(monitor: "M27Q", machine: "ghost"))
        }
        XCTAssertTrue(RouterError.missingInputCode(monitor: "M27Q", machine: "ghost")
            .userMessage.contains("deskswitch probe"))
    }

    func testDDCFailureSurfaces() {
        ddc.names = ["M27Q"]
        ddc.failSet = true
        XCTAssertThrowsError(try makeRouter().switchMonitor("M27Q", to: "macbook")) {
            guard case .ddcFailure = $0 as? RouterError else { return XCTFail("expected ddcFailure") }
        }
    }

    func testPeerUnreachableSurfaces() {
        ddc.names = []
        peer.switchError = .unreachable
        XCTAssertThrowsError(try makeRouter().switchMonitor("M27Q", to: "macmini")) {
            XCTAssertEqual($0 as? RouterError, .peerUnreachable)
        }
    }

    func testPeer409MapsToNobodyDrives() {
        ddc.names = []
        peer.switchError = .remote(status: 409, message: "no machine currently drives 'M27Q'")
        XCTAssertThrowsError(try makeRouter().switchMonitor("M27Q", to: "macmini")) {
            XCTAssertEqual($0 as? RouterError, .nobodyDrives("M27Q"))
        }
    }

    func testLocalStatusReportsOwners() {
        ddc.names = ["M27Q", "PA278CV"]
        ddc.inputs = ["M27Q": 15, "PA278CV": 99]
        let s = makeRouter().localStatus()
        XCTAssertEqual(s.machine, "macmini")
        XCTAssertEqual(s.monitors.count, 2)
        XCTAssertEqual(s.monitors.first { $0.name == "M27Q" }?.owner, "macmini")
        XCTAssertNil(s.monitors.first { $0.name == "PA278CV" }?.owner)
    }

    func testSwitchAllCoversEveryConfiguredMonitorSorted() {
        ddc.names = ["M27Q", "PA278CV"]
        let results = makeRouter().switchAll(to: "macbook")
        XCTAssertEqual(results.map(\.monitor), ["M27Q", "PA278CV"])
        XCTAssertEqual(ddc.setCalls.count, 2)
        for r in results {
            XCTAssertEqual(try? r.result.get(), .switchedLocally)
        }
    }
}
