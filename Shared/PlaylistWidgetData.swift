import Foundation

struct PlaylistWidgetItem: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var songCount: Int
}
struct PlaylistWidgetCatalog: Codable, Equatable {
    var items: [PlaylistWidgetItem] = []
    var capturedAt: Date = .distantPast
    func item(id: String?) -> PlaylistWidgetItem? {
        items.first { $0.id == (id ?? "liked") }
    }
}
