import Foundation
import CryptoKit

// HASH58 signing for iTunesDB files (iPod Classic, Nano 3G and Nano 4G). The firmware ignores a
// database whose mhbd header lacks the HMAC-SHA1 of the file keyed from the device's FireWire
// GUID, so an unsigned library shows up empty.
enum ITunesDBSigning {
    static let databaseIDOffset = 0x18
    static let hashingSchemeOffset = 0x30
    static let unknown32Offset = 0x32
    static let hash58Offset = 0x58

    enum SigningError: LocalizedError {
        case tooSmall
        case badGUID

        var errorDescription: String? {
            switch self {
            case .tooSmall: return "The iTunesDB is too small to sign."
            case .badGUID: return "The iPod's FireWire GUID could not be read, so its database cannot be signed."
            }
        }
    }

    // Accepts 16 hex digits, optionally prefixed with "0x".
    static func parseGUID(_ text: String) -> Data? {
        var hex = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.lowercased().hasPrefix("0x") { hex.removeFirst(2) }
        return hexBytes(hex, count: 8)
    }

    private static func hexBytes(_ hex: String, count: Int) -> Data? {
        guard hex.count == count * 2 else { return nil }
        var bytes = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    // SysInfoExtended carries "FireWireGUID"; the older SysInfo file has a "FirewireGuid:" line.
    static func firewireGUID(base: URL) -> Data? {
        let device = base.appendingPathComponent("iPod_Control/Device")
        if let data = try? Data(contentsOf: device.appendingPathComponent("SysInfoExtended")),
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
           let text = plist["FireWireGUID"] as? String, let guid = parseGUID(text) {
            return guid
        }
        if let text = try? String(contentsOf: device.appendingPathComponent("SysInfo"), encoding: .utf8) {
            for line in text.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: ":", maxSplits: 1).map { String($0) }
                if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "firewireguid",
                   let guid = parseGUID(parts[1]) {
                    return guid
                }
            }
        }
        return nil
    }

    // The hash covers the file with db_id, the 20 bytes at 0x32 and the hash field zeroed, so the
    // first two are restored afterwards.
    static func signHash58(_ data: inout Data, guid: Data) throws {
        guard data.count >= 0x6C, data.prefix(4) == Data("mhbd".utf8) else { throw SigningError.tooSmall }
        guard guid.count == 8 else { throw SigningError.badGUID }
        let start = data.startIndex
        func range(_ offset: Int, _ length: Int) -> Range<Int> { (start + offset)..<(start + offset + length) }
        let savedID = data.subdata(in: range(databaseIDOffset, 8))
        let savedUnknown = data.subdata(in: range(unknown32Offset, 20))
        data.replaceSubrange(range(databaseIDOffset, 8), with: Data(count: 8))
        data.replaceSubrange(range(unknown32Offset, 20), with: Data(count: 20))
        data.replaceSubrange(range(hash58Offset, 20), with: Data(count: 20))
        data.replaceSubrange(range(hashingSchemeOffset, 2), with: Data([1, 0]))
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: data, using: SymmetricKey(data: key(for: guid)))
        data.replaceSubrange(range(hash58Offset, 20), with: Data(mac))
        data.replaceSubrange(range(databaseIDOffset, 8), with: savedID)
        data.replaceSubrange(range(unknown32Offset, 20), with: savedUnknown)
    }

    // 64-byte HMAC key: SHA1(fixed || bytes looked up from the LCM of each GUID byte pair), zero padded.
    static func key(for guid: Data) -> Data {
        let g = [UInt8](guid)
        var y = [UInt8](repeating: 0, count: 16)
        for i in 0..<4 {
            let value = lcm(Int(g[i * 2]), Int(g[i * 2 + 1]))
            let high = Int((value >> 8) & 0xFF)
            let low = Int(value & 0xFF)
            y[i * 4] = sbox[high]
            y[i * 4 + 1] = inverseSbox[high]
            y[i * 4 + 2] = sbox[low]
            y[i * 4 + 3] = inverseSbox[low]
        }
        var key = Data(Insecure.SHA1.hash(data: Data(fixed + y)))
        key.append(Data(count: 64 - key.count))
        return key
    }

    private static func lcm(_ a: Int, _ b: Int) -> Int {
        if a == 0 || b == 0 { return 1 }
        var x = a, y = b
        while y != 0 { (x, y) = (y, x % y) }
        return a * b / x
    }

    private static let fixed: [UInt8] = [
        0x67, 0x23, 0xFE, 0x30, 0x45, 0x33, 0xF8, 0x90, 0x99,
        0x21, 0x07, 0xC1, 0xD0, 0x12, 0xB2, 0xA1, 0x07, 0x81,
    ]

    // The AES S-box and its inverse.
    private static let sbox: [UInt8] = [UInt8](hexBytes("637c777bf26b6fc53001672bfed7ab76ca82c97dfa5947f0add4a2af9ca472c0b7fd9326363ff7cc34a5e5f171d8311504c723c31896059a071280e2eb27b27509832c1a1b6e5aa0523bd6b329e32f8453d100ed20fcb15b6acbbe394a4c58cfd0efaafb434d338545f9027f503c9fa851a3408f929d38f5bcb6da2110fff3d2cd0c13ec5f974417c4a77e3d645d197360814fdc222a908846eeb814de5e0bdbe0323a0a4906245cc2d3ac629195e479e7c8376d8dd54ea96c56f4ea657aae08ba78252e1ca6b4c6e8dd741f4bbd8b8a703eb5664803f60e613557b986c11d9ee1f8981169d98e949b1e87e9ce5528df8ca1890dbfe6426841992d0fb054bb16", count: 256) ?? Data())
    private static let inverseSbox: [UInt8] = [UInt8](hexBytes("52096ad53036a538bf40a39e81f3d7fb7ce339829b2fff87348e4344c4dee9cb547b9432a6c2233dee4c950b42fac34e082ea16628d924b2765ba2496d8bd12572f8f66486689816d4a45ccc5d65b6926c704850fdedb9da5e154657a78d9d8490d8ab008cbcd30af7e45805b8b34506d02c1e8fca3f0f02c1afbd0301138a6b3a9111414f67dcea97f2cfcef0b4e67396ac7422e7ad3585e2f937e81c75df6e47f11a711d29c5896fb7620eaa18be1bfc563e4bc6d279209adbc0fe78cd5af41fdda8338807c731b11210592780ec5f60517fa919b54a0d2de57a9f93c99cefa0e03b4dae2af5b0c8ebbb3c83539961172b047eba77d626e169146355210c7d", count: 256) ?? Data())
}
