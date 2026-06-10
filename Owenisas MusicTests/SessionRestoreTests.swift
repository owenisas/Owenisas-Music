import Foundation
import Testing
@testable import Owenisas_Music

// MARK: - Session Restore Tests
// Verifies the "continue where you left off" feature: the player rebuilds
// its queue, current song, and mode flags from a persisted session snapshot
// without auto-playing, and degrades gracefully when songs went missing.

@Suite(.serialized)
struct SessionRestoreTests {

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

    private func makeSession(
        queueIDs: [String],
        currentID: String,
        position: TimeInterval = 0,
        shuffled: Bool = false,
        repeatMode: RepeatMode = .off
    ) -> PlaybackSession {
        PlaybackSession(
            queueIDs: queueIDs,
            originalQueueIDs: queueIDs,
            currentSongID: currentID,
            position: position,
            isShuffled: shuffled,
            repeatModeRaw: repeatMode.rawValue
        )
    }

    // MARK: - Codable round trip
    // (UserDefaults save/load is not asserted here: other suites' players
    //  write the same shared key concurrently, which makes it racy.)

    @Test("PlaybackSession encodes and decodes losslessly")
    func sessionCodableRoundTrip() throws {
        let session = makeSession(
            queueIDs: ["a", "b", "c"],
            currentID: "b",
            position: 42.5,
            shuffled: true,
            repeatMode: .all
        )

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(PlaybackSession.self, from: data)
        #expect(decoded == session)
    }

    // MARK: - Restore behavior

    @Test("Restore rebuilds queue, current song, and mode flags — paused")
    func restoreRebuildsState() {
        let songs = (1...5).map { makeSong(id: "s\($0)") }
        let session = makeSession(
            queueIDs: songs.map(\.id),
            currentID: "s3",
            position: 42,
            shuffled: true,
            repeatMode: .all
        )

        let player = MusicPlayerManager()
        player.restoreSession(session, songs: songs)

        #expect(player.queue.count == 5)
        #expect(player.currentSong?.id == "s3")
        #expect(player.currentIndex == 2)
        #expect(player.isShuffled)
        #expect(player.repeatMode == .all)
        #expect(!player.isPlaying)
    }

    @Test("Songs deleted since last launch are dropped from the restored queue")
    func restoreDropsMissingSongs() {
        let songs = [makeSong(id: "s1"), makeSong(id: "s3")] // s2 gone
        let session = makeSession(queueIDs: ["s1", "s2", "s3"], currentID: "s3")

        let player = MusicPlayerManager()
        player.restoreSession(session, songs: songs)

        #expect(player.queue.map(\.id) == ["s1", "s3"])
        #expect(player.currentSong?.id == "s3")
        #expect(player.currentIndex == 1)
    }

    @Test("Missing current song falls back to first restored song at position 0")
    func restoreFallsBackWhenCurrentMissing() {
        let songs = [makeSong(id: "s1"), makeSong(id: "s2")]
        let session = makeSession(queueIDs: ["s1", "s2", "s3"], currentID: "s3", position: 90)

        let player = MusicPlayerManager()
        player.restoreSession(session, songs: songs)

        #expect(player.currentSong?.id == "s1")
        #expect(player.currentIndex == 0)
        #expect(player.currentTime == 0)
    }

    @Test("No stored session → player stays empty")
    func noSessionNoRestore() {
        let player = MusicPlayerManager()
        player.restoreSession(nil, songs: [makeSong(id: "s1")])

        #expect(player.currentSong == nil)
        #expect(player.queue.isEmpty)
    }

    @Test("Restore runs at most once per launch")
    func restoreRunsOnce() {
        let songs = [makeSong(id: "s1"), makeSong(id: "s2")]
        let player = MusicPlayerManager()

        player.restoreSession(makeSession(queueIDs: ["s1"], currentID: "s1"), songs: songs)
        #expect(player.queue.map(\.id) == ["s1"])

        // A second restore (e.g. onAppear firing again) must not clobber state.
        player.restoreSession(makeSession(queueIDs: ["s2"], currentID: "s2"), songs: songs)
        #expect(player.queue.map(\.id) == ["s1"])
        #expect(player.currentSong?.id == "s1")
    }

    @Test("Session with no surviving songs leaves player empty")
    func restoreAllSongsMissing() {
        let player = MusicPlayerManager()
        player.restoreSession(makeSession(queueIDs: ["gone1", "gone2"], currentID: "gone1"), songs: [])

        #expect(player.currentSong == nil)
        #expect(player.queue.isEmpty)
    }
}
