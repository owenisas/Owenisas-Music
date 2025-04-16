import Foundation

struct Song: Identifiable {
    let id = UUID()
    var title: String
    var audioFileURL: URL
    var coverImageURL: URL
}

