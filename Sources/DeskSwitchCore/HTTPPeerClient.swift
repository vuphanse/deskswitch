import Foundation

public final class HTTPPeerClient: PeerClient {
    private let baseURL: URL
    private let token: String
    private let session: URLSession

    public init(host: String, port: Int, token: String) {
        self.baseURL = URL(string: "http://\(host):\(port)")!
        self.token = token
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2.0   // spec: 2 s budget per hop
        configuration.timeoutIntervalForResource = 2.0
        self.session = URLSession(configuration: configuration)
    }

    public func status() throws -> LocalStatus {
        let (status, data) = try send(path: "/status", method: "GET", body: nil)
        do {
            return try JSONDecoder().decode(LocalStatus.self, from: data)
        } catch {
            throw PeerClientError.remote(status: status, message: "undecodable status payload")
        }
    }

    public func requestSwitch(monitor: String, target: String, forwarded: Bool) throws {
        let body = try? JSONEncoder().encode(
            SwitchRequest(monitor: monitor, target: target, forwarded: forwarded))
        _ = try send(path: "/switch", method: "POST", body: body)
    }

    private func send(path: String, method: String, body: Data?) throws -> (status: Int, data: Data) {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.httpBody = body
        request.setValue(token, forHTTPHeaderField: "X-DeskSwitch-Token")

        let semaphore = DispatchSemaphore(value: 0)
        var result: (data: Data?, response: URLResponse?, error: Error?)
        session.dataTask(with: request) {
            result = ($0, $1, $2)
            semaphore.signal()
        }.resume()
        semaphore.wait()

        guard result.error == nil,
              let http = result.response as? HTTPURLResponse,
              let data = result.data else {
            throw PeerClientError.unreachable
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
                ?? "peer returned \(http.statusCode)"
            throw PeerClientError.remote(status: http.statusCode, message: message)
        }
        return (http.statusCode, data)
    }
}
