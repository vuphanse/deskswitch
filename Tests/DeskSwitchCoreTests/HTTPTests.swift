import XCTest
@testable import DeskSwitchCore

final class HTTPTests: XCTestCase {
    func testParsesGetWithHeaders() throws {
        let raw = Data("GET /status HTTP/1.1\r\nHost: x\r\nX-DeskSwitch-Token: secret\r\n\r\n".utf8)
        guard case .request(let req) = HTTPRequest.parse(raw) else { return XCTFail("expected request") }
        XCTAssertEqual(req.method, "GET")
        XCTAssertEqual(req.path, "/status")
        XCTAssertEqual(req.headers["x-deskswitch-token"], "secret")
        XCTAssertTrue(req.body.isEmpty)
    }

    func testParsesPostBodyUsingContentLength() throws {
        let body = #"{"monitor":"M27Q","target":"macmini"}"#
        let raw = Data("POST /switch HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8)
        guard case .request(let req) = HTTPRequest.parse(raw) else { return XCTFail("expected request") }
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(String(decoding: req.body, as: UTF8.self), body)
    }

    func testIncompleteHeaderAndIncompleteBody() {
        XCTAssertEqual(HTTPRequest.parse(Data("GET /status HTT".utf8)), .incomplete)
        let partial = Data("POST /switch HTTP/1.1\r\nContent-Length: 100\r\n\r\n{\"mon".utf8)
        XCTAssertEqual(HTTPRequest.parse(partial), .incomplete)
    }

    func testInvalidRequestLine() {
        XCTAssertEqual(HTTPRequest.parse(Data("NONSENSE\r\n\r\n".utf8)), .invalid)
    }

    func testResponseSerialization() {
        let resp = HTTPResponse.json(200, ["ok": "yes"])
        let text = String(decoding: resp.serialized(), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(text.contains("Content-Type: application/json"))
        XCTAssertTrue(text.contains("Content-Length: \(resp.body.count)"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n" + #"{"ok":"yes"}"#))
    }

    func testErrorResponseStatusLine() {
        let resp = HTTPResponse.json(409, ["error": "x"])
        XCTAssertTrue(String(decoding: resp.serialized(), as: UTF8.self).hasPrefix("HTTP/1.1 409 "))
    }

    func testNegativeOrGarbageContentLengthIsInvalid() {
        let negative = Data("POST /switch HTTP/1.1\r\nContent-Length: -1\r\n\r\n".utf8)
        XCTAssertEqual(HTTPRequest.parse(negative), .invalid)
        let garbage = Data("POST /switch HTTP/1.1\r\nContent-Length: abc\r\n\r\n".utf8)
        XCTAssertEqual(HTTPRequest.parse(garbage), .invalid)
    }

    func testParsesFromDataSliceWithNonzeroStartIndex() {
        // Accumulation buffers may hand the parser a slice; index math must not assume startIndex 0.
        let body = #"{"x":"y"}"#
        var padded = Data(repeating: 0xEE, count: 7)
        padded.append(Data("POST /s HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8))
        let slice = padded[7...]
        guard case .request(let req) = HTTPRequest.parse(slice) else { return XCTFail("expected request") }
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(String(decoding: req.body, as: UTF8.self), body)
    }
}
