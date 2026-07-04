import XCTest
@testable import DeskSwitchCore

final class APIHandlerTests: XCTestCase {
    var ddc = MockDDCEngine()
    var peer = MockPeerClient()

    func makeHandler() -> APIHandler {
        APIHandler(router: Router(config: testConfig(), ddc: ddc, peer: peer), token: "secret")
    }

    func request(_ method: String, _ path: String, token: String? = "secret",
                 body: String = "") -> HTTPRequest {
        var headers: [String: String] = [:]
        if let token { headers["x-deskswitch-token"] = token }
        return HTTPRequest(method: method, path: path, headers: headers, body: Data(body.utf8))
    }

    func bodyJSON(_ resp: HTTPResponse) -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: resp.body)) ?? [:]
    }

    func testRejectsMissingOrWrongToken() {
        XCTAssertEqual(makeHandler().handle(request("GET", "/status", token: nil)).status, 401)
        XCTAssertEqual(makeHandler().handle(request("GET", "/status", token: "wrong")).status, 401)
    }

    func testStatusEndpoint() throws {
        ddc.names = ["M27Q"]
        ddc.inputs = ["M27Q": 15]
        let resp = makeHandler().handle(request("GET", "/status"))
        XCTAssertEqual(resp.status, 200)
        let status = try JSONDecoder().decode(LocalStatus.self, from: resp.body)
        XCTAssertEqual(status.machine, "macmini")
        XCTAssertEqual(status.monitors, [MonitorStatus(name: "M27Q", inputCode: 15, owner: "macmini")])
    }

    func testSwitchLocal() {
        ddc.names = ["M27Q"]
        let resp = makeHandler().handle(
            request("POST", "/switch", body: #"{"monitor":"M27Q","target":"macbook"}"#))
        XCTAssertEqual(resp.status, 200)
        XCTAssertEqual(bodyJSON(resp)["outcome"], "switched-locally")
        XCTAssertEqual(ddc.setCalls.first?.code, 27)
    }

    func testForwardedFlagBlocksReForwarding() {
        ddc.names = []
        let resp = makeHandler().handle(
            request("POST", "/switch", body: #"{"monitor":"M27Q","target":"macmini","forwarded":true}"#))
        XCTAssertEqual(resp.status, 409)
        XCTAssertTrue(peer.switchCalls.isEmpty)
    }

    func testErrorStatusMapping() {
        ddc.names = []
        peer.switchError = .unreachable
        let unreachable = makeHandler().handle(
            request("POST", "/switch", body: #"{"monitor":"M27Q","target":"macmini"}"#))
        XCTAssertEqual(unreachable.status, 502)

        let unknown = makeHandler().handle(
            request("POST", "/switch", body: #"{"monitor":"LG99","target":"macmini"}"#))
        XCTAssertEqual(unknown.status, 404)

        ddc.names = ["M27Q"]
        let missing = makeHandler().handle(
            request("POST", "/switch", body: #"{"monitor":"M27Q","target":"ghost"}"#))
        XCTAssertEqual(missing.status, 422)
        XCTAssertTrue(bodyJSON(missing)["error"]!.contains("deskswitch probe"))
    }

    func testBadJSONAndUnknownRoute() {
        XCTAssertEqual(makeHandler().handle(request("POST", "/switch", body: "not json")).status, 400)
        XCTAssertEqual(makeHandler().handle(request("GET", "/nope")).status, 404)
    }

    func testSwitchRequestDecodingDefaultsForwardedFalse() throws {
        let sw = try JSONDecoder().decode(SwitchRequest.self,
                                          from: Data(#"{"monitor":"M27Q","target":"x"}"#.utf8))
        XCTAssertFalse(sw.forwarded)
    }
}
