import Foundation
import Testing
@testable import Owenisas_Music

// MARK: - File-system mirror against temp directories
// Temp dirs stand in for local Documents/Songs and the iCloud container
// (injected). FakeUbiquity plays the iCloud daemon: eviction leaves a
// `.name.icloud` placeholder, starting a download brings the file back.

@MainActor
struct CloudSyncMirrorTests {

    private struct Device {
        let id: String
        let root: URL
        let songs: URL
        let mirror: CloudFileMirror
        let engine: CloudSyncEngine
        let store: InMemoryLibraryStore
    }

    private func makeDevice(_ id: String, container: URL, ubiquity: FakeUbiquity) -> Device {
        let root = CloudFixtures.tempDirectory("device-\(id)")
        let songs = root.appendingPathComponent("Songs", isDirectory: true)
        try? FileManager.default.createDirectory(at: songs, withIntermediateDirectories: true)
        let paths = CloudSyncLocalPaths.rooted(at: root.appendingPathComponent("CloudSync", isDirectory: true))
        let mirror = CloudFileMirror(localSongs: songs, containerDocuments: container,
                                     stagingDirectory: paths.stagingDirectory,
                                     holdingDirectory: paths.holdingDirectory, ops: ubiquity)
        let engine = CloudSyncEngine(mirror: mirror, stateURL: paths.stateURL, loadedState: nil,
                                     deviceID: id, deviceName: id, accountFingerprint: nil)
        let store = InMemoryLibraryStore()
        store.localSongs = songs
        return Device(id: id, root: root, songs: songs, mirror: mirror, engine: engine, store: store)
    }

    private func makeMirror(ubiquity: FakeUbiquity = FakeUbiquity()) -> (CloudFileMirror, URL, URL) {
        let local = CloudFixtures.tempDirectory("local")
        let container = CloudFixtures.tempDirectory("container")
        let support = CloudFixtures.tempDirectory("support")
        let mirror = CloudFileMirror(localSongs: local, containerDocuments: container,
                                     stagingDirectory: support.appendingPathComponent("Staging"),
                                     holdingDirectory: support.appendingPathComponent("Removed"), ops: ubiquity)
        return (mirror, local, container)
    }

    // MARK: Upload

    @Test("Upload copies song files only — no debug log, temp, partial or hidden files")
    func uploadCopiesSyncableFiles() throws {
        let (mirror, local, _) = makeMirror()
        try CloudFixtures.writeSongFolder("vid123", in: local)

        try mirror.uploadFolder("vid123")

        let uploaded = CloudFixtures.files(in: mirror.remoteSongs.appendingPathComponent("vid123"))
        #expect(uploaded == ["vid123.mp3", "cover.jpg", "vid123.lyrics.vtt", "meta.json"])
        let original = try Data(contentsOf: local.appendingPathComponent("vid123/vid123.mp3"))
        #expect(try Data(contentsOf: mirror.remoteSongs.appendingPathComponent("vid123/vid123.mp3")) == original)
        // The local copy is untouched.
        #expect(CloudFixtures.files(in: local.appendingPathComponent("vid123")).contains("download-debug.log"))
    }

    @Test("Upload never overwrites a file already in iCloud (or its placeholder)")
    func uploadIsAddOnly() throws {
        let (mirror, local, _) = makeMirror()
        try CloudFixtures.writeSongFolder("s", in: local)
        let remote = mirror.remoteSongs.appendingPathComponent("s", isDirectory: true)
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try Data("remote meta".utf8).write(to: remote.appendingPathComponent("meta.json"))
        try Data("placeholder".utf8).write(to: remote.appendingPathComponent(".cover.jpg.icloud"))

        try mirror.uploadFolder("s")

        #expect(try String(contentsOf: remote.appendingPathComponent("meta.json"), encoding: .utf8) == "remote meta")
        #expect(!FileManager.default.fileExists(atPath: remote.appendingPathComponent("cover.jpg").path))
        #expect(FileManager.default.fileExists(atPath: remote.appendingPathComponent("s.mp3").path))
    }

    // MARK: Download

    @Test("A placeholder-only song is downloaded, imported atomically, then evicted")
    func placeholderDownloadImportEvict() throws {
        let ubiquity = FakeUbiquity()
        let (mirror, local, _) = makeMirror(ubiquity: ubiquity)
        let remoteFolder = mirror.remoteSongs.appendingPathComponent("vidABC", isDirectory: true)
        var audio = Data([0x49, 0x44, 0x33, 0x03]); audio.append(Data(repeating: 1, count: 30_000))
        try ubiquity.seedCloudOnly(audio, at: remoteFolder.appendingPathComponent("vidABC.m4a"))
        try FileManager.default.createDirectory(at: remoteFolder, withIntermediateDirectories: true)
        try Data(#"{"title":"T"}"#.utf8).write(to: remoteFolder.appendingPathComponent("meta.json"))

        func plan() -> MirrorPlan {
            CloudMirrorPlanner.plan(MirrorPlanInput(
                local: mirror.scanLocalFolders(), remote: mirror.remoteFolders(queryEntries: []),
                tombstones: [:], mirrored: [:], pendingRemoteDeletes: [:], remoteListingComplete: true))
        }

        let first = plan()
        #expect(first.startDownloads["vidABC"] == ["vidABC.m4a"])
        #expect(first.importFolders.isEmpty)
        let firstResult = mirror.execute(first)
        #expect(ubiquity.downloadRequests.map(\.lastPathComponent) == ["vidABC.m4a"])
        #expect(firstResult.importedFolders.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: local.appendingPathComponent("vidABC").path))

        let second = plan()
        #expect(second.importFolders == ["vidABC"])
        let secondResult = mirror.execute(second)
        #expect(secondResult.importedFolders == ["vidABC"])
        #expect(CloudFixtures.files(in: local.appendingPathComponent("vidABC")) == ["vidABC.m4a", "meta.json"])
        #expect(try Data(contentsOf: local.appendingPathComponent("vidABC/vidABC.m4a")) == audio)
        // Container copy evicted so the song isn't stored twice.
        #expect(Set(ubiquity.evictions.map(\.lastPathComponent)) == ["vidABC.m4a", "meta.json"])
        #expect(FileManager.default.fileExists(atPath: FakeUbiquity.placeholderURL(for: remoteFolder.appendingPathComponent("vidABC.m4a")).path))
        // Staging cleaned up.
        #expect(CloudFixtures.files(in: mirror.stagingDirectory).isEmpty)
    }

    @Test("Importing into an existing folder only adds missing files")
    func importIntoExistingFolderIsAddOnly() throws {
        let (mirror, local, _) = makeMirror()
        try CloudFixtures.writeSongFolder("s", in: mirror.remoteSongs, extras: true)
        let localFolder = local.appendingPathComponent("s", isDirectory: true)
        try FileManager.default.createDirectory(at: localFolder, withIntermediateDirectories: true)
        try Data("local audio".utf8).write(to: localFolder.appendingPathComponent("s.mp3"))

        let outcome = try mirror.importFolder("s")

        #expect(outcome == .merged("s"))
        #expect(try String(contentsOf: localFolder.appendingPathComponent("s.mp3"), encoding: .utf8) == "local audio")
        #expect(CloudFixtures.files(in: localFolder) == ["s.mp3", "cover.jpg", "s.lyrics.vtt", "meta.json"])
    }

    @Test("Files another device added later (lyrics) arrive without touching the rest")
    func importFilesAddsLyrics() throws {
        let (mirror, local, _) = makeMirror()
        try CloudFixtures.writeSongFolder("s", in: local, extras: false)
        let remote = mirror.remoteSongs.appendingPathComponent("s", isDirectory: true)
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try Data("WEBVTT".utf8).write(to: remote.appendingPathComponent("s.en.vtt"))

        let added = try mirror.importFiles(.init(local: "s", remote: "s", files: ["s.en.vtt"]))
        #expect(added == 1)
        #expect(CloudFixtures.files(in: local.appendingPathComponent("s")) == ["s.mp3", "s.en.vtt"])
    }

    // MARK: Deletes

    @Test("Removing from iCloud deletes the container folder only")
    func removeRemoteFolder() throws {
        let (mirror, local, _) = makeMirror()
        try CloudFixtures.writeSongFolder("s", in: local)
        try mirror.uploadFolder("s")
        try mirror.removeRemoteFolder("s")
        #expect(!FileManager.default.fileExists(atPath: mirror.remoteSongs.appendingPathComponent("s").path))
        #expect(FileManager.default.fileExists(atPath: local.appendingPathComponent("s/s.mp3").path))
    }

    @Test("A song deleted elsewhere is set aside, not destroyed, and purged after the holding period")
    func holdingArea() throws {
        let (mirror, local, _) = makeMirror()
        try CloudFixtures.writeSongFolder("s", in: local)
        let now = Date()

        #expect(mirror.moveLocalFolderToHolding("s", now: now))
        #expect(!FileManager.default.fileExists(atPath: local.appendingPathComponent("s").path))
        let held = CloudFixtures.files(in: mirror.holdingDirectory)
        #expect(held == ["\(Int(now.timeIntervalSince1970))--s"])
        #expect(mirror.moveLocalFolderToHolding("missing", now: now)) // nothing to move is fine

        mirror.purgeHolding(now: now.addingTimeInterval(24 * 60 * 60))
        #expect(CloudFixtures.files(in: mirror.holdingDirectory).count == 1)
        mirror.purgeHolding(now: now.addingTimeInterval(CloudSyncConstants.holdingPeriod + 60))
        #expect(CloudFixtures.files(in: mirror.holdingDirectory).isEmpty)
    }

    // MARK: Library files

    @Test("Library files: own written, others read once per change, bad or mismatched files skipped")
    func libraryFiles() throws {
        let ubiquity = FakeUbiquity()
        let (mirror, _, _) = makeMirror(ubiquity: ubiquity)
        let own = CloudLibraryFile(deviceID: "me", updatedAt: CloudFixtures.t0)
        try mirror.writeOwnLibraryFile(try CloudSyncCoding.encoder().encode(own), deviceID: "me")

        var other = CloudLibraryFile(deviceID: "other", updatedAt: CloudFixtures.t0)
        other.deletedSongs["x"] = CloudFixtures.at(5)
        try CloudSyncCoding.encoder().encode(other).write(to: mirror.libraryFileURL(deviceID: "other"))
        try Data("not json".utf8).write(to: mirror.libraryFileURL(deviceID: "broken"))
        let impostor = CloudLibraryFile(deviceID: "someone-else", updatedAt: CloudFixtures.t0)
        try CloudSyncCoding.encoder().encode(impostor).write(to: mirror.libraryFileURL(deviceID: "renamed"))
        try ubiquity.seedCloudOnly(try CloudSyncCoding.encoder().encode(CloudLibraryFile(deviceID: "far", updatedAt: CloudFixtures.t0)),
                                   at: mirror.libraryFileURL(deviceID: "far"))
        ubiquity.completesDownloads = false

        let first = mirror.readLibraryFiles(ownDeviceID: "me")
        #expect(first.ownFileExists)
        #expect(first.files == [other])
        #expect(ubiquity.downloadRequests.map(\.lastPathComponent) == ["far.json"])

        let unchanged = mirror.readLibraryFiles(ownDeviceID: "me")
        #expect(unchanged.files.isEmpty)
    }

    // MARK: Two devices, end to end

    @Test("Two devices: upload → download → like → playlist → delete, through one container")
    func twoDevicesEndToEnd() throws {
        let ubiquity = FakeUbiquity()
        let container = CloudFixtures.tempDirectory("shared-container")
        let a = makeDevice("A", container: container, ubiquity: ubiquity)
        let b = makeDevice("B", container: container, ubiquity: ubiquity)
        try CloudFixtures.writeSongFolder("song1", in: a.songs)
        try CloudFixtures.writeSongFolder("keep", in: b.songs)
        a.store.indexAll()
        b.store.indexAll()

        // A uploads song1; B uploads keep.
        a.engine.runPass(store: a.store)
        b.engine.runPass(store: b.store)
        #expect(FileManager.default.fileExists(atPath: container.appendingPathComponent("Songs/song1/song1.mp3").path)
                || FileManager.default.fileExists(atPath: container.appendingPathComponent("Songs/song1/.song1.mp3.icloud").path))
        #expect(!CloudFixtures.files(in: container.appendingPathComponent("Songs/song1")).contains("download-debug.log"))
        #expect(FileManager.default.fileExists(atPath: a.mirror.libraryFileURL(deviceID: "A").path))

        // A few passes: evict, download placeholders, import, index.
        for _ in 0..<3 {
            a.engine.runPass(store: a.store)
            b.engine.runPass(store: b.store)
        }
        #expect(b.store.songs["song1"] != nil)
        #expect(a.store.songs["keep"] != nil)
        #expect(CloudFixtures.files(in: b.songs.appendingPathComponent("song1")) ==
                ["song1.mp3", "cover.jpg", "song1.lyrics.vtt", "meta.json"])
        #expect(!ubiquity.evictions.isEmpty)

        // Like + playlist on A reach B.
        a.store.songs["song1"]?.isFavorited = true
        a.engine.recordFavorite(songID: "song1", value: true, at: Date())
        a.store.addPlaylist("p1", "Both", ["keep", "song1"])
        a.engine.runPass(store: a.store)
        b.engine.runPass(store: b.store)
        #expect(b.store.songs["song1"]?.isFavorited == true)
        #expect(b.store.playlists["p1"]?.songIDs == ["keep", "song1"])

        // A deletes song1 (user delete): gone from iCloud, set aside on B.
        let deletedAt = Date()
        a.store.removeSong("song1")
        try FileManager.default.removeItem(at: a.songs.appendingPathComponent("song1"))
        a.engine.recordSongDeletions(["song1"], at: deletedAt)
        a.engine.runPass(store: a.store)
        #expect(!FileManager.default.fileExists(atPath: container.appendingPathComponent("Songs/song1").path))
        #expect(a.engine.state.pendingRemoteDeletes.isEmpty)

        b.engine.runPass(store: b.store, allowDestructive: false)
        #expect(b.store.songs["song1"] != nil) // waits for a safe moment
        b.engine.runPass(store: b.store, allowDestructive: true)
        #expect(b.store.songs["song1"] == nil)
        #expect(!FileManager.default.fileExists(atPath: b.songs.appendingPathComponent("song1").path))
        #expect(CloudFixtures.files(in: b.engine.mirror.holdingDirectory).count == 1)
        #expect(b.store.playlists["p1"]?.songIDs == ["keep"])

        // Nothing else was touched, and further passes are quiet.
        #expect(b.store.songs["keep"] != nil && a.store.songs["keep"] != nil)
        for _ in 0..<2 {
            let passA = a.engine.runPass(store: a.store)
            let passB = b.engine.runPass(store: b.store)
            #expect(passA?.plan.isEmpty == true)
            #expect(passB?.plan.isEmpty == true)
            #expect(passA?.result.importedFolders.isEmpty == true)
            #expect(passB?.result.uploadedFolders.isEmpty == true)
        }
        #expect(!FileManager.default.fileExists(atPath: container.appendingPathComponent("Songs/song1").path))
    }

    @Test("State survives a relaunch: tombstones and mirrored folders are reloaded")
    func stateRoundTrip() throws {
        let ubiquity = FakeUbiquity()
        let container = CloudFixtures.tempDirectory("container")
        let device = makeDevice("A", container: container, ubiquity: ubiquity)
        try CloudFixtures.writeSongFolder("s", in: device.songs)
        device.store.indexAll()
        device.engine.runPass(store: device.store)
        device.engine.recordSongDeletions(["gone"], at: CloudFixtures.at(1))
        device.engine.saveStateNow()

        let loaded = try #require(CloudSyncEngine.loadState(from: device.engine.stateURL))
        #expect(loaded == device.engine.state)
        #expect(loaded.own.deletedSongs["gone"] == CloudFixtures.at(1))
        #expect(loaded.mirroredFolders["s"] != nil)

        let relaunched = CloudSyncEngine(mirror: device.mirror, stateURL: device.engine.stateURL, loadedState: loaded,
                                         deviceID: "A", deviceName: "A", accountFingerprint: nil)
        #expect(relaunched.resumedExistingState)
        let otherDevice = CloudSyncEngine(mirror: device.mirror, stateURL: device.engine.stateURL, loadedState: loaded,
                                          deviceID: "B", deviceName: "B", accountFingerprint: nil)
        #expect(!otherDevice.resumedExistingState)
        #expect(otherDevice.state.own.deletedSongs.isEmpty)
    }
}
