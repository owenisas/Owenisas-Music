import Foundation
import Testing
@testable import Owenisas_Music

// MARK: - Session Restore Tests
// Verifies the "continue where you left off" feature: the player rebuilds
// its queue, current song, and mode flags from a persisted session snapshot
// without auto-playing, and degrades gracefully when songs went missing.

@Suite(.serialized)
struct SessionRestoreTests {

    @Test("False play result is visible and never reported as playing; retry clears the error")
    func falsePlayResult() throws {
        let (song, url) = try makeWAV(seconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        var canStart = false
        let player = MusicPlayerManager(startPlayback: { _ in canStart })
        defer { player.stop() }
        player.play(song: song, in: [song])
        #expect(!player.isPlaying)
        #expect(player.playbackError?.contains("retry") == true)
        player.resume()
        #expect(!player.isPlaying)
        #expect(player.playbackError != nil)
        canStart = true
        player.resume()
        #expect(player.isPlaying)
        #expect(player.playbackError == nil)
    }

    @Test("Cloud refresh updates metadata without seeking current audio and replaces inactive cached resume positions")
    func cloudRefreshResumeCache() throws {
        let (long, url) = try makeWAV(seconds: 720)
        defer { try? FileManager.default.removeItem(at: url) }
        let other = Song(id: "other", title: "Other", artist: "Artist", albumTitle: "Album", audioFileURL: url, isFavorited: false)
        let player = MusicPlayerManager(startPlayback: { _ in true })
        defer { player.stop() }
        player.play(song: long, in: [long, other, long])
        player.seek(to: 100)
        player.pause()
        var updated = long
        updated.title = "Cloud title"
        updated.isFavorited = true
        updated.savedPosition = 300
        player.refreshLibrarySongs([updated])
        #expect(player.currentSong?.title == "Cloud title")
        #expect(player.currentTime == 100)
        player.playFromQueue(at: 1) // saves local 100 for the long track
        player.refreshLibrarySongs([updated]) // cloud now owns inactive resume
        player.playFromQueue(at: 2)
        #expect(player.currentTime == 300)
        #expect(player.currentSong?.isFavorited == true)
        player.pause()
        player.toggleShuffle()
        player.toggleShuffle()
        #expect(player.queue.filter { $0.id == long.id }.allSatisfy { $0.title == "Cloud title" })
    }

    private func makeWAV(seconds: Int) throws -> (Song, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        let count = seconds * 8_000 * 2
        var data = Data("RIFF".utf8)
        func append32(_ value: Int) { var n = UInt32(value).littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        func append16(_ value: Int) { var n = UInt16(value).littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        append32(36 + count)
        data.append(Data("WAVEfmt ".utf8))
        append32(16); append16(1); append16(1); append32(8_000); append32(16_000); append16(2); append16(16)
        data.append(Data("data".utf8)); append32(count)
        data.append(Data(repeating: 0, count: count))
        try data.write(to: url)
        return (Song(id: url.lastPathComponent, title: "Audio", artist: "Artist", albumTitle: "Album", audioFileURL: url, isFavorited: false), url)
    }

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
