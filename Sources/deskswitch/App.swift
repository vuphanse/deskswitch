import AppKit
import DeskSwitchCore
import SwiftUI

// Compiler-forced addition (not in the brief): `Result`'s `Failure` generic
// parameter requires `Error` conformance, and `String` does not conform to
// `Error` in the standard library. Without this, `Result<..., String>` below
// fails to compile. This is the minimal fix that keeps the brief's
// `Result<(MenuState, HTTPServer, Config), String>` signature verbatim.
extension String: @retroactive Error {}

/// Builds the full object graph for app mode. Failure produces an error the
/// menu can display instead of crashing at launch.
enum Bootstrap {
    static func make() -> Result<(MenuState, HTTPServer, Config), String> {
        do {
            let config = try Config.load()
            let issues = config.validate()
            if let firstError = issues.first(where: { $0.isError }) {
                return .failure(firstError.message)
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
            // Task 17 replaces StderrNotifier with UserNotifier here.
            let state = MenuState(config: config, router: router, peer: peer,
                                  notifier: StderrNotifier())
            return .success((state, server, config))
        } catch {
            return .failure("\(error)")
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
            case .failure(let message):
                Text("deskswitch failed to start")
                Text(message)
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
            // Task 18 adds "Bring both here" / "Send both away" actions here.
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
