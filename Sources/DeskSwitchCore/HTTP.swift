import Foundation

public enum ParseResult: Equatable {
    case incomplete
    case invalid
    case request(HTTPRequest)
}

public struct HTTPRequest: Equatable {
    public var method: String
    public var path: String
    public var headers: [String: String]  // keys lowercased
    public var body: Data

    public static func parse(_ data: Data) -> ParseResult {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > 64 * 1024 ? .invalid : .incomplete
        }
        guard let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else {
            return .invalid
        }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count == 3 else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            let key = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        guard data.count - bodyStart >= length else { return .incomplete }
        let body = data.subdata(in: bodyStart..<(bodyStart + length))
        return .request(HTTPRequest(method: String(requestLine[0]),
                                    path: String(requestLine[1]),
                                    headers: headers, body: body))
    }
}

public struct HTTPResponse: Equatable {
    public var status: Int
    public var body: Data

    public static func json(_ status: Int, _ value: some Encodable) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return HTTPResponse(status: status, body: (try? encoder.encode(value)) ?? Data("{}".utf8))
    }

    public func serialized() -> Data {
        let reasons = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found",
                       409: "Conflict", 422: "Unprocessable Entity", 500: "Internal Server Error",
                       502: "Bad Gateway"]
        var out = Data("HTTP/1.1 \(status) \(reasons[status] ?? "Error")\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        out.append(body)
        return out
    }
}
