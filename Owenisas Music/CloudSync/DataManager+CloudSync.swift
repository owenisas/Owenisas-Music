import Foundation
import SwiftData

/// SwiftData side of iCloud sync. Reads a snapshot of library data and
/// applies merged values; files are handled by `CloudFileMirror`.
extension DataManager: CloudLibraryStore {

    func cloudSnapshot() -> LibrarySnapshot? {
        guard let ctx = modelContext,
              let songs = try? ctx.fetch(FetchDescriptor<SongData>()),
              let playlists = try? ctx.fetch(FetchDescriptor<PlaylistData>()) else { return nil }
        return LibrarySnapshot(
            exportDate: .now,
            songs: songs.map {
                LibraryBackup.SongBackup(
                    id: $0.id,
                    playCount: $0.playCount,
                    isFavorited: $0.isFavorited,
                    lastPlayedDate: $0.lastPlayedDate,
                    dateAdded: $0.dateAdded,
                    playbackPosition: $0.playbackPosition
                )
            },
            playlists: playlists.map {
                LibraryBackup.PlaylistBackup(
                    title: $0.title,
                    dateCreated: $0.dateCreated,
                    songIDs: $0.orderedSongs.map(\.id),
                    id: $0.id,
                    coverImagePath: $0.coverImagePath
                )
            }
        )
    }

    @discardableResult
    func applyCloudPlan(_ plan: LibraryApplyPlan, removeSongFolder: (String) -> Bool) -> Bool {
        guard let ctx = modelContext else { return false }
        guard !plan.isEmpty else { return true }

        let songs = (try? ctx.fetch(FetchDescriptor<SongData>())) ?? []
        let songsByID = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for (id, change) in plan.songChanges {
            guard let song = songsByID[id] else { continue }
            if let value = change.isFavorited, song.isFavorited != value { song.isFavorited = value }
            if let value = change.playCount, song.playCount != value { song.playCount = max(0, value) }
            if let value = change.lastPlayedDate, song.lastPlayedDate != value { song.lastPlayedDate = value }
            if let value = change.playbackPosition, abs(song.playbackPosition - value) >= 0.5 { song.playbackPosition = value }
        }

        var playlistsChanged = false
        var playlistsByID: [String: PlaylistData] = [:]
        for playlist in (try? ctx.fetch(FetchDescriptor<PlaylistData>())) ?? [] where playlistsByID[playlist.id] == nil {
            playlistsByID[playlist.id] = playlist
        }

        for upsert in plan.playlistUpserts {
            let target: PlaylistData
            if let existing = playlistsByID[upsert.id] {
                target = existing
            } else if let adoptID = upsert.adoptingLocalID, let duplicate = playlistsByID[adoptID] {
                // Same playlist created on two devices: this copy takes the
                // shared id in place.
                duplicate.id = upsert.id
                playlistsByID[adoptID] = nil
                playlistsByID[upsert.id] = duplicate
                target = duplicate
            } else {
                let created = PlaylistData(
                    id: upsert.id,
                    title: upsert.title,
                    coverImagePath: upsert.coverImagePath,
                    dateCreated: upsert.dateCreated
                )
                ctx.insert(created)
                playlistsByID[upsert.id] = created
                target = created
            }
            if target.title != upsert.title { target.title = upsert.title }
            if target.coverImagePath != upsert.coverImagePath { target.coverImagePath = upsert.coverImagePath }

            let members = upsert.songIDs.compactMap { songsByID[$0] }
            let memberIDs = members.map(\.id)
            if Set(target.songs.map(\.id)) != Set(memberIDs) {
                target.songs = members
            }
            if target.songOrder != memberIDs {
                target.songOrder = memberIDs
            }
            playlistsChanged = true
        }

        for id in plan.playlistDeletes {
            guard let playlist = playlistsByID[id] else { continue }
            ctx.delete(playlist)
            playlistsByID[id] = nil
            playlistsChanged = true
        }

        var removedSongs = false
        let protected = cloudProtectedSongIDs
        for id in plan.songDeletes {
            guard let song = songsByID[id], !protected.contains(id) else { continue }
            // Folder first: if it can't be set aside, the song stays.
            guard removeSongFolder(song.id) else { continue }
            MusicPlayerManager.shared.stopAndRemoveFromQueue(songId: song.id)
            ctx.delete(song)
            removedSongs = true
        }

        do {
            try ctx.save()
        } catch {
            print("[DEBUG] DataManager: iCloud merge save failed: \(error.localizedDescription)")
            return false
        }
        if playlistsChanged {
            NotificationCenter.default.post(name: .init("PlaylistsChanged"), object: nil)
        }
        if removedSongs {
            NotificationCenter.default.post(name: .init("SongsFolderChanged"), object: nil)
        }
        return true
    }

    func indexCloudFolder(_ folderName: String) {
        syncSingleSong(folderName: folderName)
    }

    var cloudProtectedSongIDs: Set<String> {
        guard let current = MusicPlayerManager.shared.currentSong?.id else { return [] }
        return [current]
    }
}
