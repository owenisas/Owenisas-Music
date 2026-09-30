import AppIntents
import SwiftUI
import WidgetKit

struct PlaylistWidgetEntry: TimelineEntry {
    var date: Date
    var item: PlaylistWidgetItem?
    var libraryReady: Bool
}
struct PlaylistWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> PlaylistWidgetEntry {
        PlaylistWidgetEntry(date: Date(), item: PlaylistWidgetItem(id: "liked", title: "Liked Songs", songCount: 12), libraryReady: true)
    }
    func snapshot(for configuration: PlaylistWidgetConfiguration, in context: Context) async -> PlaylistWidgetEntry { entry(configuration) }
    func timeline(for configuration: PlaylistWidgetConfiguration, in context: Context) async -> Timeline<PlaylistWidgetEntry> {
        Timeline(entries: [entry(configuration)], policy: .after(Date().addingTimeInterval(900)))
    }
    private func entry(_ configuration: PlaylistWidgetConfiguration) -> PlaylistWidgetEntry {
        let catalog = PlaylistWidgetStore.load()
        return PlaylistWidgetEntry(date: Date(), item: catalog.item(id: configuration.playlist?.id), libraryReady: catalog.capturedAt != .distantPast)
    }
}
struct PlaylistWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: PlaylistWidgetStore.kind, intent: PlaylistWidgetConfiguration.self, provider: PlaylistWidgetProvider()) { entry in
            VStack(alignment: .leading, spacing: 8) {
                Label(entry.item?.title ?? (entry.libraryReady ? "Playlist Removed" : "Open Music"), systemImage: entry.item?.id == "liked" ? "heart.fill" : "music.note.list")
                    .font(.headline).lineLimit(2)
                if let item = entry.item {
                    Text("\(item.songCount) songs").font(.caption).foregroundStyle(.secondary)
                    if item.songCount > 0 {
                        Button(intent: PlayWidgetPlaylistIntent(id: item.id)) { Label("Play on iPhone", systemImage: "play.fill") }
                            .tint(.green)
                    } else { Text("Add songs in the app").font(.caption) }
                } else {
                    Text(entry.libraryReady ? "Edit widget to choose a playlist" : "Load your library in the app").font(.caption)
                }
            }
            .containerBackground(.fill.tertiary, for: .widget)
            .widgetURL(URL(string: "owenisas://nowplaying"))
        }
        .configurationDisplayName("Playlist")
        .description("Play Liked Songs or your chosen playlist on iPhone.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
