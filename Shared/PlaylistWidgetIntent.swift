#if !SHARE_EXTENSION && !os(watchOS)
import AppIntents

struct WidgetPlaylistEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Playlist"
    static let defaultQuery = WidgetPlaylistQuery()
    var id: String
    var title: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
    init(_ item: PlaylistWidgetItem) { id = item.id; title = item.title }
}
struct WidgetPlaylistQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [WidgetPlaylistEntity] {
        let catalog = PlaylistWidgetStore.load()
        return identifiers.compactMap { catalog.item(id: $0).map(WidgetPlaylistEntity.init) }
    }
    func suggestedEntities() async throws -> [WidgetPlaylistEntity] {
        PlaylistWidgetStore.load().items.map(WidgetPlaylistEntity.init)
    }
    func defaultResult() async -> WidgetPlaylistEntity? {
        PlaylistWidgetStore.load().item(id: nil).map(WidgetPlaylistEntity.init)
    }
}
struct PlaylistWidgetConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Choose Playlist"
    static let description = IntentDescription("Pin Liked Songs or a playlist from your library.")
    @Parameter(title: "Playlist") var playlist: WidgetPlaylistEntity?
}
struct PlayWidgetPlaylistIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Pinned Playlist"
    @Parameter(title: "Playlist ID") var playlistID: String
    init() { playlistID = "liked" }
    init(id: String) { playlistID = id }
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        try await PlaylistWidgetPublisher.play(id: playlistID)
        #endif
        return .result()
    }
}
#endif
