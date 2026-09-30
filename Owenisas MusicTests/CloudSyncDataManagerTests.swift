import Foundation
import Testing
import SwiftData
@testable import Owenisas_Music

// MARK: - SwiftData side of iCloud sync
// DataManager's snapshot/apply (the CloudLibraryStore conformance), the
// notifications sync listens to, and graceful no-iCloud behaviour.

@MainActor
struct CloudSyncDataManagerTests {

    private func makeManager() throws -> (DataManager, ModelContext) {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: SongData.self, AlbumData.self, PlaylistData.self, configurations: config)
        let context = ModelContext(container)
        let manager = DataManager()
        manager.configure(with: context)
        return (manager, context)
    }

    private func song(_ id: String, _ context: ModelContext, liked: Bool = false, plays: Int = 0) -> SongData {
        let song = SongData(id: id, title: "Song \(id)", audioFilePath: "Songs/\(id)/\(id).mp3",
                            dateAdded: CloudFixtures.t0, playCount: plays, isFavorited: liked)
        context.insert(song)
        return song
    }

    @Test("Cloud apply refreshes the current song and every cached duplicate")
    func cloudApplyRefreshesPlayer() throws {
        let (manager, context) = try makeManager()
        let a = song("cloud-cache-a", context)
        try context.save()
        let player = MusicPlayerManager.shared
        player.stop()
        defer { player.stop(); player.queue = [] }
        player.queue = [Song.from(a), Song.from(a)]
        player.currentSong = Song.from(a)
        var plan = LibraryApplyPlan()
        plan.songChanges[a.id] = .init(isFavorited: true, playCount: nil, lastPlayedDate: nil, playbackPosition: 600)
        #expect(manager.applyCloudPlan(plan) { _ in true })
        #expect(player.currentSong?.isFavorited == true)
        #expect(player.queue.allSatisfy { $0.isFavorited && $0.savedPosition == 600 })
    }

    @Test("Snapshot carries playlist ids, user order and covers")
    func snapshotShape() throws {
        let (manager, context) = try makeManager()
        let a = song("a", context, liked: true, plays: 4)
        let b = song("b", context)
        b.playbackPosition = 1_234
        let playlist = PlaylistData(id: "p1", title: "Mix", coverImagePath: "Songs/a/cover.jpg", dateCreated: CloudFixtures.t0)
        context.insert(playlist)
        playlist.songs = [a, b]
        playlist.songOrder = ["b", "a"]
        try context.save()

        let snapshot = try #require(manager.cloudSnapshot())
        let snapA = try #require(snapshot.songs.first { $0.id == "a" })
        #expect(snapA.isFavorited && snapA.playCount == 4)
        #expect(snapshot.songs.first { $0.id == "b" }?.playbackPosition == 1_234)
        let snapPlaylist = try #require(snapshot.playlists.first)
        #expect(snapPlaylist.id == "p1")
        #expect(snapPlaylist.songIDs == ["b", "a"])
        #expect(snapPlaylist.coverImagePath == "Songs/a/cover.jpg")
    }

    @Test("No library yet → no snapshot (never mistaken for an empty library)")
    func noContextNoSnapshot() {
        #expect(DataManager().cloudSnapshot() == nil)
    }

    @Test("Applying a merge updates likes, counts, dates, positions and playlists")
    func applyPlan() throws {
        let (manager, context) = try makeManager()
        let a = song("a", context)
        let b = song("b", context)
        let c = song("c", context)
        let local = PlaylistData(id: "local-dup", title: "Road Trip", dateCreated: CloudFixtures.t0)
        let doomed = PlaylistData(id: "doomed", title: "Old", dateCreated: CloudFixtures.t0)
        context.insert(local)
        context.insert(doomed)
        local.songs = [c]
        try context.save()

        var plan = LibraryApplyPlan()
        plan.songChanges["a"] = .init(isFavorited: true, playCount: 9, lastPlayedDate: CloudFixtures.at(50), playbackPosition: 600)
        plan.playlistUpserts = [
            .init(id: "shared", title: "Road Trip", coverImagePath: nil, dateCreated: CloudFixtures.t0,
                  songIDs: ["c", "a", "not-here"], adoptingLocalID: "local-dup"),
            .init(id: "new", title: "Fresh", coverImagePath: "Songs/b/cover.jpg", dateCreated: CloudFixtures.at(5),
                  songIDs: ["b", "a"], adoptingLocalID: nil),
        ]
        plan.playlistDeletes = ["doomed"]
        #expect(manager.applyCloudPlan(plan) { _ in true })

        #expect(a.isFavorited && a.playCount == 9 && a.lastPlayedDate == CloudFixtures.at(50) && a.playbackPosition == 600)
        let playlists = manager.fetchAllPlaylists()
        #expect(Set(playlists.map(\.id)) == ["shared", "new"])
        let shared = try #require(playlists.first { $0.id == "shared" })
        #expect(shared === local) // the local duplicate took the shared id in place
        #expect(shared.orderedSongs.map(\.id) == ["c", "a"])
        let fresh = try #require(playlists.first { $0.id == "new" })
        #expect(fresh.orderedSongs.map(\.id) == ["b", "a"])
        #expect(fresh.coverImagePath == "Songs/b/cover.jpg")
        _ = b
    }

    @Test("A tombstoned song is removed only after its folder was set aside")
    func songDeleteNeedsFolderSetAside() throws {
        let (manager, context) = try makeManager()
        _ = song("x", context)
        _ = song("y", context)
        try context.save()
        var plan = LibraryApplyPlan()
        plan.songDeletes = ["x", "y"]

        var asked: [String] = []
        manager.applyCloudPlan(plan) { id in
            asked.append(id)
            return id == "y"
        }
        #expect(asked.sorted() == ["x", "y"])
        #expect(manager.fetchAllSongs().map(\.id) == ["x"])
    }

    @Test("Snapshot → merge → apply → snapshot settles (no second-pass changes)")
    func applyIsIdempotentThroughEngine() throws {
        let (manager, context) = try makeManager()
        _ = song("a", context, liked: true, plays: 2)
        let p = PlaylistData(id: "p", title: "Mine", dateCreated: CloudFixtures.t0)
        context.insert(p)
        try context.save()

        var state = CloudSyncLocalState(deviceID: "me", deviceName: nil, accountFingerprint: nil)
        var other = CloudLibraryFile(deviceID: "other", updatedAt: CloudFixtures.t0)
        other.songs["a"] = CloudSongRecord(playCount: 3)
        other.playlists["q"] = CloudPlaylistRecord(title: "Theirs", songOrder: ["a"], dateCreated: CloudFixtures.t0,
                                                   modifiedAt: CloudFixtures.at(1))
        for pass in 0..<3 {
            let snapshot = try #require(manager.cloudSnapshot())
            LibraryMergeEngine.capture(snapshot, changes: .init(), state: &state, now: CloudFixtures.at(10))
            let plan = LibraryMergeEngine.merge(snapshot, others: [other], state: &state, now: CloudFixtures.at(10),
                                                allowDestructive: true)
            if pass > 0 { #expect(plan.isEmpty, "pass \(pass): \(plan)") }
            manager.applyCloudPlan(plan) { _ in true }
            LibraryMergeEngine.refreshMarks(from: try #require(manager.cloudSnapshot()), state: &state)
        }
        #expect(manager.fetchAllSongs().first?.playCount == 5)
        #expect(Set(manager.fetchAllPlaylists().map(\.title)) == ["Mine", "Theirs"])
    }

    @Test("User deletes and like toggles post the notifications sync records")
    func hooksPostNotifications() async throws {
        let (manager, context) = try makeManager()
        _ = song("n1", context)
        let playlist = PlaylistData(id: "pl", title: "Gone Soon", dateCreated: CloudFixtures.t0)
        context.insert(playlist)
        try context.save()

        final class Recorder: @unchecked Sendable {
            var deletedSongs: [String] = []
            var deletedPlaylist: (id: String?, title: String?)
            var favorite: (id: String?, value: Bool?)
        }
        let seen = Recorder()
        let center = NotificationCenter.default
        let tokens = [
            center.addObserver(forName: .librarySongsDeleted, object: manager, queue: nil) { note in
                seen.deletedSongs = note.userInfo?["ids"] as? [String] ?? []
            },
            center.addObserver(forName: .libraryPlaylistDeleted, object: manager, queue: nil) { note in
                seen.deletedPlaylist = (note.userInfo?["id"] as? String, note.userInfo?["title"] as? String)
            },
            center.addObserver(forName: .libraryFavoriteChanged, object: manager, queue: nil) { note in
                seen.favorite = (note.userInfo?["id"] as? String, note.userInfo?["isFavorited"] as? Bool)
            },
        ]
        defer { tokens.forEach(center.removeObserver) }

        center.post(name: .init("SongFavoriteToggled"), object: "n1")
        for _ in 0..<50 where seen.favorite.id == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(seen.favorite.id == "n1")
        #expect(seen.favorite.value == true)
        #expect(manager.fetchAllSongs().first?.isFavorited == true)

        manager.deletePlaylist(playlist)
        #expect(seen.deletedPlaylist.id == "pl")
        #expect(seen.deletedPlaylist.title == "Gone Soon")

        manager.deleteSongs(manager.fetchAllSongs())
        #expect(seen.deletedSongs == ["n1"])
    }

    @Test("Without an iCloud account sync reports unavailable and does nothing")
    func unavailableWithoutAccount() async throws {
        guard FileManager.default.ubiquityIdentityToken == nil else { return } // signed-in machine: not applicable
        let sync = LibraryCloudSync.shared
        sync.start()
        sync.refreshAvailability()
        for _ in 0..<50 where sync.status != .unavailable { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(sync.status == .unavailable)
        #expect(sync.status.text == "iCloud unavailable — sign in to iCloud")
        #expect(sync.cloudLibrarySummary == nil)
        if UserDefaults.standard.object(forKey: CloudSyncConstants.enabledDefaultsKey) == nil {
            #expect(!sync.isEnabled) // defaults to off without an account
        }
    }

    @Test("Mirror failures reach user-facing status even when the own-library write succeeds")
    func mirrorFailureStatus() {
        let sync = LibraryCloudSync.shared
        sync.publishStatus(MirrorPlan(), errors: [], mirrorResult: .init(errors: ["Upload failed: storage full"]))
        #expect(sync.status == .failed("Upload failed: storage full"))
        #expect(sync.status.text.contains("storage full"))
        sync.refreshAvailability()
    }

    @Test("Status lines read naturally")
    func statusText() {
        #expect(CloudSyncStatus.upToDate.text == "Up to date")
        #expect(CloudSyncStatus.off.text == "Off")
        #expect(CloudSyncStatus.syncing(uploading: 3, downloading: 0).text == "Uploading 3 songs")
        #expect(CloudSyncStatus.syncing(uploading: 1, downloading: 2).text == "Uploading 1 song · Downloading 2")
        #expect(CloudSyncStatus.syncing(uploading: 0, downloading: 4).text == "Downloading 4")
    }

    @Test("Account identity compares by value, and unreadable data keeps state")
    func accountComparison() throws {
        let a = try NSKeyedArchiver.archivedData(withRootObject: NSString(string: "account-a"), requiringSecureCoding: false)
        let a2 = try NSKeyedArchiver.archivedData(withRootObject: NSString(string: "account-a"), requiringSecureCoding: false)
        let b = try NSKeyedArchiver.archivedData(withRootObject: NSString(string: "account-b"), requiringSecureCoding: false)
        #expect(LibraryCloudSync.isSameAccount(a, as: a2))
        #expect(!LibraryCloudSync.isSameAccount(a, as: b))
        #expect(LibraryCloudSync.isSameAccount(Data("garbage".utf8), as: b))
        #expect(LibraryCloudSync.isSameAccount(a, as: nil))
    }
}
