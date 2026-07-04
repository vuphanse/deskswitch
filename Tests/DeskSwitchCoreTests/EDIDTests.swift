import XCTest
@testable import DeskSwitchCore

final class EDIDTests: XCTestCase {
    /// Builds a 128-byte EDID block with a display-product-name descriptor (tag 0xFC)
    /// at the given descriptor slot offset (54, 72, 90, or 108).
    func makeEDID(name: String, at offset: Int = 54) -> Data {
        var edid = Data(repeating: 0, count: 128)
        edid[offset + 3] = 0xFC
        var text = Array((name + "\n").utf8)
        while text.count < 13 { text.append(0x20) }
        for (i, b) in text.prefix(13).enumerated() { edid[offset + 5 + i] = b }
        return edid
    }

    func testParsesNameFromFirstDescriptor() {
        XCTAssertEqual(edidDisplayName(makeEDID(name: "M27Q")), "M27Q")
    }

    func testParsesNameFromLaterDescriptor() {
        XCTAssertEqual(edidDisplayName(makeEDID(name: "PA278CV", at: 90)), "PA278CV")
    }

    func testTrimsPadding() {
        XCTAssertEqual(edidDisplayName(makeEDID(name: "M27Q ")), "M27Q")
    }

    func testReturnsNilWithoutNameDescriptor() {
        XCTAssertNil(edidDisplayName(Data(repeating: 0, count: 128)))
    }

    func testReturnsNilForShortData() {
        XCTAssertNil(edidDisplayName(Data(repeating: 0, count: 10)))
    }

    func testParsesNameFromDataSlice() {
        // Data slices keep the parent's indices; the parser must not assume startIndex 0.
        var padded = Data(repeating: 0xEE, count: 10)
        padded.append(makeEDID(name: "M27Q"))
        let slice = padded[10...]
        XCTAssertEqual(edidDisplayName(slice), "M27Q")
    }
}
