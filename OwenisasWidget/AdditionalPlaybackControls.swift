import AppIntents
import SwiftUI
import WidgetKit

struct NextTrackControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "OwenisasNextTrack") {
            ControlWidgetButton(action: NextTrackIntent()) { Label("Next Song", systemImage: "forward.end.fill") }
        }
        .displayName("Next Song")
        .description("Skip to the next song on iPhone.")
    }
}
struct FavoriteTrackControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "OwenisasFavoriteTrack") {
            ControlWidgetButton(action: ToggleFavoriteIntent()) { Label("Like / Unlike", systemImage: "heart") }
        }
        .displayName("Like / Unlike")
        .description("Toggle Liked Songs membership for the current iPhone song.")
    }
}
