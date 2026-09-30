// Playback controls for the Home Screen / Lock Screen widgets and the
// Control Center control.
//
// Every intent adopts `AudioPlaybackIntent`, so the system runs `perform()` in
// the app's process (launching it in the background when needed), where the
// player lives. That requires the same types to be compiled into both the
// app and the widget extension: the widget's copy only describes the button,
// and its `perform()` body is never reached. The share extension also
// compiles Shared/ but has no use for these, so it gets nothing.
#if !SHARE_EXTENSION
import AppIntents

/// What a playback intent asks the app to do.
enum PlaybackCommand: String {
    case play
    case pause
    case likeCurrent
    case togglePlayPause
    case next
    case previous
    case toggleFavorite
}

enum PlaybackIntentRunner {
    static func run(_ command: PlaybackCommand) async {
        #if WIDGET_EXTENSION
        // Not reached: AudioPlaybackIntent executes in the app process.
        #else
        await NowPlayingBridge.shared.perform(command)
        #endif
    }
}

struct TogglePlaybackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play or Pause"
    static let description = IntentDescription("Plays or pauses the current song in Owenisas Music.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    init() {}

    func perform() async throws -> some IntentResult {
        await PlaybackIntentRunner.run(.togglePlayPause)
        return .result()
    }
}

struct NextTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Next Song"
    static let description = IntentDescription("Skips to the next song in the Owenisas Music queue.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    init() {}

    func perform() async throws -> some IntentResult {
        await PlaybackIntentRunner.run(.next)
        return .result()
    }
}

struct PreviousTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Previous Song"
    static let description = IntentDescription("Restarts the song, or goes back to the previous one in Owenisas Music.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    init() {}

    func perform() async throws -> some IntentResult {
        await PlaybackIntentRunner.run(.previous)
        return .result()
    }
}

struct ToggleFavoriteIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Like or Unlike Current Song"
    static let description = IntentDescription("Adds the current song to Liked Songs, or removes it.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    init() {}

    func perform() async throws -> some IntentResult {
        await PlaybackIntentRunner.run(.toggleFavorite)
        return .result()
    }
}
#endif
