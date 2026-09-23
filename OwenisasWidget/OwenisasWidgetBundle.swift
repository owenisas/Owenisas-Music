import SwiftUI
import WidgetKit

@main
struct OwenisasWidgetBundle: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
        PlayPauseControl()
    }
}
