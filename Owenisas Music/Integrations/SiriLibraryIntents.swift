import AppIntents

struct PlaySongIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Song"
    static let description = IntentDescription("Play an imported song on your iPhone. Select by title and artist.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    @Parameter(title: "Song") var song: SongEntity
    static var parameterSummary: some ParameterSummary { Summary("Play \(\.$song)") }
    init() {}
    init(song: SongEntity) { self.song = song }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        NowPlayingBridge.shared.start()
        try await SiriLibraryService.live.playSong(id: song.id)
        return .result(dialog: "Playing your song on iPhone.")
    }
}

struct PlayPlaylistIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Playlist"
    static let description = IntentDescription("Play a local playlist on your iPhone in its saved order. Missing audio is skipped.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    @Parameter(title: "Playlist") var playlist: PlaylistEntity
    static var parameterSummary: some ParameterSummary { Summary("Play \(\.$playlist)") }
    init() {}
    init(playlist: PlaylistEntity) { self.playlist = playlist }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        NowPlayingBridge.shared.start()
        let skipped = try await SiriLibraryService.live.playPlaylist(id: playlist.id)
        if skipped > 0 { return .result(dialog: "Playing your playlist on iPhone. Skipped \(skipped) unavailable tracks.") }
        return .result(dialog: "Playing your playlist on iPhone.")
    }
}

struct ResumeMusicIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Resume Music"
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    init() {}
    @MainActor func perform() async throws -> some IntentResult {
        NowPlayingBridge.shared.start()
        try await SiriLibraryService.live.play()
        return .result()
    }
}

struct PauseMusicIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Pause Music"
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    init() {}
    @MainActor func perform() async throws -> some IntentResult {
        NowPlayingBridge.shared.start()
        SiriLibraryService.live.pause()
        return .result()
    }
}

struct LikeCurrentSongIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Like Current Song"
    static let description = IntentDescription("Add the current iPhone song to Liked Songs. Does not unlike an already liked song.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    init() {}
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        NowPlayingBridge.shared.start()
        try await SiriLibraryService.live.likeCurrent()
        return .result(dialog: "Added to Liked Songs.")
    }
}

struct SetMusicSleepTimerIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Set Music Sleep Timer"
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    @Parameter(title: "Minutes", default: 30, inclusiveRange: (1, 1440)) var minutes: Int
    static var parameterSummary: some ParameterSummary { Summary("Stop playing in \(\.$minutes) minutes") }
    init() {}
    init(minutes: Int) { self.minutes = minutes }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        try SiriLibraryService.live.setSleepTimer(minutes: minutes)
        return .result(dialog: "Music will stop in \(minutes) minutes.")
    }
}

struct CancelMusicSleepTimerIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Cancel Music Sleep Timer"
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    init() {}
    @MainActor func perform() async throws -> some IntentResult {
        SiriLibraryService.live.cancelSleepTimer()
        return .result()
    }
}

struct MusicAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PlaySongIntent(), phrases: ["Play \(\.$song) in \(.applicationName)", "Play a song in \(.applicationName)"], shortTitle: "Play Song", systemImageName: "music.note")
        AppShortcut(intent: PlayPlaylistIntent(), phrases: ["Play \(\.$playlist) in \(.applicationName)", "Play my \(\.$playlist) playlist in \(.applicationName)"], shortTitle: "Play Playlist", systemImageName: "music.note.list")
        AppShortcut(intent: ResumeMusicIntent(), phrases: ["Play music in \(.applicationName)", "Resume music in \(.applicationName)"], shortTitle: "Resume", systemImageName: "play.fill")
        AppShortcut(intent: PauseMusicIntent(), phrases: ["Pause music in \(.applicationName)"], shortTitle: "Pause", systemImageName: "pause.fill")
        AppShortcut(intent: LikeCurrentSongIntent(), phrases: ["Like this song in \(.applicationName)"], shortTitle: "Like Song", systemImageName: "heart.fill")
        AppShortcut(intent: SetMusicSleepTimerIntent(), phrases: ["Set a sleep timer in \(.applicationName)"], shortTitle: "Sleep Timer", systemImageName: "moon.fill")
        AppShortcut(intent: CancelMusicSleepTimerIntent(), phrases: ["Cancel the sleep timer in \(.applicationName)"], shortTitle: "Cancel Timer", systemImageName: "moon.slash")
    }
}
