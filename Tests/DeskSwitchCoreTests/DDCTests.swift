import XCTest
@testable import DeskSwitchCore

final class DDCTests: XCTestCase {
    func testSetVCPPacketLayoutAndChecksum() {
        let p = DDC.setVCPPacket(code: 0x60, value: 17)
        XCTAssertEqual(Array(p.prefix(5)), [0x84, 0x03, 0x60, 0x00, 0x11])
        // Checksum XORs destination (0x6E), source (0x51), and all payload bytes.
        let expected = p.prefix(5).reduce(UInt8(0x6E ^ 0x51)) { $0 ^ $1 }
        XCTAssertEqual(p[5], expected)
        XCTAssertEqual(p.count, 6)
    }

    func testSetVCPPacketSplitsValueBytes() {
        let p = DDC.setVCPPacket(code: 0x60, value: 0x0102)
        XCTAssertEqual(p[3], 0x01)
        XCTAssertEqual(p[4], 0x02)
    }

    func testReadVCPRequestPacket() {
        let p = DDC.readVCPRequestPacket(code: 0x60)
        XCTAssertEqual(Array(p.prefix(3)), [0x82, 0x01, 0x60])
        let expected = p.prefix(3).reduce(UInt8(0x6E ^ 0x51)) { $0 ^ $1 }
        XCTAssertEqual(p[3], expected)
    }

    func testParseVCPReplyExtractsCurrentValue() {
        // opcode 0x02, result 0x00, code 0x60, type, maxH, maxL, curH, curL
        let reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x60, 0x00, 0x00, 0x1B, 0x00, 0x0F, 0x00, 0x00]
        XCTAssertEqual(DDC.parseVCPReply(reply, expectedCode: 0x60), 15)
    }

    func testParseVCPReplyToleratesMissingAddressPrefix() {
        let reply: [UInt8] = [0x88, 0x02, 0x00, 0x60, 0x00, 0x00, 0x1B, 0x00, 0x1B, 0x00, 0x00]
        XCTAssertEqual(DDC.parseVCPReply(reply, expectedCode: 0x60), 27)
    }

    func testParseVCPReplyRejectsWrongCodeOrError() {
        let wrongCode: [UInt8] = [0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32, 0x00, 0x00]
        XCTAssertNil(DDC.parseVCPReply(wrongCode, expectedCode: 0x60))
        let errorResult: [UInt8] = [0x88, 0x02, 0x01, 0x60, 0x00, 0x00, 0x1B, 0x00, 0x0F, 0x00, 0x00]
        XCTAssertNil(DDC.parseVCPReply(errorResult, expectedCode: 0x60))
        XCTAssertNil(DDC.parseVCPReply([0x02, 0x00], expectedCode: 0x60))
    }
}
