import AppIntents

/// IDs are the library's persisted sync keys, never titles, file URLs or SwiftData IDs.
struct SongEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Song"
    static let defaultQuery = SongEntityQuery()
    let id: String
    @Property(title: "Title") var title: String
    @Property(title: "Artist") var artist: String
    @Property(title: "Album") var album: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(artist) · \(album) · \(id)")
    }

    init(id: String, title: String, artist: String, album: String) {
        self.id = id; self.title = title; self.artist = artist; self.album = album
    }

    @MainActor init(_ song: SongData) {
        self.init(id: song.id, title: song.title, artist: song.artist, album: song.albumTitle)
    }
}

struct PlaylistEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Playlist"
    static let defaultQuery = PlaylistEntityQuery()
    let id: String
    @Property(title: "Title") var title: String
    @Property(title: "Song Count") var songCount: Int

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(songCount) songs · \(id)")
    }

    init(id: String, title: String, songCount: Int) {
        self.id = id; self.title = title; self.songCount = songCount
    }

    @MainActor init(_ playlist: PlaylistData) {
        self.init(id: playlist.id, title: playlist.title, songCount: playlist.songs.count)
    }
}

struct SongEntityQuery: EntityStringQuery {
    private let service: SiriLibraryService?
    init() { self.service = nil }
    init(service: SiriLibraryService) { self.service = service }

    @MainActor func entities(for identifiers: [String]) async throws -> [SongEntity] {
        let songs = try await (service ?? .live).songs()
        let byID = Dictionary(songs.map { ($0.id, SongEntity($0)) }, uniquingKeysWith: { first, _ in first })
        return identifiers.compactMap { byID[$0] }
    }

    @MainActor func entities(matching string: String) async throws -> [SongEntity] {
        try await (service ?? .live).songs().filter {
            SiriLibraryService.matches(string, in: $0.title + " " + $0.artist + " " + $0.albumTitle)
        }.map(SongEntity.init)
    }

    @MainActor func suggestedEntities() async throws -> [SongEntity] {
        Array(try await (service ?? .live).songs().prefix(30)).map(SongEntity.init)
    }
}

struct PlaylistEntityQuery: EntityStringQuery {
    private let service: SiriLibraryService?
    init() { self.service = nil }
    init(service: SiriLibraryService) { self.service = service }

    @MainActor func entities(for identifiers: [String]) async throws -> [PlaylistEntity] {
        let playlists = try await (service ?? .live).playlists()
        let byID = Dictionary(playlists.map { ($0.id, PlaylistEntity($0)) }, uniquingKeysWith: { first, _ in first })
        return identifiers.compactMap { byID[$0] }
    }

    @MainActor func entities(matching string: String) async throws -> [PlaylistEntity] {
        try await (service ?? .live).playlists().filter { SiriLibraryService.matches(string, in: $0.title) }.map(PlaylistEntity.init)
    }

    @MainActor func suggestedEntities() async throws -> [PlaylistEntity] {
        Array(try await (service ?? .live).playlists().prefix(30)).map(PlaylistEntity.init)
    }
}
