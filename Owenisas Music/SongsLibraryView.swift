import SwiftUI

extension Notification.Name {
    /// Posted by MusicPlayerManager when a track finishes
    static let audioFinished = Notification.Name("AudioFinished")
}

struct SongsLibraryView: View {
    @State private var songs: [Song] = []
    @ObservedObject private var playerManager = MusicPlayerManager.shared

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                if songs.isEmpty {
                    Text("No songs found.\nPlease add song folders to the 'Songs' folder in Files.")
                        .multilineTextAlignment(.center)
                        .padding()
                } else {
                    List(songs) { song in
                        SongRow(song: song)
                    }
                }
            }
            .navigationTitle("My Music Library")
            .onAppear {
                loadSongs()
            }
            // Listen for the end‑of‑song notification and play the next one
            .onReceive(NotificationCenter.default.publisher(for: .audioFinished)) { _ in
                playNextSong()
            }
        }
    }

    /// Loads songs from the Documents/Songs folder (no autoplay here)
    func loadSongs() {
        let fileManager = FileManager.default

        // 1. Documents directory
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            print("Documents directory not found")
            return
        }

        // 2. Songs folder
        let songsFolderURL = documentsURL.appendingPathComponent("Songs")
        if !fileManager.fileExists(atPath: songsFolderURL.path) {
            do {
                try fileManager.createDirectory(
                    at: songsFolderURL,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                print("Created Songs folder at \(songsFolderURL.path)")
            } catch {
                print("Could not create Songs folder: \(error)")
                return
            }
        }

        // 3. Enumerate subfolders
        do {
            let subfolders = try fileManager.contentsOfDirectory(
                at: songsFolderURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            var loadedSongs: [Song] = []
            for folder in subfolders {
                var isDir: ObjCBool = false
                if fileManager.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue {
                    if let song = try processSongFolder(folder) {
                        loadedSongs.append(song)
                    }
                }
            }

            // Update state on main thread
            DispatchQueue.main.async {
                self.songs = loadedSongs
            }
        } catch {
            print("Error enumerating songs folder: \(error)")
        }
    }

    /// Finds audio & cover inside a song folder
    func processSongFolder(_ folderURL: URL) throws -> Song? {
        let fileManager = FileManager.default
        let contents = try fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: nil
        )

        let audioExtensions = ["mp3", "wav", "m4a"]
        let imageExtensions = ["jpg", "jpeg", "png"]

        var audioURL: URL?
        var coverURL: URL?

        for file in contents {
            let ext = file.pathExtension.lowercased()
            if audioExtensions.contains(ext) {
                audioURL = file
            } else if imageExtensions.contains(ext) {
                coverURL = file
            }
        }

        if let audio = audioURL, let cover = coverURL {
            let title = folderURL.lastPathComponent
            return Song(title: title, audioFileURL: audio, coverImageURL: cover)
        } else {
            print("Folder \(folderURL.lastPathComponent) missing audio or cover")
            return nil
        }
    }

    /// Plays the next song in the list, if any
    func playNextSong() {
        guard let current = playerManager.currentSong,
              let index = songs.firstIndex(where: { $0.id == current.id }),
              index + 1 < songs.count
        else { return }
        let next = songs[index + 1]
        playerManager.play(song: next)
    }
}

