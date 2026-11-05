import Foundation

enum ITunesDBError: LocalizedError {
    case malformed(String)
    case unsupported(String)
    case noDatabase

    var errorDescription: String? {
        switch self {
        case .malformed(let why):
            return "The iPod's iTunesDB could not be read: \(why)"
        case .unsupported(let why):
            return why
        case .noDatabase:
            return "This iPod has no iTunesDB yet. Restore it with Finder first so the device creates a valid empty database."
        }
    }
}

// One node of the iTunesDB tree (mhbd, mhsd, mhlt, mhit, mhod, ...).
//
// The tree is deliberately lossless: unknown header bytes, unknown trailing bytes and opaque
// datasets are kept verbatim. Firmware reads fields that no public spec explains, so zeroing or
// dropping them on write is the most likely way to turn a working library into an empty one.
final class DBChunk {
    var magic: String
    var header: Data
    // Leaf payload (MHOD data after its 24-byte header). Empty for container chunks.
    var body: Data
    var children: [DBChunk]
    // Bytes inside a container's extent that no child consumed (e.g. opaque dataset payloads).
    var trailing: Data

    init(magic: String, header: Data, body: Data = Data(), children: [DBChunk] = [], trailing: Data = Data()) {
        self.magic = magic
        self.header = header
        self.body = body
        self.children = children
        self.trailing = trailing
    }

    // List chunks store an item count at +0x08 instead of a total byte length, so their extent
    // is only knowable by parsing `count` children.
    static let listMagics: Set<String> = ["mhlt", "mhlp", "mhla", "mhli"]
    static let containerMagics: Set<String> = ["mhbd", "mhsd", "mhit", "mhyp", "mhip", "mhia"]

    // MARK: Parse

    static func parse(_ data: Data, at offset: Int) throws -> (chunk: DBChunk, end: Int) {
        guard let magic = readMagic(data, at: offset),
              let headerLength = data.readLE(UInt32.self, at: offset + 4),
              let third = data.readLE(UInt32.self, at: offset + 8) else {
            throw ITunesDBError.malformed("truncated chunk header at offset \(offset)")
        }
        let hl = Int(headerLength)
        guard hl >= 12, offset + hl <= data.count else {
            throw ITunesDBError.malformed("\(magic) header length \(hl) out of range at offset \(offset)")
        }
        let header = Data(data[(data.startIndex + offset)..<(data.startIndex + offset + hl)])

        if listMagics.contains(magic) {
            var position = offset + hl
            var kids: [DBChunk] = []
            for _ in 0..<Int(third) {
                let (kid, next) = try parse(data, at: position)
                kids.append(kid)
                position = next
            }
            return (DBChunk(magic: magic, header: header, children: kids), position)
        }

        let total = Int(third)
        guard total >= hl, offset + total <= data.count else {
            throw ITunesDBError.malformed("\(magic) total length \(total) out of range at offset \(offset)")
        }
        let end = offset + total

        guard containerMagics.contains(magic) else {
            let body = Data(data[(data.startIndex + offset + hl)..<(data.startIndex + end)])
            return (DBChunk(magic: magic, header: header, body: body), end)
        }

        var position = offset + hl
        var kids: [DBChunk] = []
        while end - position >= 12, looksLikeChunk(data, at: position) {
            let (kid, next) = try parse(data, at: position)
            guard next > position, next <= end else {
                throw ITunesDBError.malformed("\(kid.magic) overruns its parent at offset \(position)")
            }
            kids.append(kid)
            position = next
        }
        let trailing = Data(data[(data.startIndex + position)..<(data.startIndex + end)])
        return (DBChunk(magic: magic, header: header, children: kids, trailing: trailing), end)
    }

    private static func readMagic(_ data: Data, at offset: Int) -> String? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        let bytes = (0..<4).map { data[data.startIndex + offset + $0] }
        guard bytes.allSatisfy({ $0 >= 0x61 && $0 <= 0x7A }) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    // Opaque dataset payloads can start with arbitrary bytes; only descend into things that
    // carry the "mh" prefix every known chunk uses.
    private static func looksLikeChunk(_ data: Data, at offset: Int) -> Bool {
        guard let magic = readMagic(data, at: offset) else { return false }
        return magic.hasPrefix("mh")
    }

    // MARK: Serialize

    // Lengths and child counts are recomputed here, in one place, so edits elsewhere only ever
    // add or remove children and never have to keep counters consistent by hand.
    func serialized() -> Data {
        var kids = Data()
        for child in children { kids.append(child.serialized()) }
        var out = header

        if DBChunk.listMagics.contains(magic) {
            out.writeLE(UInt32(children.count), at: 8)
            out.append(kids)
            return out
        }

        out.writeLE(UInt32(header.count + body.count + kids.count + trailing.count), at: 8)
        switch magic {
        case "mhbd" where out.hasField(at: 0x14, size: 4):
            out.writeLE(UInt32(children.count), at: 0x14)
        case "mhit", "mhip", "mhia":
            out.writeLE(UInt32(children.count), at: 0x0C)
        case "mhyp":
            out.writeLE(UInt32(children.filter { $0.magic == "mhod" }.count), at: 0x0C)
            out.writeLE(UInt32(children.filter { $0.magic == "mhip" }.count), at: 0x10)
        default:
            break
        }
        out.append(body)
        out.append(kids)
        out.append(trailing)
        return out
    }
}
