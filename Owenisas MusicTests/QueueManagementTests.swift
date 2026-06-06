import Foundation
import Testing
@testable import Owenisas_Music

// MARK: - Queue Recovery Tests
// Verifies that MusicPlayerManager correctly handles queue state after
// song removal, especially the fix for Bug #1: "queue stranded after
// deleting the currently-playing song."

struct QueueManagementTests {

    // MARK: - Helpers

    private func makeSong(id: String) -> Song {
        Song(
            id: id,
            title: "Song \(id)",
            artist: "Artist",
            albumTitle: "Album",
            audioFileURL: URL(fileURLWithPath: "/tmp/fake_\(id).mp3"),
            coverImageURL: nil,
            subtitleFileURL: nil,
            isFavorited: false
        )
    }

    private func makePlayer(songCount: Int, currentIndex: Int) -> MusicPlayerManager {
        let player = MusicPlayerManager()
        let songs = (1...songCount).map { makeSong(id: "s\($0)") }
        player.queue = songs
        player.currentIndex = currentIndex
        player.currentSong = songs[currentIndex]
        return player
    }

    // MARK: - stopAndRemoveFromQueue

    @Test("Remove current song (middle) → advances to next track")
    func removeCurrentMiddle() {
        let player = makePlayer(songCount: 5, currentIndex: 2)

        player.stopAndRemoveFromQueue(songId: "s3")

        #expect(player.queue.count == 4)
        #expect(!player.queue.contains { $0.id == "s3" })
        #expect(player.currentIndex == 2)       // same index → now points to old s4
        #expect(player.currentSong?.id == "s4") // auto-advanced
    }

    @Test("Remove current song (last in queue) → clamps to new last")
    func removeCurrentLast() {
        let player = makePlayer(songCount: 3, currentIndex: 2)

        player.stopAndRemoveFromQueue(songId: "s3")

        #expect(player.queue.count == 2)
        #expect(player.currentIndex == 1)       // clamped to queue.count - 1
        #expect(player.currentSong?.id == "s2") // plays previous (now last)
    }

    @Test("Remove current song (first in queue) → plays new first")
    func removeCurrentFirst() {
        let player = makePlayer(songCount: 4, currentIndex: 0)

        player.stopAndRemoveFromQueue(songId: "s1")

        #expect(player.queue.count == 3)
        #expect(player.currentIndex == 0)
        #expect(player.currentSong?.id == "s2")
    }

    @Test("Remove only song → queue empty, currentSong nil")
    func removeOnlySong() {
        let player = makePlayer(songCount: 1, currentIndex: 0)

        player.stopAndRemoveFromQueue(songId: "s1")

        #expect(player.queue.isEmpty)
        #expect(player.currentIndex == 0)
        #expect(player.currentSong == nil) // stop() clears this
    }

    @Test("Remove non-current song after current → index unchanged")
    func removeAfterCurrent() {
        let player = makePlayer(songCount: 5, currentIndex: 1)

        player.stopAndRemoveFromQueue(songId: "s4")

        #expect(player.queue.count == 4)
        #expect(player.currentSong?.id == "s2")
        #expect(player.currentIndex == 1)
    }

    @Test("Remove non-current song before current → index shifts left")
    func removeBeforeCurrent() {
        let player = makePlayer(songCount: 5, currentIndex: 3)

        player.stopAndRemoveFromQueue(songId: "s2")

        #expect(player.queue.count == 4)
        #expect(player.currentSong?.id == "s4")
        #expect(player.currentIndex == 2) // shifted left by 1
    }

    @Test("Remove song not in queue → no-op")
    func removeNonexistent() {
        let player = makePlayer(songCount: 3, currentIndex: 1)

        player.stopAndRemoveFromQueue(songId: "ghost")

        #expect(player.queue.count == 3)
        #expect(player.currentSong?.id == "s2")
        #expect(player.currentIndex == 1)
    }

    @Test("Remove two of three while second is current → plays remaining")
    func removeMultiple() {
        let player = makePlayer(songCount: 3, currentIndex: 1)

        player.stopAndRemoveFromQueue(songId: "s2") // removes current → plays s3
        #expect(player.currentSong?.id == "s3")

        player.stopAndRemoveFromQueue(songId: "s1") // remove non-current
        #expect(player.queue.count == 1)
        #expect(player.currentSong?.id == "s3")
        #expect(player.currentIndex == 0)
    }

    // MARK: - removeFromQueue (IndexSet variant)

    @Test("removeFromQueue: remove index before current adjusts index")
    func removeByOffsetBeforeCurrent() {
        let player = makePlayer(songCount: 5, currentIndex: 3)

        player.removeFromQueue(at: IndexSet(integer: 1))

        #expect(player.queue.count == 4)
        #expect(player.currentSong?.id == "s4")
        #expect(player.currentIndex == 2) // shifted left
    }

    @Test("removeFromQueue: remove index after current keeps index")
    func removeByOffsetAfterCurrent() {
        let player = makePlayer(songCount: 5, currentIndex: 1)

        player.removeFromQueue(at: IndexSet(integer: 3))

        #expect(player.queue.count == 4)
        #expect(player.currentSong?.id == "s2")
        #expect(player.currentIndex == 1)
    }

    // MARK: - moveInQueue

    @Test("Moving current song updates currentIndex to follow it")
    func movingCurrentUpdatesIndex() {
        let player = makePlayer(songCount: 5, currentIndex: 1)
        // current = s2 at index 1

        // Move s2 from index 1 to after index 3 (destination=4)
        player.moveInQueue(from: IndexSet(integer: 1), to: 4)
        // queue should be: s1, s3, s4, s2, s5

        #expect(player.currentSong?.id == "s2")
        #expect(player.currentIndex == 3)
    }

    @Test("Reordering queue preserves order when shuffle is toggled on and back off")
    func moveInQueuePersistsAfterShuffleToggle() {
        let songs = (1...4).map { makeSong(id: "s\($0)") }
        let player = MusicPlayerManager()
        player.play(song: songs[0], in: songs)

        // Move s2 right after s3: [s1, s3, s2, s4].
        // SwiftUI's move(fromOffsets:toOffset:) interprets the destination in the
        // pre-removal index space, so moving index 1 *past* index 2 requires
        // toOffset 3 (toOffset 2 would be a no-op). Cf. movingCurrentUpdatesIndex.
        player.moveInQueue(from: IndexSet(integer: 1), to: 3)

        // A shuffle/off shuffle cycle should keep this manual order.
        player.toggleShuffle()
        player.toggleShuffle()

        #expect(player.currentIndex == 0)
        #expect(player.queue.map(\.id) == ["s1", "s3", "s2", "s4"])
    }

    @Test("Removing a queue item keeps it out after shuffle toggle")
    func removeFromQueuePersistsAfterShuffleToggle() {
        let songs = (1...3).map { makeSong(id: "s\($0)") }
        let player = MusicPlayerManager()
        player.play(song: songs[0], in: songs)

        // Remove s2 from the queue.
        player.removeFromQueue(at: IndexSet(integer: 1))

        // A shuffle/off shuffle cycle should not reintroduce the removed song.
        player.toggleShuffle()
        player.toggleShuffle()

        #expect(player.currentSong?.id == "s1")
        #expect(player.queue.map(\.id) == ["s1", "s3"])
    }

    // MARK: - playNext / addToQueue

    @Test("playNext inserts song right after current")
    func playNextInsertsAfterCurrent() {
        let player = makePlayer(songCount: 3, currentIndex: 0)
        let newSong = makeSong(id: "new")

        player.playNext(newSong)

        #expect(player.queue.count == 4)
        #expect(player.queue[1].id == "new")
    }

    @Test("addToQueue appends to end of queue")
    func addToQueueAppends() {
        let player = makePlayer(songCount: 3, currentIndex: 0)
        let newSong = makeSong(id: "new")

        player.addToQueue(newSong)

        #expect(player.queue.count == 4)
        #expect(player.queue.last?.id == "new")
    }

    @Test("stop clears current playback state and resets cursor")
    func stopResetsCurrentState() {
        let player = makePlayer(songCount: 4, currentIndex: 2)

        player.stop()

        #expect(player.currentSong == nil)
        #expect(player.currentIndex == 0)
        #expect(player.isPlaying == false)
        #expect(player.duration == 0)
    }

    @Test("playNext on empty queue starts playing the song")
    func playNextEmptyQueue() {
        let player = MusicPlayerManager()
        let song = makeSong(id: "first")

        player.playNext(song)

        #expect(player.queue.count == 1)
        #expect(player.currentSong?.id == "first")
    }
}
