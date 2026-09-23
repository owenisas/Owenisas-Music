import Foundation
import Testing
@testable import Owenisas_Music

// Bookkeeping for music downloaded to the watch.
struct WatchOfflineIndexTests {

    private func item(_ id: String, _ bytes: Int64 = 100) -> WatchSongItem {
        WatchSongItem(id: id, title: id, artist: "A", duration: 60, isFavorited: false, bytes: bytes, hasArtwork: false)
    }

    private func track(_ id: String, _ bytes: Int64 = 100) -> WatchOfflineTrack {
        WatchOfflineTrack(
            id: id, title: id, artist: "A", duration: 60, bytes: bytes,
            fileName: WatchFileNaming.fileName(songID: id, fileExtension: "m4a"), addedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func download(_ index: inout WatchOfflineIndex, _ list: WatchListRef, _ ids: [String], present: [String] = []) {
        index.upsertCollection(
            list: list, title: list.rawValue, manifestOrder: ids,
            requested: ids.filter { !present.contains($0) }.map { item($0) }, present: present,
            now: Date(timeIntervalSince1970: 1_000)
        )
    }

    @Test("A new download starts pending, then completes as files arrive")
    func progressLifecycle() {
        var index = WatchOfflineIndex()
        download(&index, .liked, ["a", "b", "c"])
        #expect(index.state(for: .liked) == .downloading(WatchOfflineProgress(received: 0, total: 3, failed: 0, receivedBytes: 0, totalBytes: 300)))
        #expect(index.pendingIDs == ["a", "b", "c"])
        #expect(index.committedBytes == 300)
        #expect(index.usedBytes == 0)

        index.recordArrival(track("b", 120))
        let partial = index.progress(for: .liked)
        #expect(partial?.received == 1)
        #expect(partial?.receivedBytes == 120)
        #expect(partial?.totalBytes == 320)

        index.recordArrival(track("a"))
        index.recordArrival(track("c"))
        guard case .downloaded(let done) = index.state(for: .liked) else {
            Issue.record("expected downloaded")
            return
        }
        #expect(done.fraction == 1)
        #expect(index.tracks(in: .liked).map(\.id) == ["a", "b", "c"])
        #expect(index.pendingIDs.isEmpty)
    }

    @Test("Failed songs end the download as incomplete; a retry clears them")
    func failures() {
        var index = WatchOfflineIndex()
        download(&index, .liked, ["a", "b"])
        index.recordArrival(track("a"))
        index.markFailed("b")
        guard case .incomplete(let progress) = index.state(for: .liked) else {
            Issue.record("expected incomplete")
            return
        }
        #expect(progress.failed == 1)
        #expect(index.pendingBytes == 0)

        // Retry just "b".
        index.upsertCollection(list: .liked, title: "Liked", manifestOrder: ["a", "b"], requested: [item("b")], present: ["a"])
        #expect(index.pendingIDs == ["b"])
        index.recordArrival(track("b"))
        if case .downloaded = index.state(for: .liked) {} else { Issue.record("expected downloaded") }
    }

    @Test("A late arrival clears an earlier failure for that song")
    func arrivalClearsFailure() {
        var index = WatchOfflineIndex()
        download(&index, .liked, ["a"])
        index.markFailed("a")
        index.recordArrival(track("a"))
        #expect(index.collection(.liked)?.failedIDs.isEmpty == true)
    }

    @Test("Removing a list keeps songs another list still uses")
    func sharedSongsSurviveRemoval() {
        var index = WatchOfflineIndex()
        download(&index, .liked, ["a", "b"])
        download(&index, .playlist("p"), ["b", "c"], present: [])
        for id in ["a", "b", "c"] { index.recordArrival(track(id)) }
        #expect(index.usedBytes == 300)

        let result = index.removeCollection(.liked)
        #expect(result.orphans.map(\.id) == ["a"])
        #expect(result.cancelled.isEmpty)
        #expect(index.tracks["b"] != nil)
        #expect(index.usedBytes == 200)
        #expect(index.collection(.liked) == nil)
    }

    @Test("Removing a list mid-download cancels its pending songs")
    func removeWhileDownloading() {
        var index = WatchOfflineIndex()
        download(&index, .playlist("p"), ["a", "b", "c"])
        download(&index, .liked, ["c"])
        index.recordArrival(track("a"))

        let result = index.removeCollection(.playlist("p"))
        #expect(result.orphans.map(\.id) == ["a"])
        // "c" is still wanted by Liked Songs.
        #expect(result.cancelled == ["b"])
        #expect(index.pendingIDs == ["c"])
    }

    @Test("A file arriving after its list was removed is rejected")
    func orphanArrival() {
        var index = WatchOfflineIndex()
        download(&index, .liked, ["a"])
        index.removeCollection(.liked)
        #expect(index.recordArrival(track("a")) == false)
        #expect(index.tracks.isEmpty)
    }

    @Test("Updating a list adds new songs in the phone's order and keeps old ones")
    func upsertMergesInOrder() {
        var index = WatchOfflineIndex()
        download(&index, .playlist("p"), ["b", "d"])
        index.recordArrival(track("b"))
        index.recordArrival(track("d"))
        // Phone playlist is now a, b, c, d (a and c new).
        index.upsertCollection(list: .playlist("p"), title: "Renamed", manifestOrder: ["a", "b", "c", "d"], requested: [item("a"), item("c")], present: ["b", "d"])
        #expect(index.collection(.playlist("p"))?.songIDs == ["a", "b", "c", "d"])
        #expect(index.collection(.playlist("p"))?.title == "Renamed")
        #expect(index.collections.count == 1)
        #expect(index.pendingIDs == ["a", "c"])
    }

    @Test("Pending bytes count a song wanted by two lists once")
    func pendingCountedOnce() {
        var index = WatchOfflineIndex()
        download(&index, .liked, ["a"])
        download(&index, .playlist("p"), ["a"])
        #expect(index.pendingBytes == 100)
    }

    @Test("Unknown lists report not downloaded")
    func unknownList() {
        let index = WatchOfflineIndex()
        #expect(index.state(for: .playlist("nope")) == .notDownloaded)
        #expect(index.tracks(in: .liked).isEmpty)
        #expect(index.progress(for: .liked) == nil)
    }

    @Test("The index survives JSON persistence")
    func persistence() throws {
        var index = WatchOfflineIndex()
        download(&index, .liked, ["a", "b"])
        index.recordArrival(track("a"))
        index.markFailed("b")
        let data = try WatchCoding.encoder().encode(index)
        #expect(try WatchCoding.decoder().decode(WatchOfflineIndex.self, from: data) == index)
    }
}
