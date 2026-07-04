import XCTest
@testable import DeskSwitchCore

final class ConfigTests: XCTestCase {
    static let fullJSON = """
    {
      "machineName": "macmini",
      "peer": { "name": "macbook", "host": "macbook.local", "port": 8377, "mac": "aa:bb:cc:dd:ee:ff" },
      "wol": { "broadcastHost": "192.168.1.255", "port": 7 },
      "token": "secret",
      "listenPort": 9000,
      "monitors": {
        "M27Q":    { "inputs": { "macmini": 15, "macbook": 27 } },
        "PA278CV": { "inputs": { "macmini": 15, "macbook": 17 } }
      },
      "preventSleepWhenHeadless": true
    }
    """

    static let minimalJSON = """
    {
      "machineName": "macmini",
      "peer": { "name": "macbook", "host": "macbook.local", "port": 8377 },
      "token": "secret"
    }
    """

    func decode(_ json: String) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    }

    func testDecodesFullConfig() throws {
        let c = try decode(Self.fullJSON)
        XCTAssertEqual(c.machineName, "macmini")
        XCTAssertEqual(c.peer.mac, "aa:bb:cc:dd:ee:ff")
        XCTAssertEqual(c.wol.broadcastHost, "192.168.1.255")
        XCTAssertEqual(c.wol.port, 7)
        XCTAssertEqual(c.listenPort, 9000)
        XCTAssertEqual(c.monitors["M27Q"]?.inputs["macbook"], 27)
        XCTAssertTrue(c.preventSleepWhenHeadless)
    }

    func testMinimalConfigGetsDefaults() throws {
        let c = try decode(Self.minimalJSON)
        XCTAssertNil(c.peer.mac)
        XCTAssertEqual(c.wol.broadcastHost, "255.255.255.255")
        XCTAssertEqual(c.wol.port, 9)
        XCTAssertEqual(c.listenPort, 8377)
        XCTAssertEqual(c.monitors, [:])
        XCTAssertFalse(c.preventSleepWhenHeadless)
    }

    func testWolEnabledOnlyWithMac() throws {
        XCTAssertTrue(try decode(Self.fullJSON).wolEnabled)
        XCTAssertFalse(try decode(Self.minimalJSON).wolEnabled)
    }

    func testValidateMissingMacIsWarningNotError() throws {
        let issues = try decode(Self.minimalJSON).validate()
        let wol = issues.filter { $0.message.contains("Wake-on-LAN") }
        XCTAssertEqual(wol.count, 1)
        XCTAssertFalse(wol[0].isError)
    }

    func testValidateRejectsBadValues() throws {
        var c = try decode(Self.fullJSON)
        c.machineName = ""
        XCTAssertTrue(c.validate().contains { $0.isError && $0.message.contains("machineName") })

        var samePeer = try decode(Self.fullJSON)
        samePeer.peer.name = "macmini"
        XCTAssertTrue(samePeer.validate().contains { $0.isError && $0.message.contains("peer.name") })

        var badMac = try decode(Self.fullJSON)
        badMac.peer.mac = "not-a-mac"
        XCTAssertTrue(badMac.validate().contains { $0.isError && $0.message.contains("peer.mac") })

        XCTAssertFalse(try decode(Self.fullJSON).validate().contains { $0.isError })
    }

    func testValidateRejectsBadWolPortAndHost() throws {
        var badWol = try decode(Self.fullJSON)
        badWol.wol.port = 70000
        XCTAssertTrue(badWol.validate().contains { $0.isError && $0.message.contains("wol.port") })

        var badHost = try decode(Self.fullJSON)
        badHost.peer.host = "not a host"
        XCTAssertTrue(badHost.validate().contains { $0.isError && $0.message.contains("peer.host") })

        var emptyHost = try decode(Self.fullJSON)
        emptyHost.peer.host = ""
        XCTAssertTrue(emptyHost.validate().contains { $0.isError && $0.message.contains("peer.host") })
    }

    func testLookups() throws {
        let c = try decode(Self.fullJSON)
        XCTAssertEqual(c.inputCode(monitor: "M27Q", machine: "macbook"), 27)
        XCTAssertNil(c.inputCode(monitor: "M27Q", machine: "nobody"))
        XCTAssertEqual(c.owner(of: "PA278CV", currentCode: 17), "macbook")
        XCTAssertNil(c.owner(of: "PA278CV", currentCode: 99))
    }

    func testSaveLoadRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskswitch-test-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("config.json")
        let c = try decode(Self.fullJSON)
        try c.save(to: url)
        XCTAssertEqual(try Config.load(from: url), c)
        try? FileManager.default.removeItem(at: dir)
    }
}
