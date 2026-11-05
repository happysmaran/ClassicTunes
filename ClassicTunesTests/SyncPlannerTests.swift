import Foundation
import Testing
@testable import ClassicTunes

private func entry(_ id: String, _ identity: String?) -> DeviceEntry {
    DeviceEntry(id: id, path: "/iPod_Control/Music/F00/\(id).mp3", identity: identity)
}

struct SyncPlannerTests {
    @Test func addsOnlyMissingTracks() {
        let plan = SyncPlanner.plan(desired: ["a", "b", "c"], device: [entry("1", "a")], mode: .additive)
        #expect(plan.addIndices == [1, 2])
        #expect(plan.alreadyPresent == 1)
        #expect(plan.remove.isEmpty)
    }

    // An iPod shared with iTunes keeps tracks ClassicTunes did not put there.
    @Test func additiveModeNeverRemoves() {
        let plan = SyncPlanner.plan(desired: ["a"], device: [entry("1", "a"), entry("2", "other"), entry("3", nil)], mode: .additive)
        #expect(plan.remove.isEmpty)
    }

    @Test func mirrorRemovesUnselectedAndUnrecognizedTracks() {
        let plan = SyncPlanner.plan(desired: ["a"], device: [entry("1", "a"), entry("2", "other"), entry("3", nil)], mode: .mirror)
        #expect(plan.remove.map(\.id) == ["2", "3"])
        #expect(plan.addIndices.isEmpty)
    }

    @Test func mirrorDropsDuplicateCopiesOfAKeptTrack() {
        let plan = SyncPlanner.plan(desired: ["a"], device: [entry("1", "a"), entry("2", "a")], mode: .mirror)
        #expect(plan.remove.map(\.id) == ["2"])
    }

    @Test func aSongListedTwiceIsCopiedOnce() {
        let plan = SyncPlanner.plan(desired: ["a", "a"], device: [], mode: .additive)
        #expect(plan.addIndices == [0])
    }

    @Test func identityIgnoresCaseDiacriticsAndMillisecondNoise() {
        let a = SyncIdentity.make(title: "Café ", artist: "ARTIST", album: "Album", durationMS: 180_300)
        let b = SyncIdentity.make(title: "cafe", artist: "artist", album: "album", durationMS: 179_800)
        #expect(a == b)
    }
}
