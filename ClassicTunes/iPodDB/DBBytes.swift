import Foundation

// iTunesDB is little-endian throughout, while iTunesSD (Shuffle 1G/2G) is big-endian.
// Keeping the readers separate from the Shuffle codec means a call site can't silently
// pick up the wrong byte order when the two formats are handled side by side.
extension Data {
    // Returns nil instead of trapping so a truncated or hostile database on a removable
    // volume surfaces as a thrown parse error rather than crashing the app.
    func readLE<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T? {
        let size = MemoryLayout<T>.size
        guard offset >= 0, offset + size <= count else { return nil }
        var value: T = 0
        for i in 0..<size {
            value |= T(truncatingIfNeeded: self[startIndex + offset + i]) << (8 * i)
        }
        return value
    }

    // Callers that patch header fields guard on header length first, because header sizes
    // differ between iPod generations and a field may legitimately not exist on older models.
    mutating func writeLE<T: FixedWidthInteger>(_ value: T, at offset: Int) {
        let size = MemoryLayout<T>.size
        precondition(offset >= 0 && offset + size <= count, "iTunesDB field write out of range")
        for i in 0..<size {
            self[startIndex + offset + i] = UInt8(truncatingIfNeeded: value >> (8 * i))
        }
    }

    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        for i in 0..<MemoryLayout<T>.size {
            append(UInt8(truncatingIfNeeded: value >> (8 * i)))
        }
    }

    // True when `offset...offset+size` lies inside the buffer; used to skip fields that an
    // older, shorter header layout does not contain.
    func hasField(at offset: Int, size: Int) -> Bool {
        offset + size <= count
    }
}
