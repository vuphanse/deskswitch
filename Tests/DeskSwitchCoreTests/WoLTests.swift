import XCTest
@testable import DeskSwitchCore

final class MockWoLSender: WoLSender {
    var wakeCount = 0
    func wake() throws { wakeCount += 1 }
}

/// Peer that fails with .unreachable a set number of times, then succeeds.
final class FlakyPeerClient: PeerClient {
    var failuresRemaining: Int
    var calls = 0
    init(failures: Int) { self.failuresRemaining = failures }

    private func gate() throws {
        calls += 1
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw PeerClientError.unreachable
        }
    }

    func status() throws -> LocalStatus {
        try gate()
        return LocalStatus(machine: "macbook", monitors: [])
    }

    func requestSwitch(monitor: String, target: String, forwarded: Bool) throws {
        try gate()
    }
}

final class WoLTests: XCTestCase {
    func testMagicPacketLayout() throws {
        let packet = try wolMagicPacket(mac: "aa:bb:cc:dd:ee:ff")
        XCTAssertEqual(packet.count, 102)
        XCTAssertEqual(Array(packet.prefix(6)), Array(repeating: 0xFF, count: 6))
        let mac: [UInt8] = [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]
        for i in 0..<16 {
            XCTAssertEqual(Array(packet[(6 + i * 6)..<(6 + (i + 1) * 6)]), mac, "repeat \(i)")
        }
    }

    func testMagicPacketAcceptsDashesAndRejectsGarbage() throws {
        XCTAssertEqual(try wolMagicPacket(mac: "AA-BB-CC-DD-EE-FF"),
                       try wolMagicPacket(mac: "aa:bb:cc:dd:ee:ff"))
        XCTAssertThrowsError(try wolMagicPacket(mac: "not-a-mac"))
        XCTAssertThrowsError(try wolMagicPacket(mac: "aa:bb:cc:dd:ee"))
    }

    func testWakingClientSendsWoLAndRetriesOnce() throws {
        let flaky = FlakyPeerClient(failures: 1)
        let wol = MockWoLSender()
        let client = WakingPeerClient(inner: flaky, wol: wol, wakeDelay: 0, sleeper: { _ in })
        try client.requestSwitch(monitor: "M27Q", target: "macmini", forwarded: false)
        XCTAssertEqual(wol.wakeCount, 1)
        XCTAssertEqual(flaky.calls, 2)
    }

    func testWakingClientGivesUpAfterOneRetry() {
        let flaky = FlakyPeerClient(failures: 2)
        let wol = MockWoLSender()
        let client = WakingPeerClient(inner: flaky, wol: wol, wakeDelay: 0, sleeper: { _ in })
        XCTAssertThrowsError(try client.status()) {
            XCTAssertEqual($0 as? PeerClientError, .unreachable)
        }
        XCTAssertEqual(wol.wakeCount, 1)
        XCTAssertEqual(flaky.calls, 2)
    }

    func testWithoutWoLSenderStillRetriesOnceWithoutWaking() throws {
        // Spec degrade path (config prose + error table): peer.mac unset → skip the
        // magic packet, but the single retry before "other Mac offline" remains.
        let recovers = FlakyPeerClient(failures: 1)
        let client = WakingPeerClient(inner: recovers, wol: nil, wakeDelay: 0, sleeper: { _ in })
        XCTAssertNoThrow(try client.status())
        XCTAssertEqual(recovers.calls, 2)

        let dead = FlakyPeerClient(failures: 2)
        let deadClient = WakingPeerClient(inner: dead, wol: nil, wakeDelay: 0, sleeper: { _ in })
        XCTAssertThrowsError(try deadClient.status()) {
            XCTAssertEqual($0 as? PeerClientError, .unreachable)
        }
        XCTAssertEqual(dead.calls, 2)
    }

    func testNonUnreachableErrorsPassThroughWithoutWoL() {
        final class RemoteErrorPeer: PeerClient {
            func status() throws -> LocalStatus {
                throw PeerClientError.remote(status: 409, message: "x")
            }
            func requestSwitch(monitor: String, target: String, forwarded: Bool) throws {
                throw PeerClientError.remote(status: 409, message: "x")
            }
        }
        let wol = MockWoLSender()
        let client = WakingPeerClient(inner: RemoteErrorPeer(), wol: wol, wakeDelay: 0, sleeper: { _ in })
        XCTAssertThrowsError(try client.status()) {
            XCTAssertEqual($0 as? PeerClientError, .remote(status: 409, message: "x"))
        }
        XCTAssertEqual(wol.wakeCount, 0)
    }

    func testMakeWoLSenderRespectsConfig() {
        XCTAssertNotNil(makeWoLSender(config: testConfig()))  // has peer.mac
        var noMac = testConfig()
        noMac.peer.mac = nil
        XCTAssertNil(makeWoLSender(config: noMac))
    }
}
