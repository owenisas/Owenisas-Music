import Foundation
import SwiftData
import UIKit

/// Manages syncing the file system (Documents/Songs/) with SwiftData,
/// and provides helper methods for the UI to load Song structs.
@MainActor
class DataManager: ObservableObject {
    static let shared = DataManager()

    var modelContext: ModelContext?
    private var observerTokens: [NSObjectProtocol] = []

    // MARK: - Setup
    func configure(with context: ModelContext) {
        self.modelContext = context
        if observerTokens.isEmpty {
            setupObservers()
        }
    }

    private func setupObservers() {
        let songPlayedObserver = NotificationCenter.default.addObserver(forName: .init("SongPlayed"), object: nil, queue: .main) { [weak self] note in
            guard let songId = note.object as? String else { return }
            Task { @MainActor in
                self?.markSongAsPlayed(songId: songId)
            }
        }
        observerTokens.append(songPlayedObserver)
        
        let favoriteObserver = NotificationCenter.default.addObserver(forName: .init("SongFavoriteToggled"), object: nil, queue: .main) { [weak self] note in
            guard let songId = note.object as? String else { return }
            Task { @MainActor in
                self?.toggleFavorite(songId: songId)
            }
        }
        observerTokens.append(favoriteObserver)

        let positionObserver = NotificationCenter.default.addObserver(forName: .init("SongPositionChanged"), object: nil, queue: .main) { [weak self] note in
            guard let songId = note.object as? String,
                  let position = note.userInfo?["position"] as? TimeInterval else { return }
            Task { @MainActor in
                self?.updatePlaybackPosition(songId: songId, position: position)
            }
        }
        observerTokens.append(positionObserver)
    }

    deinit {
        for observer in observerTokens {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func markSongAsPlayed(songId: String) {
        guard let ctx = modelContext else { return }
        let descriptor = FetchDescriptor<SongData>(predicate: #Predicate { $0.id == songId })
        if let song = (try? ctx.fetch(descriptor))?.first {
            song.lastPlayedDate = .now
            song.playCount += 1
            try? ctx.save()
        }
    }

    private func toggleFavorite(songId: String) {
        guard let ctx = modelContext else { return }
        let descriptor = FetchDescriptor<SongData>(predicate: #Predicate { $0.id == songId })
        if let song = (try? ctx.fetch(descriptor))?.first {
            song.isFavorited.toggle()
            try? ctx.save()
        }
    }

    private func updatePlaybackPosition(songId: String, position: TimeInterval) {
        guard let ctx = modelContext else { return }
        let descriptor = FetchDescriptor<SongData>(predicate: #Predicate { $0.id == songId })
        if let song = (try? ctx.fetch(descriptor))?.first, abs(song.playbackPosition - position) >= 1 {
            song.playbackPosition = position
            try? ctx.save()
        }
    }

    // MARK: - Sync file system → SwiftData
    /// Scans Documents/Songs/ and upserts into SwiftData
    func syncFromFileSystem() {
        guard let ctx = modelContext else { return }
        let fm = FileManager.default
        guard let docs = fm.urls(for: FileManager.SearchPathDirectory.documentDirectory, in: FileManager.SearchPathDomainMask.userDomainMask).first else { return }
        let songsFolder = docs.appendingPathComponent("Songs")

        if !fm.fileExists(atPath: songsFolder.path) {
            try? fm.createDirectory(at: songsFolder, withIntermediateDirectories: true)
        }

        guard let initialSubfolders = try? fm.contentsOfDirectory(
            at: songsFolder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let sanitizedSubfolders = sanitizeSongFolders(initialSubfolders, in: songsFolder)
        cleanupBrokenFolders(subfolders: sanitizedSubfolders)
        let subfolders = sanitizedSubfolders.filter { fm.fileExists(atPath: $0.path) }

        print("[DEBUG] DataManager: Syncing library. Found \(subfolders.count) folders in Documents/Songs.")

        let cleanSongs = deduplicateSongData(in: ctx)
        let foundIDKeys = Set(subfolders.map { normalizedSongIDKey($0.lastPathComponent) })
        
        // 1. Remove missing
        for song in cleanSongs {
            if !foundIDKeys.contains(normalizedSongIDKey(song.id)) {
                print("[DEBUG] DataManager: Song folder removed, deleting from database: \(song.id)")
                ctx.delete(song)
            }
        }

        // 2. Sync each existing folder
        for folder in subfolders {
            syncSingleSong(folderName: folder.lastPathComponent, shouldDeduplicate: false)
        }
        
        print("[DEBUG] DataManager: Sync complete.")
        do {
            try ctx.save()
        } catch {
            print("[DEBUG] DataManager: Failed saving sync changes: \(error.localizedDescription)")
        }
    }

    private func normalizedSongID(_ id: String) -> String {
        id.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedSongIDKey(_ id: String) -> Data {
        Data(normalizedSongID(id).utf8)
    }

    private func hasSameStoredString(_ lhs: String, _ rhs: String) -> Bool {
        Data(lhs.utf8) == Data(rhs.utf8)
    }

    @discardableResult
    private func deduplicateSongData(in ctx: ModelContext) -> [SongData] {
        let descriptor = FetchDescriptor<SongData>()
        let existingSongs = (try? ctx.fetch(descriptor)) ?? []
        let groupedSongs = Dictionary(grouping: existingSongs) { normalizedSongIDKey($0.id) }
        var survivors: [SongData] = []
        var removedDuplicates = false

        for (_, songs) in groupedSongs {
            guard let firstSong = songs.first else { continue }
            let normalizedID = normalizedSongID(firstSong.id)
            let sortedSongs = songs.sorted { lhs, rhs in
                let lhsExact = hasSameStoredString(lhs.id, normalizedID)
                let rhsExact = hasSameStoredString(rhs.id, normalizedID)
                if lhsExact != rhsExact { return lhsExact }
                if lhs.isFavorited != rhs.isFavorited { return lhs.isFavorited }
                return lhs.dateAdded < rhs.dateAdded
            }

            guard let survivor = sortedSongs.first else { continue }
            survivors.append(survivor)

            for duplicate in sortedSongs.dropFirst() {
                mergeSongData(from: duplicate, into: survivor)
                print("[DEBUG] DataManager: Removing duplicate database entry: \(duplicate.id)")
                ctx.delete(duplicate)
                removedDuplicates = true
            }
        }

        if removedDuplicates {
            do {
                try ctx.save()
            } catch {
                print("[DEBUG] DataManager: Failed removing duplicate songs: \(error.localizedDescription)")
            }
        }

        var normalizedSurvivors = false
        for survivor in survivors {
            let normalizedID = normalizedSongID(survivor.id)
            if !hasSameStoredString(survivor.id, normalizedID) {
                survivor.id = normalizedID
                normalizedSurvivors = true
            }
        }

        if normalizedSurvivors {
            do {
                try ctx.save()
            } catch {
                print("[DEBUG] DataManager: Failed normalizing song IDs: \(error.localizedDescription)")
            }
        }

        return (try? ctx.fetch(descriptor)) ?? survivors
    }

    private func mergeSongData(from duplicate: SongData, into survivor: SongData) {
        if survivor.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            survivor.title = duplicate.title
        }
        if survivor.artist == "Unknown Artist", duplicate.artist != "Unknown Artist" {
            survivor.artist = duplicate.artist
        }
        if survivor.albumTitle == "Unknown Album", duplicate.albumTitle != "Unknown Album" {
            survivor.albumTitle = duplicate.albumTitle
        }
        if survivor.audioFilePath.isEmpty {
            survivor.audioFilePath = duplicate.audioFilePath
        }
        if survivor.coverImagePath == nil {
            survivor.coverImagePath = duplicate.coverImagePath
        }
        if survivor.subtitleFilePath == nil {
            survivor.subtitleFilePath = duplicate.subtitleFilePath
        }
        if survivor.duration <= 0, duplicate.duration > 0 {
            survivor.duration = duplicate.duration
        }
        if duplicate.dateAdded < survivor.dateAdded {
            survivor.dateAdded = duplicate.dateAdded
        }
        if let duplicateLastPlayed = duplicate.lastPlayedDate {
            if let survivorLastPlayed = survivor.lastPlayedDate {
                survivor.lastPlayedDate = max(survivorLastPlayed, duplicateLastPlayed)
            } else {
                survivor.lastPlayedDate = duplicateLastPlayed
            }
        }
        survivor.isFavorited = survivor.isFavorited || duplicate.isFavorited

        for playlist in duplicate.playlists where !survivor.playlists.contains(where: { $0.id == playlist.id }) {
            survivor.playlists.append(playlist)
        }

        if survivor.album == nil {
            survivor.album = duplicate.album
        }
    }

    private func sanitizeSongFolders(_ subfolders: [URL], in songsFolder: URL) -> [URL] {
        let fm = FileManager.default
        var sanitizedFolders: [URL] = []
        var seenPaths = Set<String>()

        for folderURL in subfolders {
            let originalName = folderURL.lastPathComponent
            let sanitizedName = originalName.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
            var resolvedURL = folderURL

            if originalName != sanitizedName {
                let newURL = songsFolder.appendingPathComponent(sanitizedName)
                print("[DEBUG] DataManager: Renaming folder to remove trailing spaces: '\(originalName)' -> '\(sanitizedName)'")

                if !fm.fileExists(atPath: newURL.path) {
                    try? fm.moveItem(at: folderURL, to: newURL)
                }

                if fm.fileExists(atPath: newURL.path) {
                    resolvedURL = newURL
                }
            }

            if fm.fileExists(atPath: resolvedURL.path), seenPaths.insert(resolvedURL.path).inserted {
                sanitizedFolders.append(resolvedURL)
            }
        }

        return sanitizedFolders
    }

    private func cleanupBrokenFolders(subfolders: [URL]) {
        let fm = FileManager.default
        
        for folder in subfolders {
            guard let contents = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            let hasValidAudio = firstValidAudioFile(in: contents, fileManager: fm) != nil
            
            if !hasValidAudio {
                // Never delete user audio folders during a background sync. A file can be
                // short, temporarily unavailable, or use a codec that this pass cannot
                // inspect. Leave it in place so the user can repair or re-import it.
                print("[DEBUG] DataManager: Skipping folder without validated audio: \(folder.lastPathComponent)")
                continue
            }
            
            // Validation: Check for corrupted images
            let imageExts = ["jpg", "jpeg", "png", "webp"]
            for file in contents {
                if imageExts.contains(file.pathExtension.lowercased()) {
                    let attr = (try? fm.attributesOfItem(atPath: file.path)) ?? [:]
                    let size = attr[.size] as? Int64 ?? 0
                    
                    // If image is suspiciously small, it's likely a failed download
                    if size < 5_000 {
                        print("[DEBUG] DataManager: Purging corrupted thumbnail: \(file.lastPathComponent)")
                        try? fm.removeItem(at: file)
                    } else {
                        // Check image header bytes instead of full decode (much faster)
                        if let data = try? Data(contentsOf: file, options: .mappedIfSafe),
                           data.count >= 4 {
                            let isJPEG = data.starts(with: [0xFF, 0xD8, 0xFF])
                            let isPNG = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
                            let isWebP = data.count >= 12 && data[8...11] == Data([0x57, 0x45, 0x42, 0x50])
                            if !isJPEG && !isPNG && !isWebP {
                                print("[DEBUG] DataManager: Purging unreadable image: \(file.lastPathComponent)")
                                try? fm.removeItem(at: file)
                            }
                        } else {
                            print("[DEBUG] DataManager: Purging unreadable image: \(file.lastPathComponent)")
                            try? fm.removeItem(at: file)
                        }
                    }
                }
            }
        }
    }

    private func firstValidAudioFile(in contents: [URL], fileManager: FileManager) -> URL? {
        let audioExts = ["mp3", "wav", "m4a", "aac", "flac", "aiff", "aif"]

        for file in contents where audioExts.contains(file.pathExtension.lowercased()) {
            let attr = (try? fileManager.attributesOfItem(atPath: file.path)) ?? [:]
            let size = attr[.size] as? Int64 ?? 0
            if size > 500_000 {
                return file
            }
        }

        return nil
    }

    /// Surgically syncs a single song folder. Much faster for incremental updates.
    func syncSingleSong(folderName rawFolderName: String) {
        syncSingleSong(folderName: rawFolderName, shouldDeduplicate: true)
    }

    private func syncSingleSong(folderName rawFolderName: String, shouldDeduplicate: Bool) {
        let folderName = rawFolderName.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let ctx = modelContext else { return }
        let fm = FileManager.default
        guard let docs = fm.urls(for: FileManager.SearchPathDirectory.documentDirectory, in: FileManager.SearchPathDomainMask.userDomainMask).first else { return }
        let songFolder = docs.appendingPathComponent("Songs").appendingPathComponent(folderName)

        if shouldDeduplicate {
            deduplicateSongData(in: ctx)
        }

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: songFolder.path, isDirectory: &isDir), isDir.boolValue else { return }

        guard let contents = try? fm.contentsOfDirectory(at: songFolder, includingPropertiesForKeys: nil) else { return }

        print("[DEBUG] DataManager: Syncing folder '\(folderName)' (\(contents.count) files found)")
        let imageExts = ["jpg", "jpeg", "png", "webp"]
        let subExts = ["vtt", "srv1", "txt"]

        let audioFile = firstValidAudioFile(in: contents, fileManager: fm)
        let coverFile = contents.first { imageExts.contains($0.pathExtension.lowercased()) }
        let subtitleFile = contents.first { subExts.contains($0.pathExtension.lowercased()) }

        guard let audio = audioFile else { return }

        let inferredDateAdded = inferredSongDateAdded(audioFile: audio, songFolder: songFolder, fileManager: fm)

        let audioRelPath = "Songs/\(folderName)/\(audio.lastPathComponent)"
        let coverRelPath = coverFile != nil ? "Songs/\(folderName)/\(coverFile!.lastPathComponent)" : nil
        let subtitleRelPath = subtitleFile != nil ? "Songs/\(folderName)/\(subtitleFile!.lastPathComponent)" : nil

        let descriptor = FetchDescriptor<SongData>(predicate: #Predicate { $0.id == folderName })
        let matchingSongs = ((try? ctx.fetch(descriptor)) ?? []).sorted { lhs, rhs in
            let lhsExact = hasSameStoredString(lhs.id, folderName)
            let rhsExact = hasSameStoredString(rhs.id, folderName)
            if lhsExact != rhsExact { return lhsExact }
            return lhs.dateAdded < rhs.dateAdded
        }
        if let existing = matchingSongs.first {
            for duplicate in matchingSongs.dropFirst() {
                mergeSongData(from: duplicate, into: existing)
                print("[DEBUG] DataManager: Removing duplicate database entry: \(duplicate.id)")
                ctx.delete(duplicate)
            }
            if existing.audioFilePath != audioRelPath { existing.audioFilePath = audioRelPath }
            if existing.coverImagePath != coverRelPath { existing.coverImagePath = coverRelPath }
            if existing.subtitleFilePath != subtitleRelPath { existing.subtitleFilePath = subtitleRelPath }
            if abs(existing.dateAdded.timeIntervalSince(inferredDateAdded)) > 1 {
                existing.dateAdded = inferredDateAdded
            }
        } else {
            var title = folderName
            var artist = "Unknown Artist"
            
            let parts = folderName.components(separatedBy: " - ")
            if parts.count >= 2 {
                artist = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                title = parts.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            
            let song = SongData(
                id: folderName,
                title: title,
                artist: artist,
                audioFilePath: audioRelPath,
                coverImagePath: coverRelPath,
                subtitleFilePath: subtitleRelPath,
                dateAdded: inferredDateAdded
            )
            ctx.insert(song)
        }
        do {
            try ctx.save()
        } catch {
            print("[DEBUG] DataManager: Failed syncing folder '\(folderName)': \(error.localizedDescription)")
        }
    }

    private func inferredSongDateAdded(audioFile: URL, songFolder: URL, fileManager: FileManager) -> Date {
        let audioAttrs = (try? fileManager.attributesOfItem(atPath: audioFile.path)) ?? [:]
        let folderAttrs = (try? fileManager.attributesOfItem(atPath: songFolder.path)) ?? [:]

        let candidates = [
            audioAttrs[.creationDate] as? Date,
            audioAttrs[.modificationDate] as? Date,
            folderAttrs[.creationDate] as? Date,
            folderAttrs[.modificationDate] as? Date
        ].compactMap { $0 }

        return candidates.min() ?? .now
    }

    // MARK: - Fetch helpers
    func fetchAllSongs() -> [SongData] {
        guard let ctx = modelContext else { return [] }
        let descriptor = FetchDescriptor<SongData>(sortBy: [SortDescriptor(\.dateAdded, order: .reverse)])
        return (try? ctx.fetch(descriptor)) ?? []
    }

    func fetchAllAlbums() -> [AlbumData] {
        guard let ctx = modelContext else { return [] }
        let descriptor = FetchDescriptor<AlbumData>(sortBy: [SortDescriptor(\.dateAdded, order: .reverse)])
        return (try? ctx.fetch(descriptor)) ?? []
    }

    func fetchAllPlaylists() -> [PlaylistData] {
        guard let ctx = modelContext else { return [] }
        let descriptor = FetchDescriptor<PlaylistData>(sortBy: [SortDescriptor(\.dateCreated, order: .reverse)])
        return (try? ctx.fetch(descriptor)) ?? []
    }

    // MARK: - Playlist CRUD
    func createPlaylist(title: String, coverImagePath: String? = nil) -> PlaylistData? {
        guard let ctx = modelContext else { return nil }
        let playlist = PlaylistData(title: title, coverImagePath: coverImagePath)
        ctx.insert(playlist)
        try? ctx.save()
        NotificationCenter.default.post(name: .init("PlaylistsChanged"), object: nil)
        return playlist
    }

    func addSong(_ song: SongData, to playlist: PlaylistData) {
        if !playlist.songs.contains(where: { $0.id == song.id }) {
            playlist.songs.append(song)
            try? modelContext?.save()
            NotificationCenter.default.post(name: .init("PlaylistsChanged"), object: nil)
        }
    }

    func addSongs(_ songs: [SongData], to playlist: PlaylistData) {
        var added = false
        for song in songs {
            if !playlist.songs.contains(where: { $0.id == song.id }) {
                playlist.songs.append(song)
                added = true
            }
        }
        if added {
            try? modelContext?.save()
            NotificationCenter.default.post(name: .init("PlaylistsChanged"), object: nil)
        }
    }

    func removeSong(_ song: SongData, from playlist: PlaylistData) {
        playlist.songs.removeAll { $0.id == song.id }
        try? modelContext?.save()
        NotificationCenter.default.post(name: .init("PlaylistsChanged"), object: nil)
    }

    func deletePlaylist(_ playlist: PlaylistData) {
        modelContext?.delete(playlist)
        try? modelContext?.save()
        NotificationCenter.default.post(name: .init("PlaylistsChanged"), object: nil)
    }

    func renamePlaylist(_ playlist: PlaylistData, to newTitle: String) {
        playlist.title = newTitle
        try? modelContext?.save()
        NotificationCenter.default.post(name: .init("PlaylistsChanged"), object: nil)
    }

    // MARK: - Song deletion
    func resetLibraryForUITests() {
        guard let ctx = modelContext else { return }
        let fm = FileManager.default
        guard let docs = fm.urls(for: FileManager.SearchPathDirectory.documentDirectory, in: FileManager.SearchPathDomainMask.userDomainMask).first else { return }

        do {
            let songsFolder = docs.appendingPathComponent("Songs")
            if fm.fileExists(atPath: songsFolder.path) {
                try fm.removeItem(at: songsFolder)
            }
            try fm.createDirectory(at: songsFolder, withIntermediateDirectories: true)
        } catch {
            debugPrint("Failed resetting Songs folder for UI tests: \(error.localizedDescription)")
        }

        if let songs = try? ctx.fetch(FetchDescriptor<SongData>()) {
            for song in songs {
                ctx.delete(song)
            }
        }

        if let playlists = try? ctx.fetch(FetchDescriptor<PlaylistData>()) {
            for playlist in playlists {
                ctx.delete(playlist)
            }
        }

        try? ctx.save()
        NotificationCenter.default.post(name: .init("SongsFolderChanged"), object: nil)
        NotificationCenter.default.post(name: .init("PlaylistsChanged"), object: nil)
    }

    func deleteSongs(_ songs: [SongData]) {
        guard let ctx = modelContext else { return }
        let fm = FileManager.default
        guard let docs = fm.urls(for: FileManager.SearchPathDirectory.documentDirectory, in: FileManager.SearchPathDomainMask.userDomainMask).first else { return }

        for song in songs {
            // Stop playback
            MusicPlayerManager.shared.stopAndRemoveFromQueue(songId: song.id)
            
            // Filesystem removal
            let songFolder = docs.appendingPathComponent("Songs").appendingPathComponent(song.id)
            try? fm.removeItem(at: songFolder)
            
            // Database removal
            ctx.delete(song)
        }
        
        try? ctx.save()
        NotificationCenter.default.post(name: .init("SongsFolderChanged"), object: nil)
    }

    func deleteSong(_ song: SongData) {
        deleteSongs([song])
    }

    // MARK: - Import local audio files
    /// Audio formats the player and sync pipeline both understand.
    static let importableAudioExtensions: Set<String> = ["mp3", "wav", "m4a", "aac", "flac", "aiff", "aif"]

    /// Copies user-picked audio files into Documents/Songs/<name>/ and syncs them.
    /// Returns how many imported vs. skipped (unsupported type or copy failure).
    func importAudioFiles(from urls: [URL]) -> (imported: Int, skipped: Int) {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return (0, urls.count)
        }

        var imported = 0
        var skipped = 0

        for url in urls {
            guard Self.importableAudioExtensions.contains(url.pathExtension.lowercased()) else {
                skipped += 1
                continue
            }

            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            let folderName = url.deletingPathExtension().lastPathComponent
                .precomposedStringWithCanonicalMapping
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !folderName.isEmpty else {
                skipped += 1
                continue
            }

            let songFolder = docs.appendingPathComponent("Songs").appendingPathComponent(folderName)
            let destination = songFolder.appendingPathComponent(url.lastPathComponent)
            // Picking a file already inside our own Songs folder must not
            // delete-then-copy onto itself — just (re)index it in place.
            let sourcePath = url.resolvingSymlinksInPath().standardizedFileURL.path
            let destinationPath = destination.resolvingSymlinksInPath().standardizedFileURL.path
            if sourcePath == destinationPath {
                syncSingleSong(folderName: folderName)
                imported += 1
                continue
            }
            do {
                try fm.createDirectory(at: songFolder, withIntermediateDirectories: true)
                if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination)
                }
                try fm.copyItem(at: url, to: destination)
                syncSingleSong(folderName: folderName)
                imported += 1
            } catch {
                print("[DEBUG] DataManager: Import failed for \(url.lastPathComponent): \(error.localizedDescription)")
                skipped += 1
            }
        }

        if imported > 0 {
            NotificationCenter.default.post(name: .init("SongsFolderChanged"), object: nil)
        }
        return (imported, skipped)
    }

    // MARK: - Backup & restore (playlists, likes, play history)
    func exportBackupData() -> Data? {
        guard let ctx = modelContext else { return nil }
        let songs = (try? ctx.fetch(FetchDescriptor<SongData>())) ?? []
        let playlists = (try? ctx.fetch(FetchDescriptor<PlaylistData>())) ?? []

        let backup = LibraryBackup(
            exportDate: .now,
            songs: songs.map {
                LibraryBackup.SongBackup(
                    id: $0.id,
                    playCount: $0.playCount,
                    isFavorited: $0.isFavorited,
                    lastPlayedDate: $0.lastPlayedDate,
                    dateAdded: $0.dateAdded,
                    playbackPosition: $0.playbackPosition > 0 ? $0.playbackPosition : nil
                )
            },
            playlists: playlists.map {
                LibraryBackup.PlaylistBackup(
                    title: $0.title,
                    dateCreated: $0.dateCreated,
                    songIDs: $0.songs.map(\.id)
                )
            }
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(backup)
    }

    /// Merges a backup into the current library. Never deletes anything:
    /// likes/play counts take the richer value, playlists are matched by title.
    @discardableResult
    func importBackupData(_ data: Data) -> LibraryBackupImportResult? {
        guard let ctx = modelContext else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let backup = try? decoder.decode(LibraryBackup.self, from: data) else { return nil }

        let allSongs = (try? ctx.fetch(FetchDescriptor<SongData>())) ?? []
        let songsByID = Dictionary(allSongs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var matchedSongs = 0
        for entry in backup.songs {
            guard let song = songsByID[entry.id] else { continue }
            matchedSongs += 1
            song.playCount = max(song.playCount, entry.playCount)
            song.isFavorited = song.isFavorited || entry.isFavorited
            if let last = entry.lastPlayedDate {
                song.lastPlayedDate = max(song.lastPlayedDate ?? .distantPast, last)
            }
            if let added = entry.dateAdded, added < song.dateAdded {
                song.dateAdded = added
            }
            if let position = entry.playbackPosition, song.playbackPosition == 0 {
                song.playbackPosition = position
            }
        }

        var newPlaylists = 0
        let existingPlaylists = (try? ctx.fetch(FetchDescriptor<PlaylistData>())) ?? []
        for entry in backup.playlists {
            let target: PlaylistData
            if let existing = existingPlaylists.first(where: { $0.title == entry.title }) {
                target = existing
            } else {
                target = PlaylistData(title: entry.title, dateCreated: entry.dateCreated)
                ctx.insert(target)
                newPlaylists += 1
            }
            for songID in entry.songIDs {
                if let song = songsByID[songID], !target.songs.contains(where: { $0.id == song.id }) {
                    target.songs.append(song)
                }
            }
        }

        do {
            try ctx.save()
        } catch {
            print("[DEBUG] DataManager: Backup import save failed: \(error.localizedDescription)")
            return nil
        }
        NotificationCenter.default.post(name: .init("PlaylistsChanged"), object: nil)
        return LibraryBackupImportResult(
            matchedSongs: matchedSongs,
            totalSongs: backup.songs.count,
            newPlaylists: newPlaylists
        )
    }

    // MARK: - Convert SongData → Song (lightweight struct for player)
    func toSong(_ data: SongData) -> Song {
        Song.from(data)
    }

    func toSongs(_ dataArray: [SongData]) -> [Song] {
        dataArray.map { Song.from($0) }
    }
}

