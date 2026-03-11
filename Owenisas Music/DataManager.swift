import Foundation
import SwiftData
import UIKit

/// Manages syncing the file system (Documents/Songs/) with SwiftData,
/// and provides helper methods for the UI to load Song structs.
@MainActor
class DataManager: ObservableObject {
    static let shared = DataManager()

    var modelContext: ModelContext?

    // MARK: - Setup
    func configure(with context: ModelContext) {
        self.modelContext = context
        setupObservers()
    }

    private func setupObservers() {
        NotificationCenter.default.addObserver(forName: .init("SongPlayed"), object: nil, queue: .main) { [weak self] note in
            guard let songId = note.object as? String else { return }
            Task { @MainActor in
                self?.markSongAsPlayed(songId: songId)
            }
        }
        
        NotificationCenter.default.addObserver(forName: .init("SongFavoriteToggled"), object: nil, queue: .main) { [weak self] note in
            guard let songId = note.object as? String else { return }
            Task { @MainActor in
                self?.toggleFavorite(songId: songId)
            }
        }
    }

    private func markSongAsPlayed(songId: String) {
        guard let ctx = modelContext else { return }
        let descriptor = FetchDescriptor<SongData>(predicate: #Predicate { $0.id == songId })
        if let song = (try? ctx.fetch(descriptor))?.first {
            song.lastPlayedDate = .now
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

        guard let subfolders = try? fm.contentsOfDirectory(
            at: songsFolder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        print("[DEBUG] DataManager: Syncing library. Found \(subfolders.count) folders in Documents/Songs.")

        let allDescriptor = FetchDescriptor<SongData>()
        let existingSongs = (try? ctx.fetch(allDescriptor)) ?? []
        
        // 0. Deduplicate database (Fix for previous normalization bug)
        var seenIDs = Set<String>()
        var duplicatesToRemove = [SongData]()
        for song in existingSongs {
            let normalizedID = song.id.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
            if seenIDs.contains(normalizedID) {
                duplicatesToRemove.append(song)
            } else {
                seenIDs.insert(normalizedID)
                if song.id != normalizedID { song.id = normalizedID } // Fix in-place
            }
        }
        for dup in duplicatesToRemove {
            print("[DEBUG] DataManager: Removing duplicate database entry: \(dup.id)")
            ctx.delete(dup)
        }
        try? ctx.save()

        // Re-fetch clean list
        let cleanSongs = (try? ctx.fetch(allDescriptor)) ?? []
        let foundIDs = Set(subfolders.map { $0.lastPathComponent.precomposedStringWithCanonicalMapping })
        
        // 1. Remove missing
        for song in cleanSongs {
            if !foundIDs.contains(song.id) {
                print("[DEBUG] DataManager: Song folder removed, deleting from database: \(song.id)")
                ctx.delete(song)
            }
        }

        // 2. Sync each existing folder
        for folder in subfolders {
            syncSingleSong(folderName: folder.lastPathComponent)
        }
        
        // 3. Clean up empty/corrupted folders (those that didn't sync because they lack audio)
        // 2. Sanitize Physical Folders (Fix trailing spaces on disk)
        let songsDir = docs.appendingPathComponent("Songs")
        
        for folderURL in subfolders {
            let originalName = folderURL.lastPathComponent
            let sanitizedName = originalName.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
            
            if originalName != sanitizedName {
                let newURL = songsDir.appendingPathComponent(sanitizedName)
                print("[DEBUG] DataManager: Renaming folder to remove trailing spaces: '\(originalName)' -> '\(sanitizedName)'")
                try? fm.moveItem(at: folderURL, to: newURL)
            }
        }

        cleanupBrokenFolders(subfolders: subfolders)
        
        print("[DEBUG] DataManager: Sync complete.")
        try? ctx.save()
    }

    private func cleanupBrokenFolders(subfolders: [URL]) {
        let fm = FileManager.default
        let audioExts = ["mp3", "wav", "m4a", "aac", "flac"]
        
        for folder in subfolders {
            guard let contents = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            
            // Validation: Must have audio file AND it must be reasonably sized (> 500KB)
            var hasValidAudio = false
            for file in contents {
                if audioExts.contains(file.pathExtension.lowercased()) {
                    let attr = (try? fm.attributesOfItem(atPath: file.path)) ?? [:]
                    let size = attr[.size] as? Int64 ?? 0
                    if size > 500_000 { // 500KB min for a song
                        hasValidAudio = true
                        break
                    }
                }
            }
            
            if !hasValidAudio {
                print("[DEBUG] DataManager: Cleaning up broken/empty/corrupted folder: \(folder.lastPathComponent)")
                try? fm.removeItem(at: folder)
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
                        // Optional: Try to decode as extra safety (can be slow, but good for stability)
                        if UIImage(contentsOfFile: file.path) == nil {
                            print("[DEBUG] DataManager: Purging unreadable image: \(file.lastPathComponent)")
                            try? fm.removeItem(at: file)
                        }
                    }
                }
            }
        }
    }

    /// Surgically syncs a single song folder. Much faster for incremental updates.
    func syncSingleSong(folderName rawFolderName: String) {
        let folderName = rawFolderName.precomposedStringWithCanonicalMapping
        guard let ctx = modelContext else { return }
        let fm = FileManager.default
        guard let docs = fm.urls(for: FileManager.SearchPathDirectory.documentDirectory, in: FileManager.SearchPathDomainMask.userDomainMask).first else { return }
        let songFolder = docs.appendingPathComponent("Songs").appendingPathComponent(folderName)

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: songFolder.path, isDirectory: &isDir), isDir.boolValue else { return }

        guard let contents = try? fm.contentsOfDirectory(at: songFolder, includingPropertiesForKeys: nil) else { return }

        print("[DEBUG] DataManager: Syncing folder '\(folderName)' (\(contents.count) files found)")
        let audioExts = ["mp3", "wav", "m4a", "aac", "flac"]
        let imageExts = ["jpg", "jpeg", "png", "webp"]
        let subExts = ["vtt", "srv1", "txt"]

        let audioFile = contents.first { audioExts.contains($0.pathExtension.lowercased()) }
        let coverFile = contents.first { imageExts.contains($0.pathExtension.lowercased()) }
        let subtitleFile = contents.first { subExts.contains($0.pathExtension.lowercased()) }

        guard let audio = audioFile else { return }

        let audioRelPath = "Songs/\(folderName)/\(audio.lastPathComponent)"
        let coverRelPath = coverFile != nil ? "Songs/\(folderName)/\(coverFile!.lastPathComponent)" : nil
        let subtitleRelPath = subtitleFile != nil ? "Songs/\(folderName)/\(subtitleFile!.lastPathComponent)" : nil

        let descriptor = FetchDescriptor<SongData>(predicate: #Predicate { $0.id == folderName })
        if let existing = (try? ctx.fetch(descriptor))?.first {
            if existing.audioFilePath != audioRelPath { existing.audioFilePath = audioRelPath }
            if existing.coverImagePath != coverRelPath { existing.coverImagePath = coverRelPath }
            if existing.subtitleFilePath != subtitleRelPath { existing.subtitleFilePath = subtitleRelPath }
        } else {
            let song = SongData(
                id: folderName,
                title: folderName,
                audioFilePath: audioRelPath,
                coverImagePath: coverRelPath,
                subtitleFilePath: subtitleRelPath
            )
            ctx.insert(song)
        }
        try? ctx.save()
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

    // MARK: - Convert SongData → Song (lightweight struct for player)
    func toSong(_ data: SongData) -> Song {
        Song.from(data)
    }

    func toSongs(_ dataArray: [SongData]) -> [Song] {
        dataArray.map { Song.from($0) }
    }
}

