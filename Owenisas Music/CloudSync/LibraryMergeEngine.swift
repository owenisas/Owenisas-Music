import Foundation

/// Library data as SwiftData holds it right now (songs + playlists with
/// ids, covers and user order). Same shape as a backup.
typealias LibrarySnapshot = LibraryBackup

/// Edits the app reported explicitly since the last capture. Likes and
/// resume positions only change through these, so a lost or rebuilt
/// SwiftData store can never broadcast "unlike everything".
struct LibraryLocalChanges: Equatable {
    struct Favorite: Equatable {
        var value: Bool
        var at: Date
    }

    struct Position: Equatable {
        var value: Double
        var at: Date
    }

    var favorites: [String: Favorite] = [:]
    var positions: [String: Position] = [:]
    /// After a backup restore or re-enabling sync: local likes/positions
    /// that differ from the last published state count as edits made now.
    var treatDiffsAsExplicit = false

    var isEmpty: Bool { favorites.isEmpty && positions.isEmpty && !treatDiffsAsExplicit }
}

/// Changes a merge wants made to the local SwiftData library.
struct LibraryApplyPlan: Equatable {
    struct SongChange: Equatable {
        var isFavorited: Bool?
        var playCount: Int?
        var lastPlayedDate: Date?
        var playbackPosition: Double?

        var isEmpty: Bool {
            isFavorited == nil && playCount == nil && lastPlayedDate == nil && playbackPosition == nil
        }
    }

    struct PlaylistUpsert: Equatable {
        var id: String
        var title: String
        var coverImagePath: String?
        var dateCreated: Date
        /// Members present on this device, in playlist order.
        var songIDs: [String]
        /// A local duplicate that takes this id in place (no delete + create,
        /// so a screen showing it keeps working).
        var adoptingLocalID: String?
    }

    var songChanges: [String: SongChange] = [:]
    var playlistUpserts: [PlaylistUpsert] = []
    var playlistDeletes: [String] = []
    var songDeletes: [String] = []

    var isEmpty: Bool {
        songChanges.isEmpty && playlistUpserts.isEmpty && playlistDeletes.isEmpty && songDeletes.isEmpty
    }
}

/// Pure capture/merge logic. No I/O, no SwiftData: everything is a value in,
/// value out, so it is unit-tested directly.
enum LibraryMergeEngine {

    // MARK: - Recording explicit deletions

    /// The user deleted songs here: tombstone them and queue the iCloud
    /// copies for removal. The device's own history stays in its record.
    static func recordSongDeletions(_ ids: [String], at date: Date, state: inout CloudSyncLocalState) {
        for rawID in ids {
            let id = CloudSyncFiles.folderKey(rawID)
            guard !id.isEmpty else { continue }
            state.own.deletedSongs[id] = max(state.own.deletedSongs[id] ?? date, date)
            state.own.songs[id]?.addedAt = nil
            state.pendingRemoteDeletes[id] = max(state.pendingRemoteDeletes[id] ?? date, date)
        }
    }

    /// The user deleted a playlist here (DataManager.deletePlaylist). A
    /// playlist that merely goes missing is never treated as deleted.
    static func recordPlaylistDeletion(id: String, title: String?, at date: Date, state: inout CloudSyncLocalState) {
        var record = state.own.playlists[id] ?? CloudPlaylistRecord(
            title: title ?? "",
            songOrder: [],
            coverImagePath: nil,
            dateCreated: date,
            modifiedAt: date
        )
        record.deleted = true
        record.mergedInto = nil
        record.modifiedAt = later(date, than: record.modifiedAt)
        state.own.playlists[id] = record
        state.playlistMarks[id] = nil
    }

    // MARK: - Capture (local edits → own records)

    static func capture(_ snapshot: LibrarySnapshot, changes: LibraryLocalChanges,
                        state: inout CloudSyncLocalState, now: Date) {
        let localSongIDs = Set(snapshot.songs.map(\.id))

        for song in snapshot.songs {
            let existing = state.own.songs[song.id]
            let localPosition = song.playbackPosition ?? 0
            var record = existing ?? CloudSongRecord(
                favorited: song.isFavorited,
                favoritedAt: CloudSyncConstants.unknownDate,
                playCount: 0,
                lastPlayed: nil,
                position: localPosition,
                positionAt: CloudSyncConstants.unknownDate,
                addedAt: song.dateAdded
            )

            if let favorite = changes.favorites[song.id] {
                record.favorited = favorite.value
                record.favoritedAt = later(favorite.at, than: record.favoritedAt)
            } else if changes.treatDiffsAsExplicit, existing != nil, song.isFavorited != record.favorited {
                record.favorited = song.isFavorited
                record.favoritedAt = later(now, than: record.favoritedAt)
            }
            // Otherwise a differing local like is drift (store rebuilt,
            // failed save): the merge puts the synced value back.

            // This device's share of plays only grows; a reset store can't
            // take plays away from the other devices' view.
            let othersApplied = state.appliedOthersPlayCount[song.id] ?? 0
            record.playCount = max(record.playCount, song.playCount - othersApplied)

            if let lastPlayed = song.lastPlayedDate {
                record.lastPlayed = max(record.lastPlayed ?? lastPlayed, lastPlayed)
            }

            if let position = changes.positions[song.id] {
                record.position = position.value
                record.positionAt = later(position.at, than: record.positionAt)
            } else if changes.treatDiffsAsExplicit, existing != nil, abs(localPosition - record.position) >= 1 {
                record.position = localPosition
                record.positionAt = later(now, than: record.positionAt)
            }

            if let added = song.dateAdded {
                record.addedAt = added
                // Re-added on this device after deleting it: the delete is over.
                if let deleted = state.own.deletedSongs[song.id], added > deleted {
                    state.own.deletedSongs[song.id] = nil
                }
            }
            state.own.songs[song.id] = record
        }

        for id in state.own.songs.keys where !localSongIDs.contains(id) {
            state.own.songs[id]?.addedAt = nil
        }

        for playlist in snapshot.playlists {
            guard let id = playlist.id else { continue }
            let current = CloudPlaylistLocalMark(
                title: playlist.title,
                coverImagePath: playlist.coverImagePath,
                songIDs: playlist.songIDs
            )
            guard var record = state.own.playlists[id] else {
                // First time sync sees this playlist.
                state.own.playlists[id] = CloudPlaylistRecord(
                    title: playlist.title,
                    songOrder: playlist.songIDs,
                    coverImagePath: playlist.coverImagePath,
                    dateCreated: playlist.dateCreated,
                    modifiedAt: playlist.dateCreated
                )
                state.playlistMarks[id] = current
                continue
            }
            guard let mark = state.playlistMarks[id] else {
                state.playlistMarks[id] = current
                continue
            }
            guard mark != current else { continue }

            var changed = false
            if current.title != mark.title {
                record.title = current.title
                changed = true
            }
            if current.coverImagePath != mark.coverImagePath {
                record.coverImagePath = current.coverImagePath
                changed = true
            }
            if current.songIDs != mark.songIDs {
                // A song that left the library without being deleted by the
                // user (folder removed in Files, store rebuilt) stays in the
                // playlist; only real removals and user deletes count.
                let vanished = Set(mark.songIDs.filter {
                    !localSongIDs.contains($0) && state.own.deletedSongs[$0] == nil
                })
                let effectivePrevious = mark.songIDs.filter { !vanished.contains($0) }
                if current.songIDs != effectivePrevious {
                    if record.deleted {
                        record.songOrder = current.songIDs
                    } else {
                        record.songOrder = replacingSlots(
                            in: record.songOrder,
                            slots: Set(effectivePrevious),
                            with: current.songIDs
                        )
                    }
                    changed = true
                }
            }
            if changed {
                if record.deleted {
                    // Edited here after another device deleted it: keep it.
                    record.deleted = false
                    record.mergedInto = nil
                    record.title = current.title
                    record.coverImagePath = current.coverImagePath
                }
                record.modifiedAt = later(now, than: record.modifiedAt)
                state.own.playlists[id] = record
            }
            state.playlistMarks[id] = current
        }
    }

    /// Replaces the members that were present here (`slots`) with the new
    /// local order, keeping members this device doesn't have yet anchored
    /// where they were.
    static func replacingSlots(in full: [String], slots: Set<String>, with replacement: [String]) -> [String] {
        let replacementSet = Set(replacement)
        var iterator = replacement.makeIterator()
        var result: [String] = []
        for id in full {
            if slots.contains(id) {
                if let next = iterator.next() { result.append(next) }
            } else if !replacementSet.contains(id) {
                result.append(id)
            }
        }
        while let next = iterator.next() { result.append(next) }
        var seen = Set<String>()
        return result.filter { seen.insert($0).inserted }
    }

    // MARK: - Merge (all devices → plan for this device)

    static func merge(_ snapshot: LibrarySnapshot, others allOthers: [CloudLibraryFile],
                      state: inout CloudSyncLocalState, now: Date,
                      allowDestructive: Bool, protectedSongIDs: Set<String> = []) -> LibraryApplyPlan {
        let others = allOthers
            .filter { $0.deviceID != state.own.deviceID }
            .sorted { $0.deviceID < $1.deviceID }
        var plan = LibraryApplyPlan()
        mergeSongs(snapshot, others: others, state: &state, plan: &plan)

        if allowDestructive {
            let tombstones = effectiveSongTombstones(own: state.own, others: others)
            for song in snapshot.songs {
                guard let deletedAt = tombstones[song.id],
                      let added = song.dateAdded, deletedAt > added,
                      !protectedSongIDs.contains(song.id) else { continue }
                plan.songDeletes.append(song.id)
            }
            plan.songDeletes.sort()
        }

        mergePlaylists(snapshot, others: others, state: &state, now: now,
                       allowDestructive: allowDestructive, plan: &plan)
        return plan
    }

    private static func mergeSongs(_ snapshot: LibrarySnapshot, others: [CloudLibraryFile],
                                   state: inout CloudSyncLocalState, plan: inout LibraryApplyPlan) {
        for song in snapshot.songs {
            guard var own = state.own.songs[song.id] else { continue }
            let remote = others.compactMap { $0.songs[song.id] }
            var change = LibraryApplyPlan.SongChange()

            // Like: latest edit wins; on a tie a like beats no like.
            var favorite = (value: own.favorited, at: own.favoritedAt)
            for record in remote where record.favoritedAt > favorite.at
                || (record.favoritedAt == favorite.at && record.favorited && !favorite.value) {
                favorite = (record.favorited, record.favoritedAt)
            }
            own.favorited = favorite.value
            own.favoritedAt = favorite.at
            if song.isFavorited != favorite.value { change.isFavorited = favorite.value }

            // Plays: each device counts its own; the library shows the sum.
            let otherPlays = remote.reduce(0) { $0 + max(0, $1.playCount) }
            if otherPlays > 0 {
                state.appliedOthersPlayCount[song.id] = otherPlays
            } else {
                state.appliedOthersPlayCount[song.id] = nil
            }
            let total = own.playCount + otherPlays
            if total != song.playCount { change.playCount = total }

            let latest = ([song.lastPlayedDate, own.lastPlayed] + remote.map(\.lastPlayed)).compactMap { $0 }.max()
            if let latest, latest > (song.lastPlayedDate ?? .distantPast) {
                change.lastPlayedDate = latest
            }

            // Resume position: latest save wins; on a tie the further one.
            var position = (value: own.position, at: own.positionAt)
            for record in remote where record.positionAt > position.at
                || (record.positionAt == position.at && record.position > position.value) {
                position = (record.position, record.positionAt)
            }
            own.position = position.value
            own.positionAt = position.at
            if abs(position.value - (song.playbackPosition ?? 0)) >= 1 {
                change.playbackPosition = position.value
            }

            state.own.songs[song.id] = own
            if !change.isEmpty { plan.songChanges[song.id] = change }
        }
    }

    /// Latest deletion per song, dropped when any device (re-)added the
    /// song after it — a later add always wins over an older delete.
    static func effectiveSongTombstones(own: CloudLibraryFile, others: [CloudLibraryFile]) -> [String: Date] {
        let files = [own] + others
        var latest: [String: Date] = [:]
        for file in files {
            for (id, date) in file.deletedSongs {
                latest[id] = max(latest[id] ?? date, date)
            }
        }
        for file in files {
            for (id, record) in file.songs {
                if let added = record.addedAt, let deleted = latest[id], added > deleted {
                    latest[id] = nil
                }
            }
        }
        return latest
    }

    // MARK: Playlists

    static func titleKey(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    private static func mergePlaylists(_ snapshot: LibrarySnapshot, others: [CloudLibraryFile],
                                       state: inout CloudSyncLocalState, now: Date,
                                       allowDestructive: Bool, plan: inout LibraryApplyPlan) {
        let presentSongs = Set(snapshot.songs.map(\.id))
        var local: [String: LibrarySnapshot.PlaylistBackup] = [:]
        for playlist in snapshot.playlists {
            if let id = playlist.id { local[id] = playlist }
        }
        let ownDevice = state.own.deviceID

        func winner(_ id: String) -> CloudPlaylistRecord? {
            var best: (record: CloudPlaylistRecord, device: String)?
            var candidates: [(CloudPlaylistRecord, String)] = []
            if let record = state.own.playlists[id] { candidates.append((record, ownDevice)) }
            for file in others {
                if let record = file.playlists[id] { candidates.append((record, file.deviceID)) }
            }
            for (record, device) in candidates {
                guard let current = best else {
                    best = (record, device)
                    continue
                }
                if record.modifiedAt != current.record.modifiedAt {
                    if record.modifiedAt > current.record.modifiedAt { best = (record, device) }
                } else if record.deleted != current.record.deleted {
                    if !record.deleted { best = (record, device) } // tie: keeping beats deleting
                } else if device > current.device {
                    best = (record, device)
                }
            }
            return best?.record
        }

        var allIDs = Set(state.own.playlists.keys)
        for file in others { allIDs.formUnion(file.playlists.keys) }

        // 1. Learn folds other devices published.
        for id in allIDs.sorted() {
            if let record = winner(id), record.deleted, let target = record.mergedInto, target != id {
                state.playlistAliases[id] = target
            }
        }

        // 2. Same title created independently on two devices before they
        //    knew about each other → one playlist, not two.
        let remoteKnown = Set(others.flatMap { $0.playlists.keys })
        for id in allIDs.sorted() where local[id] == nil && state.own.playlists[id] == nil
            && state.playlistAliases[id] == nil {
            guard let remote = winner(id), !remote.deleted else { continue }
            let key = titleKey(remote.title)
            let match = local.values
                .filter { candidate in
                    guard let candidateID = candidate.id else { return false }
                    return candidateID != id
                        && !remoteKnown.contains(candidateID)
                        && state.playlistAliases[candidateID] == nil
                        && titleKey(candidate.title) == key
                }
                .min { ($0.dateCreated, $0.id ?? "") < ($1.dateCreated, $1.id ?? "") }
            guard let match, let localID = match.id else { continue }
            let remoteIsOlder = (remote.dateCreated, id) < (match.dateCreated, localID)
            let canonical = remoteIsOlder ? id : localID
            let alias = remoteIsOlder ? localID : id
            state.playlistAliases[alias] = canonical
        }

        func resolve(_ id: String) -> String {
            var current = id
            var seen: Set<String> = [id]
            while let next = state.playlistAliases[current], next != current, seen.insert(next).inserted {
                current = next
            }
            return current
        }

        // 3. Fold live duplicates into their canonical playlist (union, the
        //    canonical order first) and tombstone the duplicate.
        for alias in state.playlistAliases.keys.sorted() {
            let canonical = resolve(alias)
            guard canonical != alias, let aliasRecord = winner(alias), !aliasRecord.deleted else { continue }
            var target = winner(canonical) ?? CloudPlaylistRecord(
                title: aliasRecord.title,
                songOrder: [],
                coverImagePath: aliasRecord.coverImagePath,
                dateCreated: aliasRecord.dateCreated,
                modifiedAt: CloudSyncConstants.unknownDate
            )
            var changed = false
            if target.deleted {
                if aliasRecord.modifiedAt > target.modifiedAt {
                    target.deleted = false
                    target.mergedInto = nil
                    target.songOrder = aliasRecord.songOrder
                    changed = true
                }
            } else {
                let existing = Set(target.songOrder)
                let extra = aliasRecord.songOrder.filter { !existing.contains($0) }
                if !extra.isEmpty {
                    target.songOrder += extra
                    changed = true
                }
                if target.coverImagePath == nil, aliasRecord.coverImagePath != nil {
                    target.coverImagePath = aliasRecord.coverImagePath
                    changed = true
                }
            }
            if changed || state.own.playlists[canonical] == nil {
                if changed { target.modifiedAt = later(now, than: target.modifiedAt) }
                state.own.playlists[canonical] = target
            }
            var tombstone = aliasRecord
            tombstone.deleted = true
            tombstone.mergedInto = canonical
            tombstone.modifiedAt = later(now, than: aliasRecord.modifiedAt)
            state.own.playlists[alias] = tombstone
        }

        // 4. Make the local library match the winners.
        var adoptedLocal = Set<String>()
        var ids = allIDs
        ids.formUnion(local.keys)
        ids.formUnion(state.own.playlists.keys)
        for id in ids.sorted() {
            if resolve(id) != id {
                // Duplicates are handled via their canonical id; publish the
                // fold tombstone instead of a stale live record.
                if let record = winner(id), record.deleted, state.own.playlists[id] != record {
                    state.own.playlists[id] = record
                }
                continue
            }
            guard let record = winner(id) else { continue }
            if state.own.playlists[id] != record { state.own.playlists[id] = record }

            if record.deleted {
                if local[id] != nil, allowDestructive { plan.playlistDeletes.append(id) }
                continue
            }

            var seen = Set<String>()
            let present = record.songOrder.filter { presentSongs.contains($0) && seen.insert($0).inserted }
            if let existing = local[id] {
                if existing.title != record.title || existing.coverImagePath != record.coverImagePath
                    || existing.songIDs != present {
                    plan.playlistUpserts.append(.init(
                        id: id, title: record.title, coverImagePath: record.coverImagePath,
                        dateCreated: record.dateCreated, songIDs: present, adoptingLocalID: nil
                    ))
                }
            } else {
                let adopt = state.playlistAliases.keys.sorted().first {
                    local[$0] != nil && resolve($0) == id && !adoptedLocal.contains($0)
                }
                if let adopt { adoptedLocal.insert(adopt) }
                plan.playlistUpserts.append(.init(
                    id: id, title: record.title, coverImagePath: record.coverImagePath,
                    dateCreated: record.dateCreated, songIDs: present, adoptingLocalID: adopt
                ))
            }
        }

        // 5. A duplicate still here whose canonical playlist also exists
        //    here: its songs are already folded in, so it goes.
        if allowDestructive {
            for id in local.keys.sorted() where resolve(id) != id && !adoptedLocal.contains(id) {
                plan.playlistDeletes.append(id)
            }
        }
    }

    // MARK: - After apply

    /// Remember what each playlist looks like now that the plan is applied,
    /// so the next capture only sees real user edits.
    static func refreshMarks(from snapshot: LibrarySnapshot, state: inout CloudSyncLocalState) {
        var marks: [String: CloudPlaylistLocalMark] = [:]
        for playlist in snapshot.playlists {
            guard let id = playlist.id else { continue }
            marks[id] = CloudPlaylistLocalMark(
                title: playlist.title,
                coverImagePath: playlist.coverImagePath,
                songIDs: playlist.songIDs
            )
        }
        state.playlistMarks = marks
    }

    // MARK: - Helpers

    /// `date`, nudged past `other` so a local edit always beats the value
    /// it replaced even when clocks disagree slightly.
    static func later(_ date: Date, than other: Date) -> Date {
        date > other ? date : other.addingTimeInterval(0.001)
    }
}
