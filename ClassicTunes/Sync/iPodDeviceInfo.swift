import Foundation

// What an iPod says about itself in iPod_Control/Device/SysInfoExtended, shown on the device
// page the way iTunes shows model, software version and serial number. Every field is optional
// because Shuffles and blank devices often lack the file.
struct iPodDeviceInfo: Equatable {
    var productType: String?
    var modelNumber: String?
    var softwareVersion: String?
    var serialNumber: String?

    static func read(base: URL) -> iPodDeviceInfo {
        let url = base.appendingPathComponent("iPod_Control/Device/SysInfoExtended")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return iPodDeviceInfo()
        }
        func text(_ key: String) -> String? {
            guard let value = plist[key] as? String, !value.isEmpty else { return nil }
            return value
        }
        return iPodDeviceInfo(
            productType: text("ProductType"),
            modelNumber: text("ModelNumStr"),
            softwareVersion: text("VisibleBuildID"),
            serialNumber: text("SerialNumber")
        )
    }
}
