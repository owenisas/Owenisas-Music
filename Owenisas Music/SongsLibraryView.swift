import SwiftUI

struct SongsLibraryView: View {
    @State private var songs: [Song] = []
    
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
        }
    }
    
    /// Load songs by enumerating subfolders within the designated "Songs" folder.
    func loadSongs() {
        let fileManager = FileManager.default
        
        // Get the app's Documents directory.
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            print("Documents directory not found")
            return
        }
        
        // Define the "Songs" folder inside Documents.
        let songsFolderURL = documentsURL.appendingPathComponent("Songs")
        
        // Create the Songs folder if it doesn't exist.
        if !fileManager.fileExists(atPath: songsFolderURL.path) {
            do {
                try fileManager.createDirectory(at: songsFolderURL, withIntermediateDirectories: true, attributes: nil)
                print("Created Songs folder at \(songsFolderURL.path)")
            } catch {
                print("Could not create Songs folder: \(error)")
                return
            }
        }
        
        // Enumerate subfolders.
        do {
            let subfolders = try fileManager.contentsOfDirectory(at: songsFolderURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            var loadedSongs: [Song] = []
            for folder in subfolders {
                var isDir: ObjCBool = false
                if fileManager.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue {
                    if let song = try processSongFolder(folder) {
                        loadedSongs.append(song)
                    }
                }
            }
            
            // Update the state on the main thread.
            DispatchQueue.main.async {
                self.songs = loadedSongs
                // Autoplay the first song if available and none is playing.
                if let firstSong = loadedSongs.first, !MusicPlayerManager.shared.isPlaying {
                    MusicPlayerManager.shared.play(song: firstSong)
                }
            }
        } catch {
            print("Error enumerating songs folder: \(error)")
        }
    }
    
    /// Process a song folder to look for an audio file and a cover image.
    func processSongFolder(_ folderURL: URL) throws -> Song? {
        let fileManager = FileManager.default
        let contents = try fileManager.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)
        
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
        
        if let audioURL = audioURL, let coverURL = coverURL {
            let title = folderURL.lastPathComponent
            return Song(title: title, audioFileURL: audioURL, coverImageURL: coverURL)
        } else {
            print("Folder \(folderURL.lastPathComponent) is missing an audio file or cover image")
            return nil
        }
    }
}

#Preview("SongsLibraryView Preview") {
    SongsLibraryView()
}
