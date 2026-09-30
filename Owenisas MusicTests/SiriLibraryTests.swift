import XCTest
import AppIntents
#if canImport(MediaIntents)
import MediaIntents
#endif
import SwiftData
import AVFoundation
@testable import Owenisas_Music

final class SiriLibraryTests: XCTestCase {
    private func expectIDs(_ actual: [String], _ expected: [String], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    private func expectEmpty<T>(_ actual: [T], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(actual.isEmpty, file: file, line: line)
    }

    @MainActor
    private func fixture() throws -> (ModelContainer, MusicPlayerManager, SiriLibraryService) {
        let schema = Schema([SongData.self, AlbumData.self, PlaylistData.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let player = MusicPlayerManager()
        let service = SiriLibraryService(context: { container.mainContext }, player: player)
        return (container, player, service)
    }

    @MainActor
    private func song(_ id: String, title: String = "Echo", artist: String = "Artist", in context: ModelContext) -> SongData {
        let song = SongData(id: id, title: title, artist: artist, audioFilePath: "SiriTests/\(UUID().uuidString).wav")
        context.insert(song)
        return song
    }

    @MainActor
    private func audio(for song: SongData) throws {
        try FileManager.default.createDirectory(at: song.audioFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 441000)!
        buffer.frameLength = buffer.frameCapacity
        memset(buffer.floatChannelData![0], 0, Int(buffer.frameLength) * MemoryLayout<Float>.size)
        let file = try AVAudioFile(forWriting: song.audioFileURL, settings: format.settings)
        try file.write(from: buffer)
        let url = song.audioFileURL
        addTeardownBlock { @Sendable in try? FileManager.default.removeItem(at: url) }
    }

    @MainActor
    func testDuplicateSongTitlesRemainDistinctAndArtistSearchDisambiguates() async throws {
        let (store, _, service) = try fixture()
        _ = song("b", artist: "Björk", in: store.mainContext)
        _ = song("a", artist: "Other", in: store.mainContext)
        let query = SongEntityQuery(service: service)
        expectIDs(try await query.entities(matching: "echo").map(\.id), ["b", "a"])
        expectIDs(try await query.entities(matching: "echo bjork").map(\.id), ["b"])
        expectIDs(try await query.entities(for: ["a", "gone", "b"]).map(\.id), ["a", "b"])
    }

    @MainActor
    func testEntitiesUseCanonicalIDsAndRefreshRenamedMetadata() async throws {
        let (store, _, service) = try fixture()
        let model = song("stable-cloud-id", in: store.mainContext)
        let query = SongEntityQuery(service: service)
        model.title = "Renamed"
        let entities = try await query.entities(for: [model.id])
        let entity = try XCTUnwrap(entities.first)
        XCTAssertEqual(entity.id, model.id)
        XCTAssertEqual(entity.title, "Renamed")
        XCTAssertEqual(entity.artist, "Artist")
    }

    @MainActor
    func testPlaylistQueryPreservesDuplicateNamesAndCanonicalIDs() async throws {
        let (store, _, service) = try fixture()
        for id in ["b", "a"] { store.mainContext.insert(PlaylistData(id: id, title: "Running")) }
        let query = PlaylistEntityQuery(service: service)
        expectIDs(try await query.entities(matching: "running").map(\.id), ["a", "b"])
        expectIDs(try await query.entities(for: ["b", "a", "gone"]).map(\.id), ["b", "a"])
    }

    @MainActor
    func testEmptyLibrarySuggestionsAreEmpty() async throws {
        let (_, _, service) = try fixture()
        expectEmpty(try await SongEntityQuery(service: service).suggestedEntities())
        expectEmpty(try await PlaylistEntityQuery(service: service).suggestedEntities())
    }

    @MainActor
    func testColdLaunchWaitsForPersistentContextInsteadOfCreatingFallbackStore() async throws {
        let (store, player, _) = try fixture()
        _ = song("ready", in: store.mainContext)
        var attempts = 0
        let service = SiriLibraryService(context: { attempts += 1; return attempts < 3 ? nil : store.mainContext }, player: player, readinessDelay: .zero)
        expectIDs(try await service.songs().map(\.id), ["ready"])
        XCTAssertEqual(attempts, 3)
    }

    @MainActor
    func testUnavailableStoreReportsFailureRatherThanEmptyLibrary() async throws {
        let service = SiriLibraryService(context: { nil }, player: MusicPlayerManager(), readinessDelay: .zero)
        do { _ = try await service.songs(); XCTFail("Expected unavailable library") }
        catch { XCTAssertEqual(error as? SiriLibraryError, .libraryUnavailable) }
    }

    @MainActor
    func testNamedSongPlaybackUsesIDAndRealAudio() async throws {
        let (store, player, service) = try fixture()
        let first = song("one", in: store.mainContext)
        let second = song("two", in: store.mainContext)
        try audio(for: first); try audio(for: second)
        defer { player.stop() }
        try await service.playSong(id: "two")
        XCTAssertEqual(player.currentSong?.id, "two")
        XCTAssertEqual(player.queue.map(\.id), ["two"])
        XCTAssertTrue(player.isPlaying)
    }

    @MainActor
    func testPlaylistPlaybackUsesSavedOrderAndSkipsMissingAudio() async throws {
        let (store, player, service) = try fixture()
        let a = song("a", in: store.mainContext), b = song("b", in: store.mainContext), missing = song("missing", in: store.mainContext)
        try audio(for: a); try audio(for: b)
        let playlist = PlaylistData(id: "run", title: "Running")
        store.mainContext.insert(playlist)
        playlist.songs = [a, missing, b]; playlist.songOrder = ["b", "missing", "a"]
        defer { player.stop() }
        let skipped = try await service.playPlaylist(id: "run")
        XCTAssertEqual(skipped, 1)
        XCTAssertEqual(player.queue.map(\.id), ["b", "a"])
        XCTAssertEqual(player.currentSong?.id, "b")
        XCTAssertTrue(player.isPlaying)
    }

    @MainActor
    func testMissingSongAndMissingFileDoNotChangeExistingQueue() async throws {
        let (store, player, service) = try fixture()
        _ = song("missing", in: store.mainContext)
        let existing = song("existing", in: store.mainContext)
        player.queue = [Song.from(existing)]
        for (id, expected) in [("deleted", SiriLibraryError.songNotFound), ("missing", .audioUnavailable)] {
            do { try await service.playSong(id: id); XCTFail("Expected playback failure") }
            catch { XCTAssertEqual(error as? SiriLibraryError, expected) }
        }
        XCTAssertEqual(player.queue.map(\.id), ["existing"])
    }

    @MainActor
    func testEmptyPlaylistAndAllMissingAudioHaveDifferentFailures() async throws {
        let (store, _, service) = try fixture()
        let empty = PlaylistData(id: "empty", title: "Empty")
        let missing = PlaylistData(id: "missing", title: "Missing")
        store.mainContext.insert(empty); store.mainContext.insert(missing)
        missing.songs = [song("missing", in: store.mainContext)]
        for (id, expected) in [("deleted", SiriLibraryError.playlistNotFound), ("empty", .emptyPlaylist), ("missing", .audioUnavailable)] {
            do { _ = try await service.playPlaylist(id: id); XCTFail("Expected failure") }
            catch { XCTAssertEqual(error as? SiriLibraryError, expected) }
        }
    }

    @MainActor
    func testExplicitPlayAndPauseAreIdempotent() async throws {
        let (store, player, service) = try fixture()
        let model = song("play", in: store.mainContext); try audio(for: model)
        defer { player.stop() }
        try await service.playSong(id: model.id)
        try await service.play(); try await service.play()
        XCTAssertTrue(player.isPlaying)
        service.pause(); service.pause()
        XCTAssertFalse(player.isPlaying)
        try await service.play()
        XCTAssertTrue(player.isPlaying)
    }

    @MainActor
    func testPlayWithoutCurrentSongReportsNoCurrentSong() async throws {
        let (_, _, service) = try fixture()
        do { try await service.play(); XCTFail("Expected no song") }
        catch { XCTAssertEqual(error as? SiriLibraryError, .noCurrentSong) }
    }

    @MainActor
    func testLikeCurrentSongIsPersistentAndIdempotent() async throws {
        let (store, player, service) = try fixture()
        let model = song("like", in: store.mainContext)
        player.currentSong = Song.from(model); player.queue = [Song.from(model), Song.from(model)]
        try await service.likeCurrent(); try await service.likeCurrent()
        XCTAssertTrue(model.isFavorited)
        XCTAssertTrue(player.currentSong?.isFavorited == true)
        XCTAssertTrue(player.queue.allSatisfy(\.isFavorited))
        XCTAssertTrue(try store.mainContext.fetch(FetchDescriptor<SongData>()).first!.isFavorited)
    }

    @MainActor
    func testLikeWithNoCurrentSongReportsFailure() async throws {
        let (_, _, service) = try fixture()
        do { try await service.likeCurrent(); XCTFail("Expected no song") }
        catch { XCTAssertEqual(error as? SiriLibraryError, .noCurrentSong) }
    }

    @MainActor
    func testSleepTimerValidationAndCancellation() async throws {
        let (_, player, service) = try fixture()
        for minutes in [0, -1, 1441, Int.max] {
            XCTAssertThrowsError(try service.setSleepTimer(minutes: minutes)) { error in
                XCTAssertEqual(error as? SiriLibraryError, .invalidTimerDuration)
            }
        }
        XCTAssertThrowsError(try service.setSleepTimer(minutes: 30))
        player.currentSong = Song(id: "timer", title: "Timer", artist: "Artist", albumTitle: "Album", audioFileURL: URL(fileURLWithPath: "/missing"), coverImageURL: nil, subtitleFileURL: nil, isFavorited: false)
        try service.setSleepTimer(minutes: 30)
        XCTAssertTrue(player.sleepTimerActive)
        XCTAssertEqual(try XCTUnwrap(player.sleepTimerEndDate).timeIntervalSinceNow, 1800, accuracy: 2)
        service.cancelSleepTimer(); service.cancelSleepTimer()
        XCTAssertFalse(player.sleepTimerActive)
    }

    func testAppShortcutsExposeAllRequestedActions() {
        XCTAssertEqual(MusicAppShortcuts.appShortcuts.count, 7)
        XCTAssertFalse(PlaySongIntent.openAppWhenRun)
        XCTAssertFalse(PlayPlaylistIntent.openAppWhenRun)
        let song = SongEntity(id: "id", title: "Song", artist: "Artist", album: "Album")
        XCTAssertEqual(PlaySongIntent(song: song).song.id, "id")
        XCTAssertEqual(PlayPlaylistIntent(playlist: PlaylistEntity(id: "list", title: "List", songCount: 0)).playlist.id, "list")
        XCTAssertEqual(SetMusicSleepTimerIntent(minutes: 30).minutes, 30)
    }

    @MainActor
    func testNamedIntentRejectsDeletedEntityInsteadOfUsingStaleMetadata() async throws {
        let (store, _, _) = try fixture()
        let original = DataManager.shared.modelContext
        DataManager.shared.modelContext = store.mainContext
        defer { DataManager.shared.modelContext = original }
        let intent = PlaySongIntent(song: SongEntity(id: "deleted", title: "Stale", artist: "Artist", album: "Album"))
        do { _ = try await intent.perform(); XCTFail("Expected deleted entity") }
        catch { XCTAssertEqual(error as? SiriLibraryError, .songNotFound) }
    }

    #if canImport(MediaIntents)
    @MainActor
    func testMediaSearchUsesLibraryAndRejectsAmbiguityAndExternalURLs() async throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("MediaIntents requires iOS 27") }
        let (store, _, service) = try fixture()
        _ = song("one", title: "Echo", artist: "Björk", in: store.mainContext)
        _ = song("two", title: "Echo", artist: "Other", in: store.mainContext)
        let playlist = PlaylistData(id: "run", title: "Running")
        store.mainContext.insert(playlist)
        let selectedSong = try await service.resolveAudioSearch(AudioSearch(criteria: .searchQuery("Echo Bjork")))
        XCTAssertEqual(selectedSong, .song("one"))
        let selectedPlaylist = try await service.resolveAudioSearch(AudioSearch(criteria: .searchQuery("Running")))
        XCTAssertEqual(selectedPlaylist, .playlist("run"))
        let resume = try await service.resolveAudioSearch(AudioSearch(criteria: .unspecified))
        XCTAssertEqual(resume, .resume)
        for (search, failure) in [(AudioSearch(criteria: .searchQuery("Echo")), SiriLibraryError.ambiguousContent), (AudioSearch(criteria: .searchQuery("NoSuchCatalogEntry-9C7F")), .songNotFound), (AudioSearch(criteria: .url([URL(string: "https://example.com/audio")!])), .unsupportedSearch)] {
            do { _ = try await service.resolveAudioSearch(search); XCTFail("Expected search failure") }
            catch { XCTAssertEqual(error as? SiriLibraryError, failure) }
        }
    }

    #endif

    func testVoiceCommandsAreExplicitRatherThanToggles() {
        XCTAssertNotNil(PlaybackCommand(rawValue: "play"))
        XCTAssertNotNil(PlaybackCommand(rawValue: "pause"))
        XCTAssertNotNil(PlaybackCommand(rawValue: "likeCurrent"))
    }
}
