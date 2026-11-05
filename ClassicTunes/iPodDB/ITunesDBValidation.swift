import Foundation

extension ITunesDBDocument {
    // Run on the bytes that are about to be written, after re-parsing them, so a bug in the
    // editing code is caught before the iPod's only database is replaced. A database that is
    // internally inconsistent is exactly the kind the firmware shows as empty.
    func validate() throws {
        guard let list = dataset(1), let master = masterPlaylist() else {
            throw ITunesDBError.malformed("track list or master playlist is missing")
        }
        let ids = list.children.compactMap { $0.header.readLE(UInt32.self, at: 0x10) }
        guard ids.count == list.children.count, Set(ids).count == ids.count else {
            throw ITunesDBError.malformed("track IDs are missing or duplicated")
        }
        let known = Set(ids)

        let masterItems = master.children.filter { $0.magic == "mhip" }
        guard masterItems.count == ids.count else {
            throw ITunesDBError.malformed("master playlist lists \(masterItems.count) tracks but the library has \(ids.count)")
        }
        // Dataset 3's master is the one newer firmware reads; it must list the same tracks in the
        // same order as dataset 2's.
        let order = masterItems.compactMap { $0.header.readLE(UInt32.self, at: 0x18) }
        for other in masterPlaylists() {
            let theirs = other.children.filter { $0.magic == "mhip" }.compactMap { $0.header.readLE(UInt32.self, at: 0x18) }
            guard theirs == order else {
                throw ITunesDBError.malformed("the two master playlists list different tracks")
            }
        }
        for datasetType: UInt32 in [2, 3] {
            for playlist in dataset(datasetType)?.children ?? [] where playlist.magic == "mhyp" {
                for item in playlist.children where item.magic == "mhip" {
                    guard let id = item.header.readLE(UInt32.self, at: 0x18), known.contains(id) else {
                        throw ITunesDBError.malformed("a playlist points at a track that is not in the library")
                    }
                }
            }
        }

        for index in indexMHODs() {
            let count = Int(index.body.readLE(UInt32.self, at: 4) ?? 0)
            guard count == masterItems.count, index.body.count == 48 + 4 * count else {
                throw ITunesDBError.malformed("a sorted index has \(count) entries for \(masterItems.count) tracks")
            }
            var seen = Set<UInt32>()
            for i in 0..<count {
                guard let position = index.body.readLE(UInt32.self, at: 48 + 4 * i), Int(position) < count, seen.insert(position).inserted else {
                    throw ITunesDBError.malformed("a sorted index is not a permutation of the tracks")
                }
            }
        }

        if let albums = dataset(4) {
            let albumIDs = Set(albums.children.compactMap { $0.header.readLE(UInt32.self, at: 0x10) })
            for track in list.children {
                let album = track.header.readLE(UInt32.self, at: 0x120) ?? 0
                guard albumIDs.contains(album) else {
                    throw ITunesDBError.malformed("a track references album record \(album), which does not exist")
                }
            }
        }
    }
}
