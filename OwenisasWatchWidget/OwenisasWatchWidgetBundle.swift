import SwiftUI
import WidgetKit

@main
struct OwenisasWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        WatchPhoneWidget()
        WatchOfflineWidget()
    }
}

struct WatchWidgetEntry: TimelineEntry {
    var date: Date
    var snapshot: WatchWidgetSnapshot
    var destination: WatchWidgetDestination = .phone
    var relevance: TimelineEntryRelevance? {
        snapshot.isRelevant(destination, at: date) ? TimelineEntryRelevance(score: 1, duration: 300) : nil
    }
}
struct WatchWidgetProvider: TimelineProvider {
    var destination: WatchWidgetDestination = .phone
    func placeholder(in context: Context) -> WatchWidgetEntry {
        WatchWidgetEntry(date: Date(), snapshot: WatchWidgetSnapshot())
    }
    func getSnapshot(in context: Context, completion: @escaping (WatchWidgetEntry) -> Void) {
        completion(WatchWidgetEntry(date: Date(), snapshot: WatchWidgetStore.load(), destination: destination))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchWidgetEntry>) -> Void) {
        let now = Date()
        let snapshot = WatchWidgetStore.load()
        // An explicit expiry entry removes cached phone metadata even when no
        // connectivity update arrives. No per-second reload loop.
        let expiration = snapshot.nextExpiry(after: now)
        completion(Timeline(entries: [WatchWidgetEntry(date: now, snapshot: snapshot, destination: destination),
                                      WatchWidgetEntry(date: expiration, snapshot: snapshot, destination: destination)],
                            policy: .after(now.addingTimeInterval(300))))
    }
}
struct WatchPhoneWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WatchWidgetStore.phoneKind, provider: WatchWidgetProvider()) { entry in
            WatchWidgetView(entry: entry, destination: .phone)
        }
        .configurationDisplayName("iPhone Playback")
        .description("Open iPhone controls. This never plays downloaded Watch music.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
struct WatchOfflineWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WatchWidgetStore.offlineKind, provider: WatchWidgetProvider(destination: .watch)) { entry in
            WatchWidgetView(entry: entry, destination: .watch)
        }
        .configurationDisplayName("On This Watch")
        .description("Open offline playback and downloaded music, without your iPhone.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
struct WatchWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WatchWidgetEntry
    let destination: WatchWidgetDestination
    private var title: String { entry.snapshot.title(for: destination, at: entry.date) }
    private var icon: String { destination == .phone ? "iphone" : "applewatch" }
    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                VStack { Image(systemName: icon); Text(destination == .phone ? "iPhone" : "Watch").font(.caption2) }
            case .accessoryInline:
                Label(title, systemImage: icon)
            default:
                VStack(alignment: .leading) {
                    Label(destination == .phone ? "On iPhone" : "On This Watch", systemImage: icon).font(.caption)
                    Text(title).font(.headline).lineLimit(1)
                    if entry.snapshot.canControl(destination, at: entry.date) {
                        let playing = destination == .phone ? entry.snapshot.phone?.isPlaying == true : entry.snapshot.local?.isPlaying == true
                        Button(intent: WatchWidgetToggleIntent(target: destination == .phone ? .phone : .watch)) {
                            Label(playing ? "Pause" : "Play", systemImage: playing ? "pause.fill" : "play.fill")
                        }
                        .accessibilityLabel("\(playing ? "Pause" : "Play") on \(destination == .phone ? "iPhone" : "Watch")")
                    }
                }
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(destination == .watch && entry.snapshot.local == nil ? WatchWidgetDestination.downloads.url : destination.url)
        .accessibilityLabel("\(destination == .phone ? "iPhone" : "Watch"), \(title)")
    }
}
