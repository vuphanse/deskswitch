import Foundation
@testable import DeskSwitchCore

enum MockError: Error { case noValue, setFailed }

final class MockDDCEngine: DDCEngine {
    var names: [String] = []
    var inputs: [String: UInt16] = [:]
    var setCalls: [(name: String, code: UInt16)] = []
    var failSet = false

    func connectedDisplayNames() throws -> [String] { names }

    func readInput(displayName: String) throws -> UInt16 {
        guard let v = inputs[displayName] else { throw MockError.noValue }
        return v
    }

    func setInput(displayName: String, code: UInt16) throws {
        if failSet { throw MockError.setFailed }
        setCalls.append((displayName, code))
        inputs[displayName] = code
    }
}

final class MockPeerClient: PeerClient {
    var statusResult: Result<LocalStatus, PeerClientError> = .failure(.unreachable)
    var switchError: PeerClientError?
    var switchCalls: [(monitor: String, target: String, forwarded: Bool)] = []

    func status() throws -> LocalStatus {
        try statusResult.get()
    }

    func requestSwitch(monitor: String, target: String, forwarded: Bool) throws {
        switchCalls.append((monitor, target, forwarded))
        if let e = switchError { throw e }
    }
}

func testConfig() -> Config {
    Config(
        machineName: "macmini",
        peer: .init(name: "macbook", host: "macbook.local", port: 8377, mac: "aa:bb:cc:dd:ee:ff"),
        token: "secret",
        monitors: [
            "M27Q": .init(inputs: ["macmini": 15, "macbook": 27]),
            "PA278CV": .init(inputs: ["macmini": 15, "macbook": 17]),
        ])
}
