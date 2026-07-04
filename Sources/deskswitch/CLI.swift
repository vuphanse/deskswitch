import ArgumentParser
import DeskSwitchCore
import Foundation

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

/// Peer client factory. M1: no HTTP client yet, so the peer is always unreachable.
/// (Task 12 swaps in HTTPPeerClient; Task 16 wraps it in WakingPeerClient.)
func makePeerClient(config: Config) -> PeerClient {
    UnreachablePeerClient()
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
        subcommands: [Status.self, Probe.self, Switch.self])
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

    @Argument(help: "Monitor name from config (e.g. M27Q).")
    var monitor: String

    @Argument(help: "Target machine name (this machine or the peer).")
    var machine: String

    func run() throws {
        let config = loadValidatedConfig()
        do {
            let outcome = try makeRouter(config: config).switchMonitor(monitor, to: machine)
            print(outcome == .switchedLocally ? "switched locally" : "forwarded to peer")
        } catch let e as RouterError {
            fail(e.userMessage)
        }
    }
}
