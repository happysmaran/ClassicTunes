import SwiftUI

enum iPodDesign {
    case thirdGen, clickWheel, mini
    case nanoSlim, nanoFat, nanoTall, nanoCurved
    case classic
    case shuffleStick, shuffleClip, shuffleBar
    case generic

    // Keyed by USB product ID
    init(usbProductID: Int) {
        switch usbProductID {
        case 0x1201: self = .thirdGen
        case 0x1203, 0x1204, 0x1209: self = .clickWheel
        case 0x1205: self = .mini
        case 0x120A, 0x1260: self = .nanoSlim
        case 0x1262: self = .nanoFat
        case 0x1263: self = .nanoCurved
        case 0x1265: self = .nanoTall
        case 0x1261: self = .classic
        case 0x1300: self = .shuffleStick
        case 0x1301: self = .shuffleClip
        case 0x1302: self = .shuffleBar
        default: self = .generic
        }
    }

    var assetName: String {
        switch self {
        case .thirdGen: return "iPodGlyphThirdGen"
        case .clickWheel, .generic: return "iPodGlyphClickWheel"
        case .mini: return "iPodGlyphMini"
        case .nanoSlim: return "iPodGlyphNanoSlim"
        case .nanoFat: return "iPodGlyphNanoFat"
        case .nanoTall: return "iPodGlyphNanoTall"
        case .nanoCurved: return "iPodGlyphNanoCurved"
        case .classic: return "iPodGlyphClassic"
        case .shuffleStick: return "iPodGlyphShuffleStick"
        case .shuffleClip: return "iPodGlyphShuffleClip"
        case .shuffleBar: return "iPodGlyphShuffleBar"
        }
    }
}

struct iPodGlyph: View {
    let design: iPodDesign

    var body: some View {
        Image(design.assetName)
            .resizable()
            .scaledToFit()
    }
}
