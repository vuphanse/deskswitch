import Foundation

public struct ValidationIssue: Equatable {
    public let message: String
    public let isError: Bool
    public init(message: String, isError: Bool) {
        self.message = message
        self.isError = isError
    }
}

public struct Config: Codable, Equatable {
    public var machineName: String
    public var peer: Peer
    public var wol: WoL
    public var token: String
    public var listenPort: Int
    public var monitors: [String: Monitor]
    public var preventSleepWhenHeadless: Bool

    public struct Peer: Codable, Equatable {
        public var name: String
        public var host: String
        public var port: Int
        public var mac: String?
        public init(name: String, host: String, port: Int, mac: String? = nil) {
            self.name = name
            self.host = host
            self.port = port
            self.mac = mac
        }
    }

    public struct WoL: Codable, Equatable {
        public var broadcastHost: String
        public var port: Int
        public init(broadcastHost: String = "255.255.255.255", port: Int = 9) {
            self.broadcastHost = broadcastHost
            self.port = port
        }
    }

    public struct Monitor: Codable, Equatable {
        public var inputs: [String: UInt16]
        public init(inputs: [String: UInt16]) {
            self.inputs = inputs
        }
    }

    public init(machineName: String, peer: Peer, wol: WoL = WoL(), token: String,
                listenPort: Int = 8377, monitors: [String: Monitor] = [:],
                preventSleepWhenHeadless: Bool = false) {
        self.machineName = machineName
        self.peer = peer
        self.wol = wol
        self.token = token
        self.listenPort = listenPort
        self.monitors = monitors
        self.preventSleepWhenHeadless = preventSleepWhenHeadless
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        machineName = try c.decode(String.self, forKey: .machineName)
        peer = try c.decode(Peer.self, forKey: .peer)
        wol = try c.decodeIfPresent(WoL.self, forKey: .wol) ?? WoL()
        token = try c.decode(String.self, forKey: .token)
        listenPort = try c.decodeIfPresent(Int.self, forKey: .listenPort) ?? 8377
        monitors = try c.decodeIfPresent([String: Monitor].self, forKey: .monitors) ?? [:]
        preventSleepWhenHeadless = try c.decodeIfPresent(Bool.self, forKey: .preventSleepWhenHeadless) ?? false
    }

    public var wolEnabled: Bool { peer.mac != nil }

    public func inputCode(monitor: String, machine: String) -> UInt16? {
        monitors[monitor]?.inputs[machine]
    }

    public func owner(of monitor: String, currentCode: UInt16) -> String? {
        monitors[monitor]?.inputs.first(where: { $0.value == currentCode })?.key
    }

    public func validate() -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        if machineName.isEmpty {
            issues.append(.init(message: "machineName must not be empty", isError: true))
        }
        if peer.name == machineName {
            issues.append(.init(message: "peer.name must differ from machineName", isError: true))
        }
        if !(1...65535).contains(peer.port) {
            issues.append(.init(message: "peer.port must be 1-65535", isError: true))
        }
        if !(1...65535).contains(listenPort) {
            issues.append(.init(message: "listenPort must be 1-65535", isError: true))
        }
        if !(1...65535).contains(wol.port) {
            issues.append(.init(message: "wol.port must be 1-65535", isError: true))
        }
        if peer.host.isEmpty || peer.host.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) == nil {
            issues.append(.init(message: "peer.host must be a valid hostname or IP: '\(peer.host)'", isError: true))
        }
        if token.isEmpty {
            issues.append(.init(message: "token must not be empty", isError: true))
        }
        if let mac = peer.mac {
            let pattern = "^[0-9A-Fa-f]{2}([:-][0-9A-Fa-f]{2}){5}$"
            if mac.range(of: pattern, options: .regularExpression) == nil {
                issues.append(.init(message: "peer.mac is not a valid MAC address: \(mac)", isError: true))
            }
        } else {
            issues.append(.init(
                message: "Wake-on-LAN disabled: peer.mac not set (peer-unreachable handling degrades to retry + notification)",
                isError: false))
        }
        return issues
    }

    public static var defaultPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/deskswitch/config.json")
    }

    public static func load(from url: URL = defaultPath) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL = Config.defaultPath) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
