import Foundation
import IOKit

// Identifies an iPod by what its USB connection reports
enum iPodUSBIdentity {
    private static let appleVendorID = 0x05AC

    // Product IDs by family. Note, Shuffles must be told apart because their database format
    // are incompatible; every other model here stores an iTunesDB. Models missing from the table
    // are identified from their files instead. In practice, that is also unreliable.
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

    // Cover formats for models whose artwork layout is fixed, used when the iPod has no
    // SysInfoExtended to declare them (a Finder restore does not write it).
    static func artworkFormats(bsdName: String) -> [ArtworkFormat] {
        guard let ids = usbIDs(bsdName: bsdName), ids.vendor == appleVendorID else { return [] }
        switch ids.product {
        case 0x120A, 0x1260:   // Nano 1st and 2nd generation
            return [
                ArtworkFormat(id: 1031, width: 42, height: 42, rowBytes: 84),
                ArtworkFormat(id: 1027, width: 100, height: 100, rowBytes: 200),
            ]
        case 0x1204:   // Photo / 4th generation (colour display)
            return [
                ArtworkFormat(id: 1017, width: 56, height: 56, rowBytes: 112),
                ArtworkFormat(id: 1016, width: 140, height: 140, rowBytes: 280),
            ]
        case 0x1209:   // Video (5th and 5.5th generation)
            return [
                ArtworkFormat(id: 1028, width: 100, height: 100, rowBytes: 200),
                ArtworkFormat(id: 1029, width: 200, height: 200, rowBytes: 400),
            ]
        case 0x1261, 0x1262:   // Classic and Nano 3rd generation
            return [
                ArtworkFormat(id: 1061, width: 56, height: 56, rowBytes: 112),
                ArtworkFormat(id: 1055, width: 128, height: 128, rowBytes: 256),
                ArtworkFormat(id: 1068, width: 128, height: 128, rowBytes: 256),
                ArtworkFormat(id: 1060, width: 320, height: 320, rowBytes: 640),
            ]
        case 0x1263:   // Nano 4th generation
            return [
                ArtworkFormat(id: 1055, width: 128, height: 128, rowBytes: 256),
                ArtworkFormat(id: 1068, width: 128, height: 128, rowBytes: 256),
                ArtworkFormat(id: 1071, width: 240, height: 240, rowBytes: 480),
                ArtworkFormat(id: 1074, width: 50, height: 50, rowBytes: 100),
                ArtworkFormat(id: 1078, width: 80, height: 80, rowBytes: 160),
                ArtworkFormat(id: 1084, width: 240, height: 240, rowBytes: 480),
            ]
        default:
            return []
        }
    }

    // nil when the volume is not on a USB Apple device or the model is not in the table, in
    // which case the caller falls back to inspecting files.
    static func generation(bsdName: String) -> iPodGeneration? {
        guard let ids = usbIDs(bsdName: bsdName), ids.vendor == appleVendorID else { return nil }
        return generations[ids.product]
    }

    private static let modelNames: [Int: String] = [
        0x1201: "iPod (3rd generation)",
        0x1203: "iPod (4th generation)",
        0x1204: "iPod Photo",
        0x1205: "iPod mini",
        0x1209: "iPod Video (5th/5.5th generation)",
        0x120A: "iPod nano (1st generation)",
        0x1260: "iPod nano (2nd generation)",
        0x1261: "iPod Classic",
        0x1262: "iPod nano (3rd generation)",
        0x1263: "iPod nano (4th generation)",
        0x1265: "iPod nano (5th generation)",
        0x1300: "iPod shuffle (1st generation)",
        0x1301: "iPod shuffle (2nd generation)",
        0x1302: "iPod shuffle (3rd generation)",
    ]

    static func design(bsdName: String) -> iPodDesign {
        guard let ids = usbIDs(bsdName: bsdName), ids.vendor == appleVendorID else { return .generic }
        return iPodDesign(usbProductID: ids.product)
    }

    static func modelName(bsdName: String) -> String? {
        guard let ids = usbIDs(bsdName: bsdName), ids.vendor == appleVendorID else { return nil }
        return modelNames[ids.product]
    }

    // The USB serial of an iPod is its FireWire GUID, the fallback when no SysInfo file states it.
    static func serialNumber(bsdName: String) -> String? {
        guard !bsdName.isEmpty,
              let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else { return nil }
        let media = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard media != 0 else { return nil }
        defer { IOObjectRelease(media) }
        return IORegistryEntrySearchCFProperty(
            media, kIOServicePlane, "USB Serial Number" as CFString, kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        ) as? String
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
