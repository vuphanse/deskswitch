import Foundation

public struct MonitorStatus: Codable, Equatable {
    public let name: String
    public let inputCode: UInt16
    public let owner: String?
    public init(name: String, inputCode: UInt16, owner: String?) {
        self.name = name
        self.inputCode = inputCode
        self.owner = owner
    }
}

public struct LocalStatus: Codable, Equatable {
    public let machine: String
    public let monitors: [MonitorStatus]
    public init(machine: String, monitors: [MonitorStatus]) {
        self.machine = machine
        self.monitors = monitors
    }
}

public enum SwitchOutcome: Equatable {
    case switchedLocally
    case forwarded
}

public enum RouterError: Error, Equatable {
    case unknownMonitor(String)
    case missingInputCode(monitor: String, machine: String)
    case nobodyDrives(String)
    case peerUnreachable
    case ddcFailure(String)

    public var userMessage: String {
        switch self {
        case .unknownMonitor(let m):
            return "unknown monitor '\(m)' — not present in config"
        case .missingInputCode(let m, let machine):
            return "no input code for monitor '\(m)' / machine '\(machine)' — run `deskswitch probe` on the machine that drives it"
        case .nobodyDrives(let m):
            return "no machine currently drives '\(m)'"
        case .peerUnreachable:
            return "other Mac offline"
        case .ddcFailure(let detail):
            return "DDC write failed: \(detail)"
        }
    }
}

public struct Router {
    private let config: Config
    private let ddc: DDCEngine
    private let peer: PeerClient

    public init(config: Config, ddc: DDCEngine, peer: PeerClient) {
        self.config = config
        self.ddc = ddc
        self.peer = peer
    }

    public func localStatus() -> LocalStatus {
        let names = (try? ddc.connectedDisplayNames()) ?? []
        let monitors: [MonitorStatus] = names.sorted().compactMap { name in
            guard let code = try? ddc.readInput(displayName: name) else { return nil }
            return MonitorStatus(name: name, inputCode: code,
                                 owner: config.owner(of: name, currentCode: code))
        }
        return LocalStatus(machine: config.machineName, monitors: monitors)
    }

    /// Spec routing rules: drive locally → DDC write; else forward once to the peer;
    /// a request that was already forwarded must not bounce back (nobodyDrives).
    public func switchMonitor(_ monitor: String, to target: String,
                              allowForward: Bool = true) throws -> SwitchOutcome {
        guard config.monitors[monitor] != nil else {
            throw RouterError.unknownMonitor(monitor)
        }
        let local = (try? ddc.connectedDisplayNames()) ?? []
        if local.contains(monitor) {
            guard let code = config.inputCode(monitor: monitor, machine: target) else {
                throw RouterError.missingInputCode(monitor: monitor, machine: target)
            }
            do {
                try ddc.setInput(displayName: monitor, code: code)
            } catch {
                throw RouterError.ddcFailure("\(error)")
            }
            return .switchedLocally
        }
        guard allowForward else {
            throw RouterError.nobodyDrives(monitor)
        }
        do {
            try peer.requestSwitch(monitor: monitor, target: target, forwarded: true)
            return .forwarded
        } catch PeerClientError.unreachable {
            throw RouterError.peerUnreachable
        } catch let PeerClientError.remote(status, message) {
            if status == 409 { throw RouterError.nobodyDrives(monitor) }
            throw RouterError.ddcFailure(message)
        }
    }

    public func switchAll(to target: String) -> [(monitor: String, result: Result<SwitchOutcome, RouterError>)] {
        config.monitors.keys.sorted().map { monitor in
            do {
                return (monitor, .success(try switchMonitor(monitor, to: target)))
            } catch let e as RouterError {
                return (monitor, .failure(e))
            } catch {
                return (monitor, .failure(.ddcFailure("\(error)")))
            }
        }
    }
}
