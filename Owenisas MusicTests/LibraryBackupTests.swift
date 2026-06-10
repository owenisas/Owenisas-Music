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
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
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

    @Test("Corrupt backup data is rejected cleanly")
    func importRejectsCorruptData() throws {
        let dm = DataManager()
        dm.configure(with: try makeContext())

        let result = dm.importBackupData(Data("not json".utf8))
        #expect(result == nil)
    }
}
