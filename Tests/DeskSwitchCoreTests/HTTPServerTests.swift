import XCTest
@testable import DeskSwitchCore

final class HTTPServerTests: XCTestCase {
    func testServesHandlerResponseOverLoopback() throws {
        let port: UInt16 = 18377
        let server = try HTTPServer(port: port) { req in
            .json(200, ["echo": req.path])
        }
        server.start()
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(port)/hello")!
        let expectation = expectation(description: "response")
        var received: (Int, [String: String])?
        URLSession.shared.dataTask(with: url) { data, response, _ in
            if let http = response as? HTTPURLResponse, let data,
               let json = try? JSONDecoder().decode([String: String].self, from: data) {
                received = (http.statusCode, json)
            }
            expectation.fulfill()
        }.resume()
        wait(for: [expectation], timeout: 5)
        XCTAssertEqual(received?.0, 200)
        XCTAssertEqual(received?.1, ["echo": "/hello"])
    }

    func testMalformedRequestGets400() throws {
        let port: UInt16 = 18378
        let server = try HTTPServer(port: port) { _ in .json(200, ["ok": "1"]) }
        server.start()
        defer { server.stop() }

        // Raw socket write of garbage, expect an HTTP 400 status line back.
        let expectation = expectation(description: "raw response")
        let conn = TCPTestClient(host: "127.0.0.1", port: port)
        conn.sendAndReadAll(Data("NONSENSE\r\n\r\n".utf8)) { data in
            XCTAssertTrue(String(decoding: data, as: UTF8.self).hasPrefix("HTTP/1.1 400"))
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
    }

    func testListenerFailureCallbackFiresOnPortConflict() throws {
        let port: UInt16 = 18384
        let first = try HTTPServer(port: port) { _ in .json(200, ["ok": "1"]) }
        first.start()
        defer { first.stop() }
        // Give the first listener a moment to bind.
        Thread.sleep(forTimeInterval: 0.2)

        let second = try HTTPServer(port: port) { _ in .json(200, ["ok": "2"]) }
        let expectation = expectation(description: "failure callback")
        expectation.assertForOverFulfill = false
        second.onListenerFailure = { _ in expectation.fulfill() }
        second.start()
        defer { second.stop() }
        wait(for: [expectation], timeout: 5)
    }

    func testOversizedRequestGets400() throws {
        let port: UInt16 = 18379
        let server = try HTTPServer(port: port, maxRequestBytes: 64) { _ in .json(200, ["ok": "1"]) }
        server.start()
        defer { server.stop() }

        // Valid request start, Content-Length far beyond the cap, body drips in over it.
        let big = "POST /switch HTTP/1.1\r\nContent-Length: 100000\r\n\r\n" + String(repeating: "x", count: 200)
        let expectation = expectation(description: "raw response")
        let conn = TCPTestClient(host: "127.0.0.1", port: port)
        conn.sendAndReadAll(Data(big.utf8)) { data in
            XCTAssertTrue(String(decoding: data, as: UTF8.self).hasPrefix("HTTP/1.1 400"))
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
    }
}

import Network

/// Minimal raw TCP client for exercising the server with non-HTTP bytes.
final class TCPTestClient {
    private let connection: NWConnection

    init(host: String, port: UInt16) {
        connection = NWConnection(host: NWEndpoint.Host(host),
                                  port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    }

    func sendAndReadAll(_ data: Data, completion: @escaping (Data) -> Void) {
        connection.start(queue: .global())
        connection.send(content: data, completion: .contentProcessed { _ in
            self.connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, _ in
                completion(data ?? Data())
                self.connection.cancel()
            }
        })
    }
}
