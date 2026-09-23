import SwiftUI
import WidgetKit

/// Reads the snapshot the app writes (NowPlayingBridge). The app reloads this
/// kind whenever something visible changes, so the timeline never refreshes
/// on its own; progress is drawn with timer-driven views instead.
struct NowPlayingProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry {
        NowPlayingEntry(date: Date(), snapshot: .preview(), artwork: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        let entry = NowPlayingEntry.load()
        if context.isPreview && !entry.snapshot.hasSong {
            // Widget gallery with nothing playing: show what it looks like in use.
            completion(NowPlayingEntry(date: Date(), snapshot: .preview(), artwork: nil))
        } else {
            completion(entry)
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        let now = Date()
        let current = NowPlayingEntry.load(at: now)
        var entries = [current]
        // If the app stops reporting (killed mid-song), flip to "paused at the
        // end" when the track would have finished instead of showing a full,
        // still-"playing" bar forever.
        if let end = current.snapshot.projectedEndDate, end > now {
            entries.append(NowPlayingEntry(
                date: end,
                snapshot: current.snapshot.pausedAtEnd(at: end),
                artwork: current.artwork
            ))
        }
        completion(Timeline(entries: entries, policy: .never))
    }
}

struct NowPlayingWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NowPlayingEntry

    var body: some View {
        switch family {
        case .systemSmall, .systemMedium:
            NowPlayingWidgetView(entry: entry, family: family)
                .environment(\.colorScheme, .dark)
                .containerBackground(for: .widget) {
                    NowPlayingBackground(artwork: entry.snapshot.hasSong ? entry.artwork : nil)
                }
        default:
            NowPlayingWidgetView(entry: entry, family: family)
                .containerBackground(for: .widget) { Color.clear }
        }
    }
}

struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: NowPlayingWidgetKind.nowPlaying, provider: NowPlayingProvider()) { entry in
            NowPlayingWidgetEntryView(entry: entry)
                .widgetURL(NowPlayingWidgetKind.openURL)
        }
        .configurationDisplayName("Now Playing")
        .description("See what's playing and control it without opening the app.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryRectangular,
            .accessoryCircular,
            .accessoryInline
        ])
    }
}

// MARK: - Previews

private extension NowPlayingEntry {
    static var previewPlaying: NowPlayingEntry {
        NowPlayingEntry(date: Date(), snapshot: .preview(isPlaying: true), artwork: nil)
    }

    static var previewPaused: NowPlayingEntry {
        NowPlayingEntry(date: Date(), snapshot: .preview(isPlaying: false, isFavorited: false), artwork: nil)
    }

    static var previewEmpty: NowPlayingEntry {
        NowPlayingEntry(date: Date(), snapshot: .notPlaying(), artwork: nil)
    }
}

#Preview("Small", as: .systemSmall) {
    NowPlayingWidget()
} timeline: {
    NowPlayingEntry.previewPlaying
    NowPlayingEntry.previewPaused
    NowPlayingEntry.previewEmpty
}

#Preview("Medium", as: .systemMedium) {
    NowPlayingWidget()
} timeline: {
    NowPlayingEntry.previewPlaying
    NowPlayingEntry.previewPaused
    NowPlayingEntry.previewEmpty
}

#Preview("Lock Screen rectangular", as: .accessoryRectangular) {
    NowPlayingWidget()
} timeline: {
    NowPlayingEntry.previewPlaying
    NowPlayingEntry.previewPaused
    NowPlayingEntry.previewEmpty
}

#Preview("Lock Screen circular", as: .accessoryCircular) {
    NowPlayingWidget()
} timeline: {
    NowPlayingEntry.previewPlaying
    NowPlayingEntry.previewPaused
    NowPlayingEntry.previewEmpty
}

#Preview("Lock Screen inline", as: .accessoryInline) {
    NowPlayingWidget()
} timeline: {
    NowPlayingEntry.previewPlaying
    NowPlayingEntry.previewEmpty
}
