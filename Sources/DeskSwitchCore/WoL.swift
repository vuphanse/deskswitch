import Foundation

public enum WoLError: Error, Equatable {
    case invalidMAC(String)
    case sendFailed(String)
}

/// Standard Wake-on-LAN magic packet: 6 x 0xFF then the MAC repeated 16 times.
public func wolMagicPacket(mac: String) throws -> Data {
    let parts = mac.split(whereSeparator: { $0 == ":" || $0 == "-" })
    guard parts.count == 6 else { throw WoLError.invalidMAC(mac) }
    let bytes: [UInt8] = try parts.map {
        guard $0.count == 2, let byte = UInt8($0, radix: 16) else {
            throw WoLError.invalidMAC(mac)
        }
        return byte
    }
    var packet = Data(repeating: 0xFF, count: 6)
    for _ in 0..<16 {
        packet.append(contentsOf: bytes)
    }
    return packet
}

public protocol WoLSender {
    func wake() throws
}

/// Sends the magic packet as a UDP broadcast (config: wol.broadcastHost / wol.port).
public struct UDPWoLSender: WoLSender {
    let packet: Data
    let host: String
    let port: UInt16

    public init(packet: Data, host: String, port: UInt16) {
        self.packet = packet
        self.host = host
        self.port = port
    }

    public func wake() throws {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw WoLError.sendFailed("socket() failed") }
        defer { close(fd) }

        var enable: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &enable, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
            throw WoLError.sendFailed("bad broadcast address \(host)")
        }

        let sent = packet.withUnsafeBytes { raw in
            withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, raw.baseAddress, packet.count, 0, sa,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == packet.count else {
            throw WoLError.sendFailed("sendto() sent \(sent) of \(packet.count) bytes")
        }
    }
}

/// Builds a sender from config; nil when peer.mac is unset (WoL degrades off — spec).
public func makeWoLSender(config: Config) -> WoLSender? {
    guard let mac = config.peer.mac, let packet = try? wolMagicPacket(mac: mac) else {
        return nil
    }
    return UDPWoLSender(packet: packet, host: config.wol.broadcastHost,
                        port: UInt16(config.wol.port))
}

/// Decorator implementing the spec's peer-unreachable behavior: send the WoL magic
/// packet when a sender is configured, wait for the peer to wake, then retry once.
/// When peer.mac is unset there is no sender — the magic packet is skipped but the
/// single retry still happens after a short delay (spec: degrade to retry + notification).
public final class WakingPeerClient: PeerClient {
    private let inner: PeerClient
    private let wol: WoLSender?
    private let wakeDelay: TimeInterval
    private let retryDelay: TimeInterval
    private let sleeper: (TimeInterval) -> Void

    public init(inner: PeerClient, wol: WoLSender?, wakeDelay: TimeInterval = 3.0,
                retryDelay: TimeInterval = 0.5,
                sleeper: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.inner = inner
        self.wol = wol
        self.wakeDelay = wakeDelay
        self.retryDelay = retryDelay
        self.sleeper = sleeper
    }

    public func status() throws -> LocalStatus {
        try retrying { try inner.status() }
    }

    public func requestSwitch(monitor: String, target: String, forwarded: Bool) throws {
        try retrying { try inner.requestSwitch(monitor: monitor, target: target, forwarded: forwarded) }
    }

    private func retrying<T>(_ operation: () throws -> T) throws -> T {
        do {
            return try operation()
        } catch PeerClientError.unreachable {
            // Spec error table: send WoL (skipped when peer.mac is unset), then retry
            // once EITHER WAY; only the wait differs (wake cycle vs brief backoff).
            if let wol {
                try? wol.wake()
                sleeper(wakeDelay)
            } else {
                sleeper(retryDelay)
            }
            return try operation()
        }
    }
}
