import Foundation
import Testing
import SwiftData
@testable import Owenisas_Music

// MARK: - Library Backup Tests
// Verifies the local-first backup: export captures likes/play history and
// playlists, and import merges them back without destroying newer data.

@MainActor
struct LibraryBackupTests {

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(
            for: SongData.self, AlbumData.self, PlaylistData.self,
            configurations: config
        )
        return ModelContext(container)
    }

    private func makeSongData(id: String, playCount: Int = 0, favorited: Bool = false) -> SongData {
        SongData(
            id: id,
            title: "Song \(id)",
            audioFilePath: "Songs/\(id)/\(id).mp3",
            playCount: playCount,
            isFavorited: favorited
        )
    }

    @Test("Export → wipe stats → import restores likes, counts, and playlists")
    func backupRoundTrip() throws {
        let dm = DataManager()
        let ctx = try makeContext()
        dm.configure(with: ctx)

        let s1 = makeSongData(id: "b1", playCount: 7, favorited: true)
        let s2 = makeSongData(id: "b2", playCount: 3)
        s1.lastPlayedDate = Date(timeIntervalSince1970: 1_700_000_000)
        ctx.insert(s1)
        ctx.insert(s2)

        let playlist = PlaylistData(title: "Road Trip")
        ctx.insert(playlist)
        playlist.songs.append(s1)
        playlist.songs.append(s2)
        try ctx.save()

        let data = try #require(dm.exportBackupData())

        // Simulate a fresh install that re-downloaded the same songs
        // (stats gone, playlist gone).
        s1.playCount = 0
        s1.isFavorited = false
        s1.lastPlayedDate = nil
        s2.playCount = 0
        ctx.delete(playlist)
        try ctx.save()

        let result = try #require(dm.importBackupData(data))

        #expect(result.matchedSongs == 2)
        #expect(result.totalSongs == 2)
        #expect(result.newPlaylists == 1)

        #expect(s1.playCount == 7)
        #expect(s1.isFavorited)
        #expect(s1.lastPlayedDate != nil)
        #expect(s2.playCount == 3)

        let playlists = dm.fetchAllPlaylists()
        let restored = try #require(playlists.first { $0.title == "Road Trip" })
        #expect(Set(restored.songs.map(\.id)) == ["b1", "b2"])
    }

    @Test("Import merges instead of overwriting newer local data")
    func importMergesNotOverwrites() throws {
        let dm = DataManager()
        let ctx = try makeContext()
        dm.configure(with: ctx)

        let song = makeSongData(id: "m1", playCount: 2)
        ctx.insert(song)
        try ctx.save()

        let data = try #require(dm.exportBackupData())

        // Local listening continues after the backup was made.
        song.playCount = 10
        song.isFavorited = true
        try ctx.save()

        _ = try #require(dm.importBackupData(data))

        // max() merge keeps the newer, larger play count and the like.
        #expect(song.playCount == 10)
        #expect(song.isFavorited)
    }

    @Test("Songs in the backup but missing locally are skipped, not invented")
    func importSkipsUnknownSongs() throws {
        let dm = DataManager()
        let ctx = try makeContext()
        dm.configure(with: ctx)

        let song = makeSongData(id: "k1", playCount: 1)
        ctx.insert(song)
        try ctx.save()
        let data = try #require(dm.exportBackupData())

        // New context without that song.
        let dm2 = DataManager()
        let ctx2 = try makeContext()
        dm2.configure(with: ctx2)

        let result = try #require(dm2.importBackupData(data))
        #expect(result.matchedSongs == 0)
        #expect(result.totalSongs == 1)
        #expect(dm2.fetchAllSongs().isEmpty)
    }

    @Test("Existing playlist with same title is reused, songs deduplicated")
    func importReusesExistingPlaylist() throws {
        let dm = DataManager()
        let ctx = try makeContext()
        dm.configure(with: ctx)

        let song = makeSongData(id: "p1")
        ctx.insert(song)
        let playlist = PlaylistData(title: "Focus")
        ctx.insert(playlist)
        playlist.songs.append(song)
        try ctx.save()

        let data = try #require(dm.exportBackupData())
        let result = try #require(dm.importBackupData(data))

        #expect(result.newPlaylists == 0)
        let playlists = dm.fetchAllPlaylists().filter { $0.title == "Focus" }
        #expect(playlists.count == 1)
        #expect(playlists.first?.songs.count == 1)
    }

    @Test("Backup preserves playlist identity, cover and user order across a fresh store")
    func preservesPlaylistIdentityAndOrder() throws {
        let dm = DataManager()
        let ctx = try makeContext()
        dm.configure(with: ctx)
        let a = makeSongData(id: "ordered-a")
        let b = makeSongData(id: "ordered-b")
        ctx.insert(a); ctx.insert(b)
        let playlist = PlaylistData(id: "stable-playlist", title: "Ordered", coverImagePath: "Covers/custom.jpg")
        ctx.insert(playlist)
        playlist.songs = [a, b]
        playlist.songOrder = [b.id, a.id]
        try ctx.save()
        let data = try #require(dm.exportBackupData())
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(LibraryBackup.self, from: data)
        #expect(backup.playlists.first?.songIDs == [b.id, a.id])
        #expect(backup.playlists.first?.id == playlist.id)
        #expect(backup.playlists.first?.coverImagePath == playlist.coverImagePath)

        let restoredDM = DataManager()
        let restoredContext = try makeContext()
        restoredDM.configure(with: restoredContext)
        restoredContext.insert(makeSongData(id: a.id))
        restoredContext.insert(makeSongData(id: b.id))
        try restoredContext.save()
        _ = try #require(restoredDM.importBackupData(data))
        let restored = try #require(restoredDM.fetchAllPlaylists().first)
        #expect(restored.id == "stable-playlist")
        #expect(restored.coverImagePath == "Covers/custom.jpg")
        #expect(restored.songOrder == [b.id, a.id])
        #expect(restored.orderedSongs.map(\.id) == [b.id, a.id])
        restored.title = "Renamed locally"
        _ = try #require(restoredDM.importBackupData(data))
        #expect(restoredDM.fetchAllPlaylists().count == 1)
    }

    @Test("Legacy JSON restores ordered IDs into a same-title playlist without deleting local songs")
    func legacyPlaylistOrder() throws {
        let dm = DataManager()
        let ctx = try makeContext()
        dm.configure(with: ctx)
        let songs = ["a", "b", "local"].map { makeSongData(id: $0) }
        songs.forEach { ctx.insert($0) }
        let playlist = PlaylistData(title: "Legacy", coverImagePath: "local.jpg")
        ctx.insert(playlist)
        playlist.songs = songs
        playlist.songOrder = ["local", "a", "b"]
        try ctx.save()
        let json = #"{"version":1,"exportDate":"2023-11-14T22:13:20Z","songs":[],"playlists":[{"title":"Legacy","dateCreated":"2023-11-14T22:13:20Z","songIDs":["b","missing","a","b"]}]}"#
        let result = try #require(dm.importBackupData(Data(json.utf8)))
        #expect(result.newPlaylists == 0)
        #expect(playlist.songOrder == ["b", "a", "local"])
        #expect(playlist.orderedSongs.map(\.id) == ["b", "a", "local"])
        #expect(playlist.coverImagePath == "local.jpg")
    }

    @Test("Backups keep distinct same-title playlist identities")
    func distinctSameTitlePlaylists() throws {
        let dm = DataManager()
        let ctx = try makeContext()
        dm.configure(with: ctx)
        ctx.insert(PlaylistData(id: "first", title: "Same"))
        ctx.insert(PlaylistData(id: "second", title: "Same"))
        try ctx.save()
        let data = try #require(dm.exportBackupData())
        let restored = DataManager()
        restored.configure(with: try makeContext())
        _ = try #require(restored.importBackupData(data))
        #expect(Set(restored.fetchAllPlaylists().map(\.id)) == ["first", "second"])
    }

    @Test("Corrupt backup data is rejected cleanly")
    func importRejectsCorruptData() throws {
        let dm = DataManager()
        dm.configure(with: try makeContext())

        let result = dm.importBackupData(Data("not json".utf8))
        #expect(result == nil)
    }
}
