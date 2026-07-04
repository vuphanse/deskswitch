import AppKit
import DeskSwitchCore
import SwiftUI

/// Wraps a human-readable startup failure so it can travel through `Result`
/// (whose `Failure` parameter requires `Error`, which `String` does not satisfy).
struct BootstrapError: Error {
    let message: String
}

/// Builds the full object graph for app mode. Failure produces an error the
/// menu can display instead of crashing at launch.
enum Bootstrap {
    static func make() -> Result<(MenuState, HTTPServer, Config), BootstrapError> {
        do {
            let config = try Config.load()
            let issues = config.validate()
            if let firstError = issues.first(where: { $0.isError }) {
                return .failure(BootstrapError(message: firstError.message))
            }
            for warning in issues where !warning.isError {
                FileHandle.standardError.write(Data(("config: " + warning.message + "\n").utf8))
            }
            let engine = try IOAVDDCEngine()
            let peer = makePeerClient(config: config)
            let router = Router(config: config, ddc: engine, peer: peer)
            let handler = APIHandler(router: router, token: config.token)
            let server = try HTTPServer(port: UInt16(config.listenPort)) { handler.handle($0) }
            server.start()
            let state = MenuState(config: config, router: router, peer: peer,
                                  notifier: UserNotifier())
            return .success((state, server, config))
        } catch {
            return .failure(BootstrapError(message: "\(error)"))
        }
    }
}

struct DeskSwitchApp: App {
    private let boot = Bootstrap.make()

    var body: some Scene {
        MenuBarExtra("DeskSwitch", systemImage: "display.2") {
            switch boot {
            case .success(let (state, _, config)):
                MenuContent(state: state,
                            machineName: config.machineName,
                            peerName: config.peer.name)
            case .failure(let error):
                Text("deskswitch failed to start")
                Text(error.message)
                Divider()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuContent: View {
    @ObservedObject var state: MenuState
    let machineName: String
    let peerName: String

    var body: some View {
        Group {
            ForEach(state.rows) { row in
                if row.owner == machineName {
                    Button("\(row.name): here — send to \(peerName)") {
                        state.send(row.name, to: peerName)
                    }
                } else if row.owner == peerName {
                    Button("\(row.name): on \(peerName) — bring here") {
                        state.send(row.name, to: machineName)
                    }
                } else {
                    Text("\(row.name): unknown")
                }
            }
            Divider()
            Button("Bring both here") { state.bringAllHere() }
            Button("Send both away") { state.sendAllAway() }
            if let error = state.lastError {
                Divider()
                Text(error)
            }
            Divider()
            Button("Quit deskswitch") { NSApp.terminate(nil) }
        }
        .onAppear { state.refresh() }  // spec: refresh when menu opens; MenuState
                                       // dispatches off-main internally, as do the
                                       // button actions above — no main-thread network
    }
}
