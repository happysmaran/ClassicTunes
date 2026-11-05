import Foundation
import IOKit

// Identifies an iPod by what its USB connection reports, the way iTunes does, because the files
// on a blank or freshly restored Shuffle say nothing about which generation it is and a database
// in the wrong layout is unreadable to it.
enum iPodUSBIdentity {
    private static let appleVendorID = 0x05AC

    // Product IDs by family. Shuffles must be told apart because their database formats are
    // incompatible; every other model here stores an iTunesDB. Models missing from the table
    // are identified from their files instead.
    private static let generations: [Int: iPodGeneration] = [
        0x1300: .shuffle1,
        0x1301: .shuffle2,
        0x1302: .shuffle3,
        0x1303: .shuffle3,
        0x1201: .classic,   // 3rd generation
        0x1203: .classic,   // 4th generation
        0x1204: .classic,   // Photo
        0x1205: .classic,   // Mini
        0x1209: .classic,   // Video
        0x120A: .classic,   // Nano 1st generation
        0x1260: .classic,   // Nano 2nd generation
        0x1261: .classic,   // Classic
        0x1262: .classic,   // Nano 3rd generation
        0x1263: .classic,   // Nano 4th generation
        0x1265: .classic,   // Nano 5th generation
    ]

    // nil when the volume is not on a USB Apple device or the model is not in the table, in
    // which case the caller falls back to inspecting files.
    static func generation(bsdName: String) -> iPodGeneration? {
        guard let ids = usbIDs(bsdName: bsdName), ids.vendor == appleVendorID else { return nil }
        return generations[ids.product]
    }

    // Walks up from the volume's IOMedia node to the USB device that owns it; the vendor and
    // product IDs live on that ancestor, not on the disk itself.
    private static func usbIDs(bsdName: String) -> (vendor: Int, product: Int)? {
        guard !bsdName.isEmpty,
              let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else { return nil }
        // IOServiceGetMatchingService consumes the matching dictionary.
        let media = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard media != 0 else { return nil }
        defer { IOObjectRelease(media) }

        func number(_ key: String) -> Int? {
            IORegistryEntrySearchCFProperty(
                media, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
            ) as? Int
        }
        guard let vendor = number("idVendor"), let product = number("idProduct") else { return nil }
        return (vendor, product)
    }
}
