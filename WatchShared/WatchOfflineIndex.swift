import Foundation

/// An audio file stored on the watch.
struct WatchOfflineTrack: Codable, Equatable, Identifiable, Hashable {
    var id: String
    var title: String
    var artist: String
    var duration: Double
    var bytes: Int64
    var fileName: String
    var addedAt: Date
}

/// A list the user downloaded to the watch (Liked Songs or a playlist).
struct WatchOfflineCollection: Codable, Equatable, Identifiable {
    var list: WatchListRef
    var title: String
    /// Song ids in list order, including ones still on their way.
    var songIDs: [String]
    /// Expected size per song id (from the manifest), for progress.
    var expectedBytes: [String: Int64]
    /// Songs the phone couldn't send.
    var failedIDs: [String]
    var requestedAt: Date

    var id: String { list.rawValue }
}

struct WatchOfflineProgress: Equatable {
    var received: Int
    var total: Int
    var failed: Int
    var receivedBytes: Int64
    var totalBytes: Int64

    var pending: Int { max(0, total - received - failed) }

    var fraction: Double {
        if totalBytes > 0 { return min(1, Double(receivedBytes) / Double(totalBytes)) }
        return total > 0 ? Double(received) / Double(total) : 0
    }
}

enum WatchOfflineState: Equatable {
    case notDownloaded
    case downloading(WatchOfflineProgress)
    case downloaded(WatchOfflineProgress)
    /// Nothing pending, but some songs failed to transfer.
    case incomplete(WatchOfflineProgress)
}

/// Everything the watch knows about downloaded music. Pure value type so the
/// bookkeeping is testable on the phone; the watch persists it as JSON.
struct WatchOfflineIndex: Codable, Equatable {
    var schema = 1
    var tracks: [String: WatchOfflineTrack] = [:]
    var collections: [WatchOfflineCollection] = []

    func collection(_ list: WatchListRef) -> WatchOfflineCollection? {
        collections.first { $0.list == list }
    }

    func isReferenced(_ songID: String) -> Bool {
        collections.contains { $0.songIDs.contains(songID) }
    }

    /// Stored on the watch.
    var usedBytes: Int64 { tracks.values.reduce(0) { $0 + $1.bytes } }

    /// Songs some collection still waits for (not stored, not failed).
    var pendingIDs: Set<String> {
        var ids = Set<String>()
        for c in collections {
            let failed = Set(c.failedIDs)
            for id in c.songIDs where tracks[id] == nil && !failed.contains(id) {
                ids.insert(id)
            }
        }
        return ids
    }

    /// Expected size of pending songs (each counted once).
    var pendingBytes: Int64 {
        pendingIDs.reduce(0) { total, id in
            total + (collections.lazy.compactMap { $0.expectedBytes[id] }.first ?? 0)
        }
    }

    /// Stored plus on the way: what the storage limit is measured against.
    var committedBytes: Int64 { usedBytes + pendingBytes }

    /// Start or extend a download. `requested` are the planned songs,
    /// `present` the manifest songs already on the watch; both keep list order.
    mutating func upsertCollection(
        list: WatchListRef,
        title: String,
        manifestOrder: [String],
        requested: [WatchSongItem],
        present: [String],
        now: Date = Date()
    ) {
        let include = Set(requested.map(\.id)).union(present)
        let existing = collection(list)
        var ids = existing?.songIDs ?? []
        var known = Set(ids)
        for id in manifestOrder where include.contains(id) && known.insert(id).inserted {
            ids.append(id)
        }
        // Follow the phone's current order for everything the collection holds.
        let rank = Dictionary(manifestOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        ids = ids.enumerated().sorted { a, b in
            let ra = rank[a.element] ?? Int.max, rb = rank[b.element] ?? Int.max
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)

        var expected = existing?.expectedBytes ?? [:]
        for song in requested { expected[song.id] = song.bytes ?? 0 }
        for id in present where expected[id] == nil { expected[id] = tracks[id]?.bytes ?? 0 }
        let retried = Set(requested.map(\.id))
        let failed = (existing?.failedIDs ?? []).filter { !retried.contains($0) }

        let updated = WatchOfflineCollection(
            list: list, title: title, songIDs: ids, expectedBytes: expected,
            failedIDs: failed, requestedAt: now
        )
        if let i = collections.firstIndex(where: { $0.list == list }) {
            collections[i] = updated
        } else {
            collections.append(updated)
        }
    }

    /// A file arrived. Returns false when no collection wants it any more
    /// (removed while in flight) — the caller deletes the file.
    @discardableResult
    mutating func recordArrival(_ track: WatchOfflineTrack) -> Bool {
        guard isReferenced(track.id) else { return false }
        tracks[track.id] = track
        for i in collections.indices {
            collections[i].failedIDs.removeAll { $0 == track.id }
        }
        return true
    }

    mutating func markFailed(_ songID: String) {
        guard tracks[songID] == nil else { return }
        for i in collections.indices where collections[i].songIDs.contains(songID) {
            if !collections[i].failedIDs.contains(songID) {
                collections[i].failedIDs.append(songID)
            }
        }
    }

    /// Remove a download. Returns the tracks no other collection uses (their
    /// files should be deleted) and pending ids nobody waits for any more
    /// (their transfers should be cancelled on the phone).
    @discardableResult
    mutating func removeCollection(_ list: WatchListRef) -> (orphans: [WatchOfflineTrack], cancelled: [String]) {
        guard let removed = collection(list) else { return ([], []) }
        let pendingBefore = pendingIDs
        collections.removeAll { $0.list == list }
        var orphans: [WatchOfflineTrack] = []
        var cancelled: [String] = []
        for id in removed.songIDs where !isReferenced(id) {
            if let track = tracks.removeValue(forKey: id) {
                orphans.append(track)
            } else if pendingBefore.contains(id) {
                cancelled.append(id)
            }
        }
        return (orphans, cancelled)
    }

    /// Stored tracks of a collection, in list order.
    func tracks(in list: WatchListRef) -> [WatchOfflineTrack] {
        collection(list)?.songIDs.compactMap { tracks[$0] } ?? []
    }

    func progress(for list: WatchListRef) -> WatchOfflineProgress? {
        guard let c = collection(list) else { return nil }
        let failed = Set(c.failedIDs)
        var progress = WatchOfflineProgress(received: 0, total: c.songIDs.count, failed: 0, receivedBytes: 0, totalBytes: 0)
        for id in c.songIDs {
            if let track = tracks[id] {
                progress.received += 1
                progress.receivedBytes += track.bytes
                progress.totalBytes += track.bytes
            } else if failed.contains(id) {
                progress.failed += 1
            } else {
                progress.totalBytes += c.expectedBytes[id] ?? 0
            }
        }
        return progress
    }

    func state(for list: WatchListRef) -> WatchOfflineState {
        guard let p = progress(for: list) else { return .notDownloaded }
        if p.pending > 0 { return .downloading(p) }
        return p.failed > 0 ? .incomplete(p) : .downloaded(p)
    }
}
