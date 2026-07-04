import ArgumentParser
import DeskSwitchCore
import Foundation
import ServiceManagement

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    Foundation.exit(1)
}

func loadValidatedConfig() -> Config {
    let config: Config
    do {
        config = try Config.load()
    } catch {
        fail("cannot read \(Config.defaultPath.path): \(error)")
    }
    for issue in config.validate() {
        FileHandle.standardError.write(Data(("config: " + issue.message + "\n").utf8))
    }
    if config.validate().contains(where: { $0.isError }) {
        fail("config invalid — fix the errors above")
    }
    return config
}

/// Peer client with WoL-and-retry on unreachable (degrades to plain errors
/// when peer.mac is unset — config validation already warned about that).
func makePeerClient(config: Config) -> PeerClient {
    let http = HTTPPeerClient(host: config.peer.host, port: config.peer.port, token: config.token)
    return WakingPeerClient(inner: http, wol: makeWoLSender(config: config))
}

func makeRouter(config: Config) -> Router {
    do {
        return Router(config: config, ddc: try IOAVDDCEngine(), peer: makePeerClient(config: config))
    } catch {
        fail("\(error)")
    }
}

struct DeskSwitchCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "deskswitch",
        abstract: "Programmatic monitor input switching between two Macs (DDC/CI).",
        version: deskswitchVersion,
        subcommands: [Status.self, Probe.self, Switch.self, Serve.self, Autostart.self])
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show which Mac drives each monitor.")

    func run() throws {
        let config = loadValidatedConfig()
        let router = makeRouter(config: config)
        let peerStatus = try? makePeerClient(config: config).status()
        print(CommandCore.statusText(local: router.localStatus(), peer: peerStatus))
    }
}

struct Probe: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Record current input codes for displays this Mac drives into config.")

    func run() throws {
        var config = loadValidatedConfig()
        let engine: IOAVDDCEngine
        do {
            engine = try IOAVDDCEngine()
        } catch {
            fail("\(error)")
        }
        var readings: [String: UInt16] = [:]
        for name in try engine.connectedDisplayNames() {
            readings[name] = try engine.readInput(displayName: name)
        }
        guard !readings.isEmpty else {
            print("No external displays driven by this Mac; nothing to probe.")
            return
        }
        config = CommandCore.applyProbe(readings: readings, config: config)
        try config.save()
        print(CommandCore.probeText(readings: readings, machine: config.machineName))
    }
}

struct Switch: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Switch a monitor's input to the given machine.")

    @Argument(help: "Monitor name from config (e.g. M27Q), or 'all' for both monitors.")
    var monitor: String

    @Argument(help: "Target machine name (this machine or the peer).")
    var machine: String

    func run() throws {
        let config = loadValidatedConfig()
        let router = makeRouter(config: config)
        if monitor == "all" {
            var failed = false
            for entry in router.switchAll(to: machine) {
                switch entry.result {
                case .success(let outcome):
                    print("\(entry.monitor): \(outcome == .switchedLocally ? "switched locally" : "forwarded to peer")")
                case .failure(let error):
                    failed = true
                    FileHandle.standardError.write(Data("\(entry.monitor): \(error.userMessage)\n".utf8))
                }
            }
            if failed { throw ExitCode(1) }
            return
        }
        do {
            let outcome = try router.switchMonitor(monitor, to: machine)
            print(outcome == .switchedLocally ? "switched locally" : "forwarded to peer")
        } catch let e as RouterError {
            fail(e.userMessage)
        }
    }
}

struct Serve: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run the HTTP agent (headless mode).")

    func run() throws {
        let config = loadValidatedConfig()
        let router = makeRouter(config: config)
        let handler = APIHandler(router: router, token: config.token)
        let server = try HTTPServer(port: UInt16(config.listenPort)) { handler.handle($0) }
        server.start()
        print("deskswitch \(deskswitchVersion) serving on port \(config.listenPort) as '\(config.machineName)'")
        let sleepTimer = startSleepGuardTimer(config: config, router: router)
        _ = sleepTimer
        RunLoop.main.run()
    }
}

struct Autostart: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage launch-at-login registration (run from inside DeskSwitch.app).")

    @Argument(help: "enable | disable | status")
    var action: String

    func run() throws {
        guard Bundle.main.bundlePath.hasSuffix(".app") else {
            fail("autostart must be run via the installed bundle, e.g. " +
                 "/Applications/DeskSwitch.app/Contents/MacOS/deskswitch autostart \(action)")
        }
        let service = SMAppService.agent(plistName: "com.vuphan.deskswitch.plist")
        switch action {
        case "enable":
            try service.register()
            print("registered (status: \(statusText(service.status)))")
        case "disable":
            try service.unregister()
            print("unregistered")
        case "status":
            print(statusText(service.status))
        default:
            fail("action must be enable, disable, or status")
        }
    }

    private func statusText(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: return "enabled"
        case .notRegistered: return "not registered"
        case .requiresApproval: return "requires approval in System Settings > General > Login Items"
        case .notFound: return "not found"
        @unknown default: return "unknown (\(status.rawValue))"
        }
    }
}
