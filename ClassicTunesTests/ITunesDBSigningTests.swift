import Foundation
import Testing
@testable import ClassicTunes

struct ITunesDBSigningTests {
    // Expected hashes come from a reference HASH58 implementation over this synthetic database.
    private func sample() -> Data {
        var bytes = Data((0..<1024).map { UInt8(truncatingIfNeeded: $0 * 37 + 11) })
        bytes.replaceSubrange(0..<4, with: Data("mhbd".utf8))
        bytes.writeLE(UInt32(244), at: 4)
        bytes.writeLE(UInt32(1024), at: 8)
        return bytes
    }

    @Test(arguments: [
        ("0000000000000000", "925b8778aaba0f2eb81f40d4cf70ae74b654f5c8"),
        ("0011223344556677", "fdbe07ecd784c50ddcb126dd2d96cca9e1b34e94"),
        ("ffffffffffffffff", "87fa95ec1b8aba7bdd1c870ab41d11d297b4e048"),
    ])
    func matchesReferenceVectors(guid: String, expected: String) throws {
        var data = sample()
        let original = data
        try ITunesDBSigning.signHash58(&data, guid: try #require(ITunesDBSigning.parseGUID(guid)))
        let hash = data.subdata(in: 0x58..<0x6C).map { String(format: "%02x", $0) }.joined()
        #expect(hash == expected)
        #expect(data.subdata(in: 0x18..<0x20) == original.subdata(in: 0x18..<0x20))
        #expect(data.subdata(in: 0x32..<0x46) == original.subdata(in: 0x32..<0x46))
        #expect(data.readLE(UInt16.self, at: 0x30) == 1)
    }

    @Test func parsesGUIDForms() {
        #expect(ITunesDBSigning.parseGUID("0x0011223344556677")?.count == 8)
        #expect(ITunesDBSigning.parseGUID("0011") == nil)
    }
}
