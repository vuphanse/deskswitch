import Foundation

/// Abstraction over the hardware DDC path so router/UI/CLI logic tests with a mock.
public protocol DDCEngine {
    /// EDID product names of external displays this Mac currently drives.
    func connectedDisplayNames() throws -> [String]
    func readInput(displayName: String) throws -> UInt16
    func setInput(displayName: String, code: UInt16) throws
}

public enum DDC {
    public static let inputSelect: UInt8 = 0x60

    // DDC/CI framing: destination 0x6E, source 0x51; checksum XORs both plus payload.
    private static func checksum(_ payload: [UInt8]) -> UInt8 {
        payload.reduce(UInt8(0x6E ^ 0x51)) { $0 ^ $1 }
    }

    public static func setVCPPacket(code: UInt8, value: UInt16) -> [UInt8] {
        var p: [UInt8] = [0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF)]
        p.append(checksum(p))
        return p
    }

    public static func readVCPRequestPacket(code: UInt8) -> [UInt8] {
        var p: [UInt8] = [0x82, 0x01, code]
        p.append(checksum(p))
        return p
    }

    /// Parses a Get-VCP reply. Monitors differ in whether the buffer starts with the
    /// address/length bytes, so scan for the reply opcode (0x02) with result 0x00 and
    /// the echoed VCP code; the current value is the last two bytes of that record.
    public static func parseVCPReply(_ reply: [UInt8], expectedCode: UInt8) -> UInt16? {
        guard reply.count >= 8 else { return nil }
        for i in 0...(reply.count - 8)
        where reply[i] == 0x02 && reply[i + 1] == 0x00 && reply[i + 2] == expectedCode {
            return UInt16(reply[i + 6]) << 8 | UInt16(reply[i + 7])
        }
        return nil
    }
}
