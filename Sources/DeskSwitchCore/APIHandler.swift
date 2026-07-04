import Foundation

public struct SwitchRequest: Codable, Equatable {
    public var monitor: String
    public var target: String
    public var forwarded: Bool

    public init(monitor: String, target: String, forwarded: Bool = false) {
        self.monitor = monitor
        self.target = target
        self.forwarded = forwarded
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        monitor = try c.decode(String.self, forKey: .monitor)
        target = try c.decode(String.self, forKey: .target)
        forwarded = try c.decodeIfPresent(Bool.self, forKey: .forwarded) ?? false
    }
}

public struct APIHandler {
    private let router: Router
    private let token: String

    public init(router: Router, token: String) {
        self.router = router
        self.token = token
    }

    public func handle(_ req: HTTPRequest) -> HTTPResponse {
        guard req.headers["x-deskswitch-token"] == token else {
            return .json(401, ["error": "missing or invalid X-DeskSwitch-Token header"])
        }
        switch (req.method, req.path) {
        case ("GET", "/status"):
            return .json(200, router.localStatus())
        case ("POST", "/switch"):
            guard let sw = try? JSONDecoder().decode(SwitchRequest.self, from: req.body) else {
                return .json(400, ["error": #"body must be {"monitor": "<name>", "target": "<machine>"}"#])
            }
            do {
                let outcome = try router.switchMonitor(sw.monitor, to: sw.target,
                                                       allowForward: !sw.forwarded)
                return .json(200, ["outcome": outcome == .switchedLocally ? "switched-locally" : "forwarded"])
            } catch let e as RouterError {
                return .json(Self.status(for: e), ["error": e.userMessage])
            } catch {
                return .json(500, ["error": "\(error)"])
            }
        default:
            return .json(404, ["error": "not found"])
        }
    }

    public static func status(for error: RouterError) -> Int {
        switch error {
        case .unknownMonitor: return 404
        case .missingInputCode: return 422
        case .nobodyDrives: return 409
        case .peerUnreachable: return 502
        case .ddcFailure: return 500
        }
    }
}
