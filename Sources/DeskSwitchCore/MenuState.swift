import Combine
import Foundation

public struct MonitorRow: Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let owner: String?
    public init(name: String, owner: String?) {
        self.name = name
        self.owner = owner
    }
}

/// Resolves each configured monitor's owner: this machine if it drives it,
/// the peer if the peer reports it, else unknown (nil).
public func buildRows(config: Config, localStatus: LocalStatus,
                      peerStatus: LocalStatus?) -> [MonitorRow] {
    config.monitors.keys.sorted().map { name in
        let owner: String?
        if localStatus.monitors.contains(where: { $0.name == name }) {
            owner = config.machineName
        } else if peerStatus?.monitors.contains(where: { $0.name == name }) == true {
            owner = config.peer.name
        } else {
            owner = nil
        }
        return MonitorRow(name: name, owner: owner)
    }
}

public final class MenuState: ObservableObject {
    @Published public private(set) var rows: [MonitorRow] = []
    @Published public private(set) var lastError: String?

    private let config: Config
    private let router: Router
    private let peer: PeerClient
    private let notifier: Notifier
    private let runAsync: (@escaping () -> Void) -> Void
    private let publish: (@escaping () -> Void) -> Void

    /// Spec rule: the UI never blocks the main thread on network. Every public action
    /// dispatches its work through `runAsync` (default: background queue) and hops
    /// published-state mutations back through `publish` (default: main queue). Tests
    /// inject `{ $0() }` for both to run fully synchronously.
    public init(config: Config, router: Router, peer: PeerClient, notifier: Notifier,
                runAsync: @escaping (@escaping () -> Void) -> Void =
                    { DispatchQueue.global(qos: .userInitiated).async(execute: $0) },
                publish: @escaping (@escaping () -> Void) -> Void =
                    { DispatchQueue.main.async(execute: $0) }) {
        self.config = config
        self.router = router
        self.peer = peer
        self.notifier = notifier
        self.runAsync = runAsync
        self.publish = publish
    }

    /// Spec: refresh happens when the menu opens; no background polling.
    public func refresh() {
        runAsync { [weak self] in self?.performRefresh() }
    }

    public func send(_ monitor: String, to machine: String) {
        runAsync { [weak self] in self?.performSend(monitor, to: machine) }
    }

    /// Local DDC read + one peer status call (2 s budget) — always off-main via runAsync.
    private func performRefresh() {
        let local = router.localStatus()
        let peerStatus = try? peer.status()
        let rows = buildRows(config: config, localStatus: local, peerStatus: peerStatus)
        let error = peerStatus == nil ? "\(config.peer.name) unreachable" : nil
        publish { [weak self] in
            self?.rows = rows
            self?.lastError = error
        }
    }

    private func performSend(_ monitor: String, to machine: String) {
        do {
            _ = try router.switchMonitor(monitor, to: machine)
            performRefresh()
        } catch {
            let message = (error as? RouterError)?.userMessage ?? "\(error)"
            publish { [weak self] in self?.lastError = message }
            notifier.notify(title: "deskswitch", body: message)
        }
    }

    public func bringAllHere() {
        runAsync { [weak self] in
            guard let self else { return }
            self.performSwitchAll(to: self.config.machineName)
        }
    }

    public func sendAllAway() {
        runAsync { [weak self] in
            guard let self else { return }
            self.performSwitchAll(to: self.config.peer.name)
        }
    }

    private func performSwitchAll(to target: String) {
        let failures = router.switchAll(to: target).compactMap { entry -> String? in
            guard case .failure(let error) = entry.result else { return nil }
            return "\(entry.monitor): \(error.userMessage)"
        }
        // performRefresh publishes lastError from peer reachability; the switch failure
        // (the more specific message) is published after it so it wins.
        performRefresh()
        if let first = failures.first {
            publish { [weak self] in self?.lastError = first }
            notifier.notify(title: "deskswitch", body: first)
        }
    }
}
