import XCTest
@testable import DeskSwitchCore

final class MockNotifier: Notifier {
    var messages: [(title: String, body: String)] = []
    func notify(title: String, body: String) {
        messages.append((title, body))
    }
}

final class MenuStateTests: XCTestCase {
    var ddc = MockDDCEngine()
    var peer = MockPeerClient()
    var notifier = MockNotifier()

    /// Synchronous executors make the async-by-default view model deterministic in tests.
    func makeState() -> MenuState {
        let config = testConfig()
        return MenuState(config: config,
                         router: Router(config: config, ddc: ddc, peer: peer),
                         peer: peer, notifier: notifier,
                         runAsync: { $0() }, publish: { $0() })
    }

    func testBuildRowsResolvesOwners() {
        let config = testConfig()
        let local = LocalStatus(machine: "macmini", monitors: [
            MonitorStatus(name: "M27Q", inputCode: 15, owner: "macmini"),
        ])
        let peerStatus = LocalStatus(machine: "macbook", monitors: [
            MonitorStatus(name: "PA278CV", inputCode: 17, owner: "macbook"),
        ])
        XCTAssertEqual(buildRows(config: config, localStatus: local, peerStatus: peerStatus), [
            MonitorRow(name: "M27Q", owner: "macmini"),
            MonitorRow(name: "PA278CV", owner: "macbook"),
        ])
    }

    func testBuildRowsUnknownOwnerWhenPeerDown() {
        let config = testConfig()
        let local = LocalStatus(machine: "macmini", monitors: [
            MonitorStatus(name: "M27Q", inputCode: 15, owner: "macmini"),
        ])
        XCTAssertEqual(buildRows(config: config, localStatus: local, peerStatus: nil), [
            MonitorRow(name: "M27Q", owner: "macmini"),
            MonitorRow(name: "PA278CV", owner: nil),
        ])
    }

    func testRefreshPopulatesRowsAndPeerError() {
        ddc.names = ["M27Q"]
        ddc.inputs = ["M27Q": 15]
        peer.statusResult = .failure(.unreachable)
        let state = makeState()
        state.refresh()
        XCTAssertEqual(state.rows.map(\.name), ["M27Q", "PA278CV"])
        XCTAssertEqual(state.lastError, "macbook unreachable")

        peer.statusResult = .success(LocalStatus(machine: "macbook", monitors: []))
        state.refresh()
        XCTAssertNil(state.lastError)
    }

    func testSendSuccessRefreshes() {
        ddc.names = ["M27Q"]
        ddc.inputs = ["M27Q": 15]
        let state = makeState()
        state.send("M27Q", to: "macbook")
        XCTAssertTrue(notifier.messages.isEmpty)
        XCTAssertEqual(ddc.setCalls.first?.code, 27)
    }

    func testSendFailureSetsErrorAndNotifies() {
        ddc.names = []
        peer.switchError = .unreachable
        let state = makeState()
        state.send("M27Q", to: "macmini")
        XCTAssertEqual(state.lastError, "other Mac offline")
        XCTAssertEqual(notifier.messages.count, 1)
        XCTAssertEqual(notifier.messages[0].body, "other Mac offline")
    }

    func testUIEntryPointsDispatchThroughAsyncExecutor() {
        // Locks in the spec's "UI never blocks on network" contract: every public
        // action must route through runAsync, never run inline on the caller thread.
        var dispatched = 0
        let config = testConfig()
        let state = MenuState(config: config,
                              router: Router(config: config, ddc: ddc, peer: peer),
                              peer: peer, notifier: notifier,
                              runAsync: { work in dispatched += 1; work() },
                              publish: { $0() })
        state.refresh()
        state.send("M27Q", to: "macbook")
        XCTAssertEqual(dispatched, 2)
    }
}
