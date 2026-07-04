import Foundation
import Network

/// Minimal HTTP/1.1 server: one request per connection, Connection: close semantics.
/// Bound to the LAN; auth is the caller-supplied handler's job (APIHandler).
public final class HTTPServer {
    private let listener: NWListener
    private let handler: (HTTPRequest) -> HTTPResponse
    private let queue = DispatchQueue(label: "deskswitch.http")

    public init(port: UInt16, handler: @escaping (HTTPRequest) -> HTTPResponse) throws {
        self.handler = handler
        self.listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
    }

    public func start() {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.receive(connection, buffer: Data())
        }
        listener.start(queue: queue)
    }

    public func stop() {
        listener.cancel()
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            var accumulated = buffer
            if let data { accumulated.append(data) }
            switch HTTPRequest.parse(accumulated) {
            case .request(let request):
                self.respond(connection, with: self.handler(request))
            case .incomplete:
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.receive(connection, buffer: accumulated)
                }
            case .invalid:
                self.respond(connection, with: .json(400, ["error": "malformed request"]))
            }
        }
    }

    private func respond(_ connection: NWConnection, with response: HTTPResponse) {
        connection.send(content: response.serialized(),
                        completion: .contentProcessed { _ in connection.cancel() })
    }
}
