import AppIntents
import SwiftUI
import WidgetKit

/// Control Center / Lock Screen / Action button control (iOS 18).
/// Shows the current play state from the shared snapshot; tapping runs
/// TogglePlaybackIntent in the app process, which reloads this control.
struct PlayPauseControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: NowPlayingWidgetKind.playPauseControl,
            provider: PlaybackStateProvider()
        ) { isPlaying in
            ControlWidgetButton(action: TogglePlaybackIntent()) {
                Label(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill")
            }
            .tint(.green)
        }
        .displayName("Play/Pause")
        .description("Play or pause Owenisas Music.")
    }
}

struct PlaybackStateProvider: ControlValueProvider {
    var previewValue: Bool { false }

    func currentValue() async throws -> Bool {
        let snapshot = NowPlayingStore.shared.load().resolved(at: Date())
        return snapshot.hasSong && snapshot.isPlaying
    }
}
