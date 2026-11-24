import Foundation

// Finds copies of the same recording in the library.
nonisolated enum DuplicateFinder {
    // The same recording could report slightly different lengths across files
    // (encoder padding, tags).
    static let durationTolerance: TimeInterval = 2

    static func groups(in songs: [Song]) -> [[Song]] {
        var buckets: [String: [Song]] = [:]
        for song in songs {
            guard song.duration != nil else { continue }
            let title = normalize(song.title)
            guard !title.isEmpty else { continue }
            let key = [title, normalize(song.artist), normalize(song.album), year(song.year)].joined(separator: "|")
            buckets[key, default: []].append(song)
        }

        var result: [[Song]] = []
        for bucket in buckets.values where bucket.count > 1 {
            // A song joins a cluster only if it matches every member, so chains of near-matches
            // can't pull in a song that differs from the first one.
            var clusters: [[Song]] = []
            for song in bucket.sorted(by: { ($0.duration ?? 0) < ($1.duration ?? 0) }) {
                if let index = clusters.firstIndex(where: { cluster in cluster.allSatisfy { areCopies($0, song) } }) {
                    clusters[index].append(song)
                } else {
                    clusters.append([song])
                }
            }
            result.append(contentsOf: clusters.filter { $0.count > 1 })
        }
        return result
            .map { $0.sorted { $0.url.path < $1.url.path } }
            .sorted { ($0[0].title, $0[0].artist) < ($1[0].title, $1[0].artist) }
    }

    // Case, accents, spacing and punctuation differ between taggers without meaning a different song.
    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }

    // Tags hold "2009" or a full date depending on the tool; only the year is compared.
    private static func year(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let digits = trimmed.prefix(4)
        return digits.count == 4 && digits.allSatisfy(\.isNumber) ? String(digits) : trimmed.lowercased()
    }

    private static func areCopies(_ a: Song, _ b: Song) -> Bool {
        guard let first = a.duration, let second = b.duration, abs(first - second) <= durationTolerance else { return false }
        if let x = a.trackNumber, let y = b.trackNumber, x != y { return false }
        if let x = a.discNumber, let y = b.discNumber, x != y { return false }
        return true
    }
}
