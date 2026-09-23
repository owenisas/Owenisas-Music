import Foundation
import Testing
@testable import Owenisas_Music

// MARK: - Shared fixtures for the CloudSync*Tests suites
// An in-memory library (stands in for SwiftData), simulated devices that
// run capture → merge → apply like the app does, and a fake ubiquity
// daemon over plain temp directories.

enum CloudFixtures {
    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    static func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    static func tempDirectory(_ label: String = "cloudsync") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes a song folder the way the downloader does (audio + cover +
    /// lyrics + meta.json) plus files that must never sync.
    @discardableResult
    static func writeSongFolder(_ name: String, in songs: URL, extras: Bool = true) throws -> URL {
        let fm = FileManager.default
        let folder = songs.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var audio = Data([0x49, 0x44, 0x33, 0x03])
        audio.append(Data(repeating: 0xAB, count: 40_000))
        try audio.write(to: folder.appendingPathComponent("\(name).mp3"))
        if extras {
            try Data(repeating: 0xFF, count: 8_000).write(to: folder.appendingPathComponent("cover.jpg"))
            try Data("WEBVTT\n\n00:00.000 --> 00:01.000\nla la".utf8).write(to: folder.appendingPathComponent("\(name).lyrics.vtt"))
            try Data(#"{"title":"Song \#(name)","artist":"Artist"}"#.utf8).write(to: folder.appendingPathComponent("meta.json"))
            try Data("debug".utf8).write(to: folder.appendingPathComponent("download-debug.log"))
            try Data("partial".utf8).write(to: folder.appendingPathComponent("audio.m4a.part"))
            try Data("tmp".utf8).write(to: folder.appendingPathComponent("scratch.tmp"))
            try Data("hidden".utf8).write(to: folder.appendingPathComponent(".DS_Store"))
        }
        return folder
    }

    static func files(in folder: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
    }
}

// MARK: - In-memory library store

@MainActor
final class InMemoryLibraryStore: CloudLibraryStore {
    struct Song: Equatable {
        var playCount = 0
        var isFavorited = false
        var lastPlayed: Date?
        var dateAdded: Date
        var position: Double = 0
    }

    struct Playlist: Equatable {
        var title: String
        var coverImagePath: String?
        var dateCreated: Date
        var songIDs: [String]
    }

    var songs: [String: Song] = [:]
    var playlists: [String: Playlist] = [:]
    var protected: Set<String> = []
    /// Folder the store indexes arriving songs from (end-to-end tests).
    var localSongs: URL?
    var indexed: [String] = []
    var applyCount = 0

    func addSong(_ id: String, added: Date = CloudFixtures.t0, plays: Int = 0, liked: Bool = false) {
        songs[id] = Song(playCount: plays, isFavorited: liked, dateAdded: added)
    }

    func addPlaylist(_ id: String, _ title: String, _ songIDs: [String], created: Date = CloudFixtures.t0) {
        playlists[id] = Playlist(title: title, coverImagePath: nil, dateCreated: created,
                                 songIDs: songIDs.filter { songs[$0] != nil })
    }

    /// Like DataManager: the row goes, and it leaves every playlist.
    func removeSong(_ id: String) {
        songs[id] = nil
        for key in playlists.keys { playlists[key]?.songIDs.removeAll { $0 == id } }
    }

    func cloudSnapshot() -> LibrarySnapshot? {
        LibrarySnapshot(
            exportDate: CloudFixtures.t0,
            songs: songs.keys.sorted().map { id in
                let song = songs[id]!
                return .init(id: id, playCount: song.playCount, isFavorited: song.isFavorited,
                             lastPlayedDate: song.lastPlayed, dateAdded: song.dateAdded,
                             playbackPosition: song.position)
            },
            playlists: playlists.keys.sorted().map { id in
                let playlist = playlists[id]!
                return .init(title: playlist.title, dateCreated: playlist.dateCreated,
                             songIDs: playlist.songIDs, id: id, coverImagePath: playlist.coverImagePath)
            }
        )
    }

    @discardableResult
    func applyCloudPlan(_ plan: LibraryApplyPlan, removeSongFolder: (String) -> Bool) -> Bool {
        applyCount += 1
        for (id, change) in plan.songChanges {
            guard var song = songs[id] else { continue }
            if let value = change.isFavorited { song.isFavorited = value }
            if let value = change.playCount { song.playCount = value }
            if let value = change.lastPlayedDate { song.lastPlayed = value }
            if let value = change.playbackPosition { song.position = value }
            songs[id] = song
        }
        for upsert in plan.playlistUpserts {
            if playlists[upsert.id] == nil, let adopt = upsert.adoptingLocalID, playlists[adopt] != nil {
                playlists[upsert.id] = playlists[adopt]
                playlists[adopt] = nil
            }
            var playlist = playlists[upsert.id] ?? Playlist(title: upsert.title, coverImagePath: upsert.coverImagePath,
                                                           dateCreated: upsert.dateCreated, songIDs: [])
            playlist.title = upsert.title
            playlist.coverImagePath = upsert.coverImagePath
            playlist.songIDs = upsert.songIDs.filter { songs[$0] != nil }
            playlists[upsert.id] = playlist
        }
        for id in plan.playlistDeletes { playlists[id] = nil }
        for id in plan.songDeletes where songs[id] != nil && !protected.contains(id) {
            guard removeSongFolder(id) else { continue }
            removeSong(id)
        }
        return true
    }

    func indexCloudFolder(_ folderName: String) {
        indexed.append(folderName)
        guard let localSongs else { return }
        let folder = localSongs.appendingPathComponent(folderName, isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        guard names.contains(where: CloudSyncFiles.isAudio), songs[folderName] == nil else { return }
        let attrs = (try? FileManager.default.attributesOfItem(atPath: folder.path)) ?? [:]
        let added = (attrs[.creationDate] as? Date) ?? Date()
        songs[folderName] = Song(dateAdded: added)
    }

    /// Mirrors what `syncFromFileSystem` would index at launch.
    func indexAll() {
        guard let localSongs else { return }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: localSongs.path)) ?? [] where !name.hasPrefix(".") {
            indexCloudFolder(name)
        }
    }

    var cloudProtectedSongIDs: Set<String> { protected }
}

// MARK: - Simulated device (library data only, no files)

/// Runs a sync pass like the app: capture local edits, merge with the other
/// devices' published files, apply, remember the new local shape.
@MainActor
final class SimDevice {
    let id: String
    var state: CloudSyncLocalState
    let store = InMemoryLibraryStore()
    var changes = LibraryLocalChanges()

    init(_ id: String) {
        self.id = id
        state = CloudSyncLocalState(deviceID: id, deviceName: id, accountFingerprint: nil)
    }

    /// The device's published file.
    var file: CloudLibraryFile { state.own }

    @discardableResult
    func sync(with others: [SimDevice], at now: Date, allowDestructive: Bool = true) -> LibraryApplyPlan {
        let snapshot = store.cloudSnapshot()!
        LibraryMergeEngine.capture(snapshot, changes: changes, state: &state, now: now)
        changes = LibraryLocalChanges()
        let plan = LibraryMergeEngine.merge(snapshot, others: others.map(\.file), state: &state, now: now,
                                            allowDestructive: allowDestructive, protectedSongIDs: store.protected)
        store.applyCloudPlan(plan) { _ in true }
        LibraryMergeEngine.refreshMarks(from: store.cloudSnapshot()!, state: &state)
        return plan
    }

    // User actions, reported the way DataManager / the player report them.

    func like(_ songID: String, _ value: Bool, at date: Date) {
        store.songs[songID]?.isFavorited = value
        changes.favorites[songID] = .init(value: value, at: date)
    }

    func play(_ songID: String, times: Int = 1, at date: Date) {
        store.songs[songID]?.playCount += times
        store.songs[songID]?.lastPlayed = date
    }

    func savePosition(_ songID: String, _ position: Double, at date: Date) {
        store.songs[songID]?.position = position
        changes.positions[songID] = .init(value: position, at: date)
    }

    func deleteSong(_ songID: String, at date: Date) {
        store.removeSong(songID)
        LibraryMergeEngine.recordSongDeletions([songID], at: date, state: &state)
    }

    func deletePlaylist(_ playlistID: String, at date: Date) {
        let title = store.playlists[playlistID]?.title
        store.playlists[playlistID] = nil
        LibraryMergeEngine.recordPlaylistDeletion(id: playlistID, title: title, at: date, state: &state)
    }
}

/// Syncs every device against all the others, `rounds` times.
@MainActor
func syncAll(_ devices: [SimDevice], at now: Date, rounds: Int = 2, allowDestructive: Bool = true) {
    for round in 0..<rounds {
        for device in devices {
            device.sync(with: devices.filter { $0 !== device }, at: now.addingTimeInterval(Double(round)),
                        allowDestructive: allowDestructive)
        }
    }
}

// MARK: - Fake ubiquity daemon

/// Eviction turns a container file into a legacy `.name.icloud` placeholder
/// (content kept aside); starting a download brings it back.
final class FakeUbiquity: UbiquityFileOperations, @unchecked Sendable {
    private let lock = NSLock()
    private var stash: [String: Data] = [:]
    private(set) var downloadRequests: [URL] = []
    private(set) var evictions: [URL] = []
    /// When false, download requests are only recorded (still "in flight").
    var completesDownloads = true

    func startDownloading(_ url: URL) throws {
        lock.lock(); defer { lock.unlock() }
        downloadRequests.append(url)
        guard completesDownloads else { return }
        let placeholder = Self.placeholderURL(for: url)
        guard FileManager.default.fileExists(atPath: placeholder.path) else { return }
        let data = stash[url.standardizedFileURL.path] ?? Data()
        try data.write(to: url)
        try FileManager.default.removeItem(at: placeholder)
    }

    func evict(_ url: URL) throws {
        lock.lock(); defer { lock.unlock() }
        evictions.append(url)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        stash[url.standardizedFileURL.path] = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        try Data("placeholder".utf8).write(to: Self.placeholderURL(for: url))
    }

    /// Puts a file into the container as "in iCloud, not on this device".
    func seedCloudOnly(_ data: Data, at url: URL) throws {
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        stash[url.standardizedFileURL.path] = data
        try Data("placeholder".utf8).write(to: Self.placeholderURL(for: url))
    }

    static func placeholderURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
    }
}

// MARK: - Fixture sanity

@MainActor
struct CloudSyncFixturesTests {
    @Test("In-memory store snapshots and applies like the SwiftData store")
    func inMemoryStoreRoundTrip() throws {
        let store = InMemoryLibraryStore()
        store.addSong("a")
        store.addSong("b", liked: true)
        store.addPlaylist("p", "Mix", ["b", "a", "missing"])
        let snapshot = try #require(store.cloudSnapshot())
        #expect(snapshot.songs.map(\.id) == ["a", "b"])
        #expect(snapshot.playlists.first?.songIDs == ["b", "a"])

        var plan = LibraryApplyPlan()
        plan.songChanges["a"] = .init(isFavorited: true)
        plan.playlistUpserts = [.init(id: "p", title: "Mix 2", coverImagePath: nil, dateCreated: CloudFixtures.t0,
                                      songIDs: ["a"], adoptingLocalID: nil)]
        store.applyCloudPlan(plan) { _ in true }
        #expect(store.songs["a"]?.isFavorited == true)
        #expect(store.playlists["p"] == .init(title: "Mix 2", coverImagePath: nil, dateCreated: CloudFixtures.t0, songIDs: ["a"]))
    }
}
