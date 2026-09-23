import Foundation
import Testing
@testable import Owenisas_Music

// MARK: - iCloud library merge (pure)
// Likes (last writer wins), play counts (sum of per-device counts),
// last played (max), resume position (last writer wins), playlists
// (per-id last writer wins with tombstones, duplicate folding), and song
// tombstones. Every scenario also checks the merge settles (idempotent).

@MainActor
struct CloudSyncMergeTests {
    private func devices(_ ids: String..., songs: [String]) -> [SimDevice] {
        ids.map { id in
            let device = SimDevice(id)
            for song in songs { device.store.addSong(song) }
            return device
        }
    }

    private func assertSettled(_ devices: [SimDevice], at now: Date, sourceLocation: SourceLocation = #_sourceLocation) {
        for device in devices {
            let plan = device.sync(with: devices.filter { $0 !== device }, at: now)
            #expect(plan.isEmpty, "\(device.id) still had changes: \(plan)", sourceLocation: sourceLocation)
        }
    }

    // MARK: Likes

    @Test("A like on one device reaches the other; an unlike later wins back")
    func likeRoundTrip() {
        let all = devices("A", "B", songs: ["s1"])
        let (a, b) = (all[0], all[1])
        syncAll(all, at: CloudFixtures.at(0))

        a.like("s1", true, at: CloudFixtures.at(10))
        syncAll(all, at: CloudFixtures.at(11))
        #expect(b.store.songs["s1"]?.isFavorited == true)

        b.like("s1", false, at: CloudFixtures.at(20))
        syncAll(all, at: CloudFixtures.at(21))
        #expect(a.store.songs["s1"]?.isFavorited == false)
        #expect(b.store.songs["s1"]?.isFavorited == false)
        assertSettled(all, at: CloudFixtures.at(30))
    }

    @Test("Conflicting likes: the later edit wins on every device")
    func likeConflictLatestWins() {
        let all = devices("A", "B", songs: ["s1"])
        let (a, b) = (all[0], all[1])
        syncAll(all, at: CloudFixtures.at(0))

        // Offline edits: A likes at 10, B likes then unlikes at 15.
        a.like("s1", true, at: CloudFixtures.at(10))
        b.like("s1", true, at: CloudFixtures.at(12))
        b.like("s1", false, at: CloudFixtures.at(15))
        syncAll(all, at: CloudFixtures.at(20))

        #expect(a.store.songs["s1"]?.isFavorited == false)
        #expect(b.store.songs["s1"]?.isFavorited == false)
        assertSettled(all, at: CloudFixtures.at(30))
    }

    @Test("A like that predates sync beats a fresh device's default 'not liked'")
    func preexistingLikeWinsOverDefault() {
        let all = devices("A", "B", songs: ["s1"])
        all[0].store.songs["s1"]?.isFavorited = true
        syncAll(all, at: CloudFixtures.at(0))
        #expect(all[1].store.songs["s1"]?.isFavorited == true)
        #expect(all[0].store.songs["s1"]?.isFavorited == true)
    }

    @Test("A rebuilt store (likes reset without a toggle) never broadcasts unlikes")
    func rebuiltStoreKeepsLikes() {
        let all = devices("A", "B", songs: ["s1", "s2"])
        let (a, b) = (all[0], all[1])
        a.like("s1", true, at: CloudFixtures.at(5))
        syncAll(all, at: CloudFixtures.at(6))
        #expect(b.store.songs["s1"]?.isFavorited == true)

        // SwiftData fell back / was re-indexed: rows back with defaults.
        a.store.songs["s1"]?.isFavorited = false
        syncAll(all, at: CloudFixtures.at(50))

        #expect(a.store.songs["s1"]?.isFavorited == true)
        #expect(b.store.songs["s1"]?.isFavorited == true)
    }

    @Test("After a backup restore, restored likes count as new edits")
    func restoredLikesAreExplicit() {
        let all = devices("A", "B", songs: ["s1"])
        let (a, b) = (all[0], all[1])
        syncAll(all, at: CloudFixtures.at(0))
        a.store.songs["s1"]?.isFavorited = true
        a.changes.treatDiffsAsExplicit = true
        syncAll(all, at: CloudFixtures.at(10))
        #expect(b.store.songs["s1"]?.isFavorited == true)
    }

    // MARK: Plays, last played, position

    @Test("Play counts are the sum of each device's plays and stay stable")
    func playCountsSum() {
        let all = devices("A", "B", songs: ["s1"])
        let (a, b) = (all[0], all[1])
        a.play("s1", times: 3, at: CloudFixtures.at(1))
        b.play("s1", times: 2, at: CloudFixtures.at(2))
        syncAll(all, at: CloudFixtures.at(10))
        #expect(a.store.songs["s1"]?.playCount == 5)
        #expect(b.store.songs["s1"]?.playCount == 5)

        a.play("s1", at: CloudFixtures.at(20))
        syncAll(all, at: CloudFixtures.at(21), rounds: 3)
        #expect(a.store.songs["s1"]?.playCount == 6)
        #expect(b.store.songs["s1"]?.playCount == 6)
        #expect(a.file.songs["s1"]?.playCount == 4)
        #expect(b.file.songs["s1"]?.playCount == 2)
        assertSettled(all, at: CloudFixtures.at(30))
    }

    @Test("A store reset can't lose plays: the device's own count only grows")
    func playCountSurvivesReset() {
        let all = devices("A", "B", songs: ["s1"])
        let (a, b) = (all[0], all[1])
        a.play("s1", times: 3, at: CloudFixtures.at(1))
        b.play("s1", times: 2, at: CloudFixtures.at(2))
        syncAll(all, at: CloudFixtures.at(10))

        a.store.songs["s1"]?.playCount = 0
        syncAll(all, at: CloudFixtures.at(20))
        #expect(a.store.songs["s1"]?.playCount == 5)
        #expect(b.store.songs["s1"]?.playCount == 5)
    }

    @Test("Last played takes the latest; resume position takes the latest save")
    func lastPlayedAndPosition() {
        let all = devices("A", "B", songs: ["mix"])
        let (a, b) = (all[0], all[1])
        a.play("mix", at: CloudFixtures.at(100))
        b.play("mix", at: CloudFixtures.at(200))
        a.savePosition("mix", 1_200, at: CloudFixtures.at(100))
        b.savePosition("mix", 300, at: CloudFixtures.at(200))
        syncAll(all, at: CloudFixtures.at(300))

        #expect(a.store.songs["mix"]?.lastPlayed == CloudFixtures.at(200))
        #expect(a.store.songs["mix"]?.position == 300)
        #expect(b.store.songs["mix"]?.position == 300)

        a.savePosition("mix", 0, at: CloudFixtures.at(400)) // finished: start over
        syncAll(all, at: CloudFixtures.at(401))
        #expect(b.store.songs["mix"]?.position == 0)
        assertSettled(all, at: CloudFixtures.at(500))
    }

    // MARK: Playlists

    @Test("A new playlist appears elsewhere in order, filling in as songs arrive")
    func playlistArrivesAndFillsIn() {
        let a = SimDevice("A")
        let b = SimDevice("B")
        for id in ["s1", "s2", "s3"] { a.store.addSong(id) }
        b.store.addSong("s1")
        b.store.addSong("s3")
        a.store.addPlaylist("p1", "Road Trip", ["s3", "s1", "s2"])
        syncAll([a, b], at: CloudFixtures.at(10))

        #expect(b.store.playlists["p1"]?.title == "Road Trip")
        #expect(b.store.playlists["p1"]?.songIDs == ["s3", "s1"])
        // B not having s2 yet must not remove it for everyone.
        #expect(a.store.playlists["p1"]?.songIDs == ["s3", "s1", "s2"])

        b.store.addSong("s2", added: CloudFixtures.at(20)) // downloaded later
        syncAll([a, b], at: CloudFixtures.at(21))
        #expect(b.store.playlists["p1"]?.songIDs == ["s3", "s1", "s2"])
        assertSettled([a, b], at: CloudFixtures.at(30))
    }

    @Test("Reorder on one device and rename on another both land")
    func reorderAndRename() {
        let all = devices("A", "B", songs: ["s1", "s2", "s3"])
        let (a, b) = (all[0], all[1])
        a.store.addPlaylist("p1", "Focus", ["s1", "s2", "s3"])
        syncAll(all, at: CloudFixtures.at(1))

        a.store.playlists["p1"]?.songIDs = ["s3", "s1", "s2"]
        syncAll(all, at: CloudFixtures.at(10))
        #expect(b.store.playlists["p1"]?.songIDs == ["s3", "s1", "s2"])

        b.store.playlists["p1"]?.title = "Deep Focus"
        syncAll(all, at: CloudFixtures.at(20))
        #expect(a.store.playlists["p1"]?.title == "Deep Focus")
        #expect(a.store.playlists["p1"]?.songIDs == ["s3", "s1", "s2"])
        assertSettled(all, at: CloudFixtures.at(30))
    }

    @Test("Reordering on a device missing a member keeps that member's slot")
    func reorderKeepsAbsentMembers() {
        let a = SimDevice("A")
        let b = SimDevice("B")
        for id in ["s1", "s2", "s3", "s4"] { a.store.addSong(id) }
        for id in ["s1", "s3", "s4"] { b.store.addSong(id) }
        a.store.addPlaylist("p1", "Mix", ["s1", "s2", "s3", "s4"])
        syncAll([a, b], at: CloudFixtures.at(1))

        b.store.playlists["p1"]?.songIDs = ["s4", "s3", "s1"]
        syncAll([a, b], at: CloudFixtures.at(10))
        let order = a.store.playlists["p1"]?.songIDs ?? []
        #expect(Set(order) == ["s1", "s2", "s3", "s4"])
        #expect(order.filter { $0 != "s2" } == ["s4", "s3", "s1"])
    }

    @Test("A song that vanished without a user delete stays in playlists")
    func vanishedSongKeepsSlot() {
        let all = devices("A", "B", songs: ["s1", "s2"])
        let (a, b) = (all[0], all[1])
        a.store.addPlaylist("p1", "Mix", ["s1", "s2"])
        syncAll(all, at: CloudFixtures.at(1))

        b.store.removeSong("s2") // folder removed in Files, not a delete
        syncAll(all, at: CloudFixtures.at(10))
        #expect(a.store.playlists["p1"]?.songIDs == ["s1", "s2"])
        #expect(b.file.playlists["p1"]?.songOrder == ["s1", "s2"])
    }

    @Test("Removing a song from a playlist propagates")
    func explicitRemovalPropagates() {
        let all = devices("A", "B", songs: ["s1", "s2"])
        all[0].store.addPlaylist("p1", "Mix", ["s1", "s2"])
        syncAll(all, at: CloudFixtures.at(1))
        all[1].store.playlists["p1"]?.songIDs = ["s2"]
        syncAll(all, at: CloudFixtures.at(10))
        #expect(all[0].store.playlists["p1"]?.songIDs == ["s2"])
    }

    @Test("Deleting a playlist removes it everywhere, deferred while not allowed")
    func playlistDeleteTombstone() {
        let all = devices("A", "B", songs: ["s1"])
        let (a, b) = (all[0], all[1])
        a.store.addPlaylist("p1", "Old", ["s1"])
        syncAll(all, at: CloudFixtures.at(1))
        #expect(b.store.playlists["p1"] != nil)

        a.deletePlaylist("p1", at: CloudFixtures.at(10))
        a.sync(with: [b], at: CloudFixtures.at(11))
        let deferred = b.sync(with: [a], at: CloudFixtures.at(12), allowDestructive: false)
        #expect(deferred.playlistDeletes.isEmpty)
        #expect(b.store.playlists["p1"] != nil)

        // Still pending, not resurrected, and removed once allowed.
        a.sync(with: [b], at: CloudFixtures.at(13))
        #expect(a.store.playlists["p1"] == nil)
        let applied = b.sync(with: [a], at: CloudFixtures.at(14), allowDestructive: true)
        #expect(applied.playlistDeletes == ["p1"])
        #expect(b.store.playlists["p1"] == nil)
        assertSettled(all, at: CloudFixtures.at(20))
    }

    @Test("An edit made after another device's delete keeps the playlist")
    func editAfterDeleteWins() {
        let all = devices("A", "B", songs: ["s1", "s2"])
        let (a, b) = (all[0], all[1])
        a.store.addPlaylist("p1", "Keep", ["s1"])
        syncAll(all, at: CloudFixtures.at(1))

        a.deletePlaylist("p1", at: CloudFixtures.at(10))
        b.store.playlists["p1"]?.songIDs = ["s1", "s2"] // offline edit, later
        b.sync(with: [a], at: CloudFixtures.at(20))
        a.sync(with: [b], at: CloudFixtures.at(21))
        #expect(a.store.playlists["p1"]?.songIDs == ["s1", "s2"])
        #expect(b.store.playlists["p1"]?.songIDs == ["s1", "s2"])
    }

    @Test("A playlist missing locally without a user delete is restored, not deleted")
    func missingPlaylistRestored() {
        let all = devices("A", "B", songs: ["s1"])
        let (a, b) = (all[0], all[1])
        a.store.addPlaylist("p1", "Precious", ["s1"])
        syncAll(all, at: CloudFixtures.at(1))

        a.store.playlists = [:] // store lost, no deletePlaylist call
        syncAll(all, at: CloudFixtures.at(10))
        #expect(a.store.playlists["p1"]?.title == "Precious")
        #expect(b.store.playlists["p1"]?.title == "Precious")
    }

    @Test("Same-titled playlists made on two devices become one, without duplicates")
    func duplicatePlaylistsFold() {
        let all = devices("A", "B", songs: ["s1", "s2", "s3"])
        let (a, b) = (all[0], all[1])
        a.store.addPlaylist("pa", "Road Trip", ["s1", "s2"], created: CloudFixtures.at(1))
        b.store.addPlaylist("pb", "road trip ", ["s2", "s3"], created: CloudFixtures.at(2))
        syncAll(all, at: CloudFixtures.at(10), rounds: 3)

        for device in all {
            let trips = device.store.playlists.filter { LibraryMergeEngine.titleKey($0.value.title) == "road trip" }
            #expect(trips.count == 1, "\(device.id) has \(trips.count) Road Trip playlists")
            #expect(trips.keys.first == "pa") // the older one's id wins
            #expect(trips.values.first?.songIDs == ["s1", "s2", "s3"])
        }
        #expect(b.file.playlists["pb"]?.deleted == true)
        #expect(b.file.playlists["pb"]?.mergedInto == "pa")
        assertSettled(all, at: CloudFixtures.at(40))
    }

    @Test("Folding works when the other device learns it from the published tombstone")
    func duplicateFoldLearnedFromTombstone() {
        let all = devices("A", "B", songs: ["s1", "s2"])
        let (a, b) = (all[0], all[1])
        a.store.addPlaylist("pa", "Gym", ["s1"], created: CloudFixtures.at(1))
        b.store.addPlaylist("pb", "Gym", ["s2"], created: CloudFixtures.at(2))
        // B publishes first, then A folds, then B catches up from A's file.
        b.sync(with: [a], at: CloudFixtures.at(5))
        a.sync(with: [b], at: CloudFixtures.at(10))
        #expect(a.store.playlists.count == 1)
        b.sync(with: [a], at: CloudFixtures.at(11))
        #expect(b.store.playlists.keys.sorted() == ["pa"])
        #expect(b.store.playlists["pa"]?.songIDs == ["s1", "s2"])
        assertSettled(all, at: CloudFixtures.at(20))
    }

    @Test("Two same-named playlists on one device are left alone")
    func intentionalSameNamesKept() {
        let all = devices("A", "B", songs: ["s1"])
        all[0].store.addPlaylist("p1", "Mix", ["s1"])
        all[0].store.addPlaylist("p2", "Mix", [])
        syncAll(all, at: CloudFixtures.at(10), rounds: 3)
        #expect(all[0].store.playlists.count == 2)
        #expect(all[1].store.playlists.count == 2)
    }

    // MARK: Song tombstones

    @Test("A deleted song is removed on devices that had it from before the delete")
    func songTombstoneApplies() {
        let all = devices("A", "B", songs: ["s1", "s2"])
        let (a, b) = (all[0], all[1])
        syncAll(all, at: CloudFixtures.at(1))

        a.deleteSong("s1", at: CloudFixtures.at(100))
        a.sync(with: [b], at: CloudFixtures.at(101))
        let plan = b.sync(with: [a], at: CloudFixtures.at(102))
        #expect(plan.songDeletes == ["s1"])
        #expect(b.store.songs["s1"] == nil)
        #expect(b.store.songs["s2"] != nil)
    }

    @Test("A song re-added after the delete is kept, and revives it for others")
    func reAddedSongSurvivesTombstone() {
        let all = devices("A", "B", songs: ["s1"])
        let (a, b) = (all[0], all[1])
        syncAll(all, at: CloudFixtures.at(1))
        a.deleteSong("s1", at: CloudFixtures.at(100))
        b.store.songs["s1"]?.dateAdded = CloudFixtures.at(200) // B downloaded it again

        let plan = b.sync(with: [a], at: CloudFixtures.at(201))
        #expect(plan.songDeletes.isEmpty)
        #expect(LibraryMergeEngine.effectiveSongTombstones(own: a.file, others: [b.file])["s1"] == nil)

        // A re-adding it itself also clears A's own tombstone.
        a.store.addSong("s1", added: CloudFixtures.at(300))
        a.sync(with: [b], at: CloudFixtures.at(301))
        #expect(a.file.deletedSongs["s1"] == nil)
    }

    @Test("Tombstones wait while destructive changes aren't allowed or the song is playing")
    func tombstoneDeferredAndProtected() {
        let all = devices("A", "B", songs: ["s1", "s2"])
        let (a, b) = (all[0], all[1])
        syncAll(all, at: CloudFixtures.at(1))
        a.deleteSong("s1", at: CloudFixtures.at(100))
        a.deleteSong("s2", at: CloudFixtures.at(100))
        a.sync(with: [b], at: CloudFixtures.at(101))

        #expect(b.sync(with: [a], at: CloudFixtures.at(102), allowDestructive: false).songDeletes.isEmpty)
        b.store.protected = ["s2"]
        #expect(b.sync(with: [a], at: CloudFixtures.at(103)).songDeletes == ["s1"])
        #expect(b.store.songs["s2"] != nil)
    }

    // MARK: Format

    @Test("Device files round-trip exactly and decode leniently")
    func deviceFileCoding() throws {
        var file = CloudLibraryFile(deviceID: "A", deviceName: "iPhone", updatedAt: CloudFixtures.at(1.25))
        file.songs["s1"] = CloudSongRecord(favorited: true, favoritedAt: CloudFixtures.at(0.001), playCount: 3,
                                           lastPlayed: CloudFixtures.at(2), position: 12.5,
                                           positionAt: CloudFixtures.at(3), addedAt: CloudFixtures.t0)
        file.playlists["p"] = CloudPlaylistRecord(title: "Mix", songOrder: ["s1"], coverImagePath: "Songs/s1/cover.jpg",
                                                  dateCreated: CloudFixtures.t0, modifiedAt: CloudFixtures.at(4))
        file.deletedSongs["gone"] = CloudFixtures.at(5)
        let data = try CloudSyncCoding.encoder().encode(file)
        #expect(try CloudSyncCoding.decoder().decode(CloudLibraryFile.self, from: data) == file)

        let sparse = Data(#"{"deviceID":"B","songs":{"x":{"favorited":true}},"playlists":{"p":{"title":"T"}},"future":1}"#.utf8)
        let decoded = try CloudSyncCoding.decoder().decode(CloudLibraryFile.self, from: sparse)
        #expect(decoded.songs["x"]?.favorited == true)
        #expect(decoded.songs["x"]?.playCount == 0)
        #expect(decoded.playlists["p"]?.songOrder == [])
        #expect(decoded.updatedAt == CloudSyncConstants.unknownDate)
    }

    @Test("Slot replacement keeps members this device doesn't have in place")
    func slotReplacement() {
        let full = ["a", "x", "b", "c", "y"]
        #expect(LibraryMergeEngine.replacingSlots(in: full, slots: ["a", "b", "c"], with: ["c", "a"])
                == ["c", "x", "a", "y"])
        #expect(LibraryMergeEngine.replacingSlots(in: full, slots: ["a", "b", "c"], with: ["a", "b", "c", "d"])
                == ["a", "x", "b", "c", "y", "d"])
    }
}
