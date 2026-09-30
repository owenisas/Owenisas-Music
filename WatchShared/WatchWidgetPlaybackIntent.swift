#if os(watchOS)
import AppIntents
import Foundation

enum WatchPlaybackTarget: String, AppEnum {
    case phone, watch
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Playback Device"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.phone: "Phone", .watch: "This Watch"]
}
struct WatchWidgetToggleIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play or Pause on Selected Device"
    @Parameter(title: "Playback Device") var target: WatchPlaybackTarget
    init() { target = .phone }
    init(target: WatchPlaybackTarget) { self.target = target }
    enum Failure: LocalizedError {
        case unavailable, noLocalTrack
        var errorDescription: String? {
            switch self {
            case .unavailable: "Open Owenisas Music on your nearby iPhone."
            case .noLocalTrack: "Open Downloads on this Watch and choose a song."
            }
        }
    }
    func perform() async throws -> some IntentResult {
        #if !WATCH_WIDGET_EXTENSION
        try await performOnWatch()
        #endif
        return .result()
    }
    #if !WATCH_WIDGET_EXTENSION
    @MainActor
    private func performOnWatch() async throws {
        switch target {
        case .phone:
            let phone = PhoneLink.shared
            phone.activate()
            guard phone.isReachable else { throw Failure.unavailable }
            // The live reply, not cached widget state, decides whether playback
            // succeeded. A failed command is never queued to run unexpectedly.
            try await phone.send(WatchCommand(action: .togglePlayPause))
        case .watch:
            let player = WatchLocalPlayer.shared
            guard player.hasTrack else { throw Failure.noLocalTrack }
            await player.togglePlayPause()
            if let problem = player.problem { throw NSError(domain: "WatchPlayback", code: 1, userInfo: [NSLocalizedDescriptionKey: problem]) }
        }
    }
    #endif
}
#endif
