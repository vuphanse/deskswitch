import Foundation

/// Extracts the display product name (descriptor tag 0xFC) from a raw EDID block.
/// Descriptor slots live at offsets 54, 72, 90, 108; a display descriptor starts
/// with two zero bytes, a zero, the tag, a zero, then 13 bytes of text terminated
/// by 0x0A and padded with 0x20.
public func edidDisplayName(_ data: Data) -> String? {
    guard data.count >= 128 else { return nil }
    let bytes = [UInt8](data)  // normalize: Data slices carry nonzero startIndex
    for offset in [54, 72, 90, 108] {
        guard bytes[offset] == 0, bytes[offset + 1] == 0, bytes[offset + 2] == 0,
              bytes[offset + 3] == 0xFC else { continue }
        let raw = bytes[(offset + 5)..<(offset + 18)]
        let text = String(decoding: raw, as: UTF8.self)
        let name = (text.split(separator: "\n").first.map(String.init) ?? text)
            .trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
    return nil
}
