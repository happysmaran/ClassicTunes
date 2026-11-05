import Foundation

// How a sync treats tracks already on the iPod that the user did not ask for this time.
// Shuffles hold only what ClassicTunes put there, so they mirror the selection. iTunesDB iPods
// usually share their library with iTunes or Finder, so they only ever gain tracks.
enum SyncMode {
    case mirror
    case additive
}

// One track as it exists on the device, independent of which database format stores it.
struct DeviceEntry: Identifiable, Hashable {
    // Handle the owning library uses to find the record again (track ID or device path).
    let id: String
    // Device path with a leading slash, e.g. "/iPod_Control/Music/F03/ABCD.mp3".
    let path: String
    // nil when nothing on the device says which Mac track this is, so it can never be matched.
    let identity: String?
}

enum SyncIdentity {
    // Tracks are matched by metadata because the device renames every file, so Mac paths and
    // device paths can never be compared. Duration is rounded to seconds because different
    // readers disagree by a few milliseconds.
    static func make(title: String, artist: String, album: String, durationMS: UInt32) -> String {
        func norm(_ s: String) -> String {
            s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "\(norm(title))|\(norm(artist))|\(norm(album))|\(Int((Double(durationMS) / 1000).rounded()))"
    }
}

struct SyncPlan: Equatable {
    // Indices into the desired list that are not on the device yet.
    var addIndices: [Int] = []
    var remove: [DeviceEntry] = []
    var alreadyPresent = 0
}

// Pure so the add/remove decisions can be tested without a device.
enum SyncPlanner {
    static func plan(desired: [String], device: [DeviceEntry], mode: SyncMode) -> SyncPlan {
        var onDevice: [String: DeviceEntry] = [:]
        for entry in device {
            if let identity = entry.identity, onDevice[identity] == nil { onDevice[identity] = entry }
        }

        var plan = SyncPlan()
        var seen = Set<String>()
        var kept = Set<String>()
        for (index, identity) in desired.enumerated() {
            // The same song listed twice must not be copied twice.
            guard seen.insert(identity).inserted else { continue }
            if let entry = onDevice[identity] {
                plan.alreadyPresent += 1
                kept.insert(entry.id)
            } else {
                plan.addIndices.append(index)
            }
        }
        if mode == .mirror {
            // Also drops duplicates of a kept track and records nothing can be matched to.
            plan.remove = device.filter { !kept.contains($0.id) }
        }
        return plan
    }
}
