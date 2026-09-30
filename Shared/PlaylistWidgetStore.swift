import Foundation

enum PlaylistWidgetStore {
    static let kind = "OwenisasPlaylist"
    static var url: URL? { AppGroup.containerURL?.appendingPathComponent("playlist-widget.json") }
    static func load() -> PlaylistWidgetCatalog {
        guard let url, let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(PlaylistWidgetCatalog.self, from: data) else { return PlaylistWidgetCatalog() }
        return catalog
    }
    static func save(_ catalog: PlaylistWidgetCatalog) throws {
        guard let url else { throw CocoaError(.fileNoSuchFile) }
        try JSONEncoder().encode(catalog).write(to: url, options: .atomic)
    }
}
