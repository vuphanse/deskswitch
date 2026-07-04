import XCTest
@testable import DeskSwitchCore

final class HTTPPeerClientTests: XCTestCase {
    func serve(port: UInt16, _ handler: @escaping (HTTPRequest) -> HTTPResponse) throws -> HTTPServer {
        let server = try HTTPServer(port: port, handler: handler)
        server.start()
        return server
    }

    func testStatusDecodesAndSendsToken() throws {
        var seenToken: String?
        let server = try serve(port: 18380) { req in
            seenToken = req.headers["x-deskswitch-token"]
            return .json(200, LocalStatus(machine: "macbook", monitors: [
                MonitorStatus(name: "PA278CV", inputCode: 17, owner: "macbook"),
            ]))
        }
        defer { server.stop() }

        let client = HTTPPeerClient(host: "127.0.0.1", port: 18380, token: "secret")
        let status = try client.status()
        XCTAssertEqual(status.machine, "macbook")
        XCTAssertEqual(status.monitors.first?.name, "PA278CV")
        XCTAssertEqual(seenToken, "secret")
    }

    func testRequestSwitchPostsForwardedBody() throws {
        var seen: SwitchRequest?
        let server = try serve(port: 18381) { req in
            seen = try? JSONDecoder().decode(SwitchRequest.self, from: req.body)
            return .json(200, ["outcome": "switched-locally"])
        }
        defer { server.stop() }

        let client = HTTPPeerClient(host: "127.0.0.1", port: 18381, token: "secret")
        try client.requestSwitch(monitor: "M27Q", target: "macmini", forwarded: true)
        XCTAssertEqual(seen, SwitchRequest(monitor: "M27Q", target: "macmini", forwarded: true))
    }

    func testRemoteErrorCarriesStatusAndMessage() throws {
        let server = try serve(port: 18382) { _ in
            .json(409, ["error": "no machine currently drives 'M27Q'"])
        }
        defer { server.stop() }

        let client = HTTPPeerClient(host: "127.0.0.1", port: 18382, token: "secret")
        XCTAssertThrowsError(try client.requestSwitch(monitor: "M27Q", target: "x", forwarded: false)) {
            XCTAssertEqual($0 as? PeerClientError,
                           .remote(status: 409, message: "no machine currently drives 'M27Q'"))
        }
    }

    func testUndecodableStatusPayloadThrowsRemoteWithRealStatus() throws {
        let server = try serve(port: 18383) { _ in
            .json(200, ["not": "a-local-status"])
        }
        defer { server.stop() }

        let client = HTTPPeerClient(host: "127.0.0.1", port: 18383, token: "secret")
        XCTAssertThrowsError(try client.status()) {
            XCTAssertEqual($0 as? PeerClientError,
                           .remote(status: 200, message: "undecodable status payload"))
        }
    }

    func testUnreachableHostThrowsUnreachableWithinBudget() {
        // Nothing listens on this port.
        let client = HTTPPeerClient(host: "127.0.0.1", port: 18399, token: "secret")
        let start = Date()
        XCTAssertThrowsError(try client.status()) {
            XCTAssertEqual($0 as? PeerClientError, .unreachable)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 4.0)  // 2 s budget + slack
    }
}
