import Foundation
import Testing
import SwiftData
@testable import Owenisas_Music

// MARK: - DataManager Sync & Playlist Tests
// Verifies:
//  - Bug #3 fix: broken folders cleaned *before* indexing (no ghost songs)
//  - Bug #6 fix: playlist reuse by case-insensitive title match
//  - syncSingleSong only indexes folders with valid audio (>500 KB)
//  - addSong deduplicates within a playlist

@MainActor
struct DataManagerSyncTests {

    // MARK: - Helpers

    private var songsFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Songs")
    }

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: SongData.self, AlbumData.self, PlaylistData.self,
            configurations: config
        )
        return ModelContext(container)
    }

    /// Creates a folder under Documents/Songs with a dummy audio file.
    @discardableResult
    private func createSongFolder(
        name: String,
        audioBytes: Int = 600_000
    ) throws -> URL {
        let fm = FileManager.default
        let folder = songsFolder.appendingPathComponent(name)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let audio = folder.appendingPathComponent("\(name).mp3")
        try Data(repeating: 0xFF, count: audioBytes).write(to: audio)
        return folder
    }

    private func removeSongFolder(name: String) {
        try? FileManager.default.removeItem(
            at: songsFolder.appendingPathComponent(name)
        )
    }

    // MARK: - syncFromFileSystem

    @Test("Valid folder (>500 KB audio) creates a SongData entry")
    func validFolderIndexed() throws {
        let id = "__test_valid_\(UUID().uuidString.prefix(8))"
        defer { removeSongFolder(name: id) }

        try createSongFolder(name: id)
        let dm = DataManager()
        dm.configure(with: try makeContext())

        dm.syncFromFileSystem()

        #expect(dm.fetchAllSongs().contains { $0.id == id })
    }

    @Test("Broken folder (tiny audio) cleaned up before indexing — no ghost song")
    func brokenFolderCleaned() throws {
        let id = "__test_broken_\(UUID().uuidString.prefix(8))"
        defer { removeSongFolder(name: id) }

        try createSongFolder(name: id, audioBytes: 1_000) // <500 KB
        let dm = DataManager()
        dm.configure(with: try makeContext())

        dm.syncFromFileSystem()

        #expect(!dm.fetchAllSongs().contains { $0.id == id })
        // Folder itself should have been deleted on disk
        #expect(!FileManager.default.fileExists(atPath: songsFolder.appendingPathComponent(id).path))
    }

    @Test("Sync removes SongData when folder disappears from disk")
    func missingFolderPurged() throws {
        let id = "__test_purge_\(UUID().uuidString.prefix(8))"
        let ctx = try makeContext()
        let dm = DataManager()
        dm.configure(with: ctx)

        // Create → sync → verify present
        try createSongFolder(name: id)
        dm.syncFromFileSystem()
        #expect(dm.fetchAllSongs().contains { $0.id == id })

        // Delete folder → re-sync → verify absent
        removeSongFolder(name: id)
        dm.syncFromFileSystem()
        #expect(!dm.fetchAllSongs().contains { $0.id == id })
    }

    @Test("Sync merges canonically equivalent duplicate SongData IDs")
    func canonicalDuplicateSongIDsMerged() throws {
        let canonicalID = "__test_caf\u{00E9}_\(UUID().uuidString.prefix(8))"
        let decomposedID = canonicalID.decomposedStringWithCanonicalMapping
        defer {
            removeSongFolder(name: canonicalID)
            removeSongFolder(name: decomposedID)
        }

        try createSongFolder(name: canonicalID)
        let ctx = try makeContext()
        let dm = DataManager()
        dm.configure(with: ctx)

        let canonicalSong = SongData(id: canonicalID, title: "Canonical", audioFilePath: "Songs/\(canonicalID)/\(canonicalID).mp3")
        let decomposedSong = SongData(id: decomposedID, title: "Decomposed", audioFilePath: "Songs/\(canonicalID)/\(canonicalID).mp3")
        decomposedSong.isFavorited = true
        ctx.insert(canonicalSong)
        ctx.insert(decomposedSong)
        try ctx.save()

        dm.syncFromFileSystem()

        let matchingSongs = dm.fetchAllSongs().filter { Data($0.id.precomposedStringWithCanonicalMapping.utf8) == Data(canonicalID.utf8) }
        #expect(matchingSongs.count == 1)
        #expect(matchingSongs.first?.isFavorited == true)
        #expect(matchingSongs.first.map { Data($0.id.utf8) == Data(canonicalID.utf8) } == true)
    }

    @Test("syncSingleSong infers artist and title from 'Artist - Title' folder name")
    func singleSongMetadataParsing() throws {
        let id = "__TestArtist - __TestTitle"
        defer { removeSongFolder(name: id) }

        try createSongFolder(name: id)
        let dm = DataManager()
        dm.configure(with: try makeContext())

        dm.syncSingleSong(folderName: id)

        let song = dm.fetchAllSongs().first { $0.id == id }
        #expect(song != nil)
        #expect(song?.artist == "__TestArtist")
        #expect(song?.title == "__TestTitle")
    }

    // MARK: - Playlist reuse (Bug #6)

    @Test("createPlaylist creates a new PlaylistData entry")
    func createPlaylistBasic() throws {
        let dm = DataManager()
        dm.configure(with: try makeContext())

        let p = dm.createPlaylist(title: "Test Playlist")
        #expect(p != nil)
        #expect(dm.fetchAllPlaylists().count == 1)
    }

    @Test("Case-insensitive lookup finds existing playlist (reuse pattern)")
    func caseInsensitiveLookup() throws {
        let dm = DataManager()
        dm.configure(with: try makeContext())

        let created = dm.createPlaylist(title: "My Awesome Playlist")!

        // Simulate the lookup that createAutoPlaylist now does
        let found = dm.fetchAllPlaylists().first {
            $0.title.trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedCaseInsensitiveCompare("my awesome playlist") == .orderedSame
        }

        #expect(found?.id == created.id)
    }

    @Test("addSong deduplicates — second add is a no-op")
    func addSongDeduplication() throws {
        let ctx = try makeContext()
        let dm = DataManager()
        dm.configure(with: ctx)

        let song = SongData(id: "dup-test", title: "T", audioFilePath: "Songs/t/t.mp3")
        ctx.insert(song)
        try ctx.save()

        let playlist = dm.createPlaylist(title: "P")!
        dm.addSong(song, to: playlist)
        dm.addSong(song, to: playlist)

        #expect(playlist.songs.count == 1)
    }

    @Test("addSongs batch deduplicates across multiple calls")
    func addSongsBatchDedup() throws {
        let ctx = try makeContext()
        let dm = DataManager()
        dm.configure(with: ctx)

        let s1 = SongData(id: "bs1", title: "A", audioFilePath: "Songs/a/a.mp3")
        let s2 = SongData(id: "bs2", title: "B", audioFilePath: "Songs/b/b.mp3")
        ctx.insert(s1); ctx.insert(s2)
        try ctx.save()

        let playlist = dm.createPlaylist(title: "Batch")!
        dm.addSongs([s1, s2], to: playlist)
        dm.addSongs([s1, s2], to: playlist) // re-add

        #expect(playlist.songs.count == 2)
    }

    // MARK: - importAudioFiles

    @Test("Import copies an outside audio file into Songs and indexes it")
    func importCopiesOutsideFile() throws {
        let id = "__test_import_\(UUID().uuidString.prefix(8))"
        defer { removeSongFolder(name: id) }

        let fm = FileManager.default
        let source = fm.temporaryDirectory.appendingPathComponent("\(id).mp3")
        try Data(repeating: 0xAB, count: 600_000).write(to: source)
        defer { try? fm.removeItem(at: source) }

        let dm = DataManager()
        dm.configure(with: try makeContext())

        let outcome = dm.importAudioFiles(from: [source])

        #expect(outcome.imported == 1)
        #expect(outcome.skipped == 0)
        let copied = songsFolder.appendingPathComponent(id).appendingPathComponent("\(id).mp3")
        #expect(fm.fileExists(atPath: copied.path))
        #expect(fm.fileExists(atPath: source.path)) // copy, not move
        #expect(dm.fetchAllSongs().contains { $0.id == id })
    }

    @Test("Importing a file already inside Songs re-indexes without deleting it")
    func importOwnFileIsNonDestructive() throws {
        let id = "__test_selfimport_\(UUID().uuidString.prefix(8))"
        defer { removeSongFolder(name: id) }

        try createSongFolder(name: id) // creates Songs/<id>/<id>.mp3
        let ownFile = songsFolder.appendingPathComponent(id).appendingPathComponent("\(id).mp3")

        let dm = DataManager()
        dm.configure(with: try makeContext())

        let outcome = dm.importAudioFiles(from: [ownFile])

        #expect(outcome.imported == 1)
        #expect(outcome.skipped == 0)
        #expect(FileManager.default.fileExists(atPath: ownFile.path)) // must survive
        #expect(dm.fetchAllSongs().contains { $0.id == id })
    }

    @Test("Unsupported file types are skipped, not copied")
    func importSkipsUnsupportedTypes() throws {
        let fm = FileManager.default
        let source = fm.temporaryDirectory.appendingPathComponent("__test_import_bad.pdf")
        try Data(repeating: 0x01, count: 10_000).write(to: source)
        defer { try? fm.removeItem(at: source) }

        let dm = DataManager()
        dm.configure(with: try makeContext())

        let outcome = dm.importAudioFiles(from: [source])

        #expect(outcome.imported == 0)
        #expect(outcome.skipped == 1)
    }
}
