import Foundation

public enum PeerClientError: Error, Equatable {
    case unreachable
    case remote(status: Int, message: String)
}

public protocol PeerClient {
    func status() throws -> LocalStatus
    func requestSwitch(monitor: String, target: String, forwarded: Bool) throws
}

/// M1 stand-in until the HTTP client exists: every peer call fails as unreachable.
public struct UnreachablePeerClient: PeerClient {
    public init() {}
    public func status() throws -> LocalStatus { throw PeerClientError.unreachable }
    public func requestSwitch(monitor: String, target: String, forwarded: Bool) throws {
        throw PeerClientError.unreachable
    }
}
