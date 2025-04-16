import SwiftUI

struct ContentView: View {
    var body: some View {
        SongsLibraryView()
            .onAppear {
                createSongsFolderIfNeeded()
            }
    }
    
    func createSongsFolderIfNeeded() {
        let fileManager = FileManager.default
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            print("Documents directory not found")
            return
        }
        
        let songsFolderURL = documentsURL.appendingPathComponent("Songs")
        if !fileManager.fileExists(atPath: songsFolderURL.path) {
            do {
                try fileManager.createDirectory(at: songsFolderURL, withIntermediateDirectories: true, attributes: nil)
                print("Created Songs folder at \(songsFolderURL.path)")
            } catch {
                print("Error creating Songs folder: \(error)")
            }
        } else {
            print("Songs folder already exists at \(songsFolderURL.path)")
        }
    }
}

#Preview("ContentView Preview") {
    ContentView()
}
