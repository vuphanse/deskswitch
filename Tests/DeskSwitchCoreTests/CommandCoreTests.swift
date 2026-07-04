import XCTest
@testable import DeskSwitchCore

final class CommandCoreTests: XCTestCase {
    func testApplyProbeRecordsCodesForThisMachineOnly() {
        var config = testConfig()
        config.monitors["M27Q"]?.inputs["macmini"] = 99  // stale value gets overwritten
        let updated = CommandCore.applyProbe(readings: ["M27Q": 15, "NEWMON": 18], config: config)
        XCTAssertEqual(updated.monitors["M27Q"]?.inputs["macmini"], 15)
        XCTAssertEqual(updated.monitors["M27Q"]?.inputs["macbook"], 27)  // untouched
        XCTAssertEqual(updated.monitors["NEWMON"]?.inputs, ["macmini": 18])  // new entry
        XCTAssertEqual(updated.monitors["PA278CV"], config.monitors["PA278CV"])  // untouched
    }

    func testProbeText() {
        let text = CommandCore.probeText(readings: ["PA278CV": 15, "M27Q": 15], machine: "macmini")
        XCTAssertEqual(text, "M27Q: recorded input 15 for macmini\nPA278CV: recorded input 15 for macmini")
    }

    func testStatusTextWithPeer() {
        let local = LocalStatus(machine: "macmini", monitors: [
            MonitorStatus(name: "M27Q", inputCode: 15, owner: "macmini"),
        ])
        let peer = LocalStatus(machine: "macbook", monitors: [
            MonitorStatus(name: "PA278CV", inputCode: 17, owner: "macbook"),
        ])
        XCTAssertEqual(CommandCore.statusText(local: local, peer: peer), """
        [macmini]
          M27Q: input 15 (macmini)
        [macbook]
          PA278CV: input 17 (macbook)
        """)
    }

    func testStatusTextUnreachablePeerAndHeadless() {
        let local = LocalStatus(machine: "macmini", monitors: [])
        XCTAssertEqual(CommandCore.statusText(local: local, peer: nil), """
        [macmini]
          drives no external displays
        [peer] unreachable
        """)
    }
}
