import SwiftUI
import UniformTypeIdentifiers

struct DownloadView: View {
    @State private var youtubeLink = ""
    @State private var isDownloading = false
    @State private var statusMessage = ""
    @FocusState private var linkFieldIsFocused: Bool
    var body: some View {
        VStack(spacing: 20) {
            TextField("Paste YouTube link here", text: $youtubeLink)
                .textFieldStyle(.roundedBorder)
                .padding()
                .focused($linkFieldIsFocused)
                .toolbar{
                    ToolbarItemGroup (placement: .keyboard){
                        Spacer()
                        Button("Done"){
                            linkFieldIsFocused = false
                        }
                    }
                }

            if isDownloading {
                ProgressView()
                Text(statusMessage)
            }

            Button(action: startDownload) {
                Label("Download Song", systemImage: "arrow.down.circle")
            }
            .disabled(isDownloading || (extractVideoId(from: youtubeLink)?.isEmpty ?? true))
            .buttonStyle(.borderedProminent)
            .padding()
            .onTapGesture {
                linkFieldIsFocused = false
            }
        }
        .navigationTitle("Download from YouTube")
        .padding()
    }

    /// 1. Kick off by fetching metadata via /info?id=<videoId>
    func startDownload() {
        guard let videoId = extractVideoId(from: youtubeLink) else {
            statusMessage = "Invalid YouTube URL"
            return
        }
        isDownloading = true
        statusMessage = "🔍 Fetching metadata…"

        // 1a. Call /info route on local server
        let infoURL = URL(string: "https://owenisas.pythonanywhere.com/info?id=\(videoId)")!
        URLSession.shared.dataTask(with: infoURL) { data, _, error in
            if let error = error {
                finish(error: "Metadata error: \(error.localizedDescription)")
                return
            }
            guard let data = data,
                  let meta = try? JSONDecoder().decode(VideoInfo.self, from: data)
            else {
                finish(error: "Failed to parse metadata")
                return
            }

            // Use the title from metadata (sanitize for filesystem)
            let safeTitle = meta.title.replacingOccurrences(
                of: "/", with: "-"
            )
            DispatchQueue.main.async { statusMessage = "🎶 Downloading cover…" }

            // 2. Download cover from meta.coverUrl
            guard let coverURL = URL(string: meta.coverUrl) else {
                finish(error: "Invalid cover URL")
                return
            }
            download(from: coverURL) { localCover in
                DispatchQueue.main.async { statusMessage = "🎵 Downloading audio…" }

                // 3. Download audio from meta.audioUrl
                guard let audioURL = URL(string: meta.audioUrl) else {
                    finish(error: "Invalid audio URL")
                    return
                }
                download(from: audioURL) { localAudio in
                    // 4. Save both into Documents/Songs/<safeTitle>/
                    do {
                        let fm = FileManager.default
                        let docs = fm.urls(
                            for: .documentDirectory, in: .userDomainMask
                        ).first!
                        let songsFolder = docs.appendingPathComponent("Songs", isDirectory: true)
                        try fm.createDirectory(
                            at: songsFolder,
                            withIntermediateDirectories: true,
                            attributes: nil
                        )

                        let songDir = songsFolder.appendingPathComponent(safeTitle, isDirectory: true)
                        try fm.createDirectory(at: songDir, withIntermediateDirectories: true)

                        let destCover = songDir.appendingPathComponent("\(safeTitle).jpg")
                        let destAudio = songDir.appendingPathComponent("\(safeTitle).mp3")

                        if fm.fileExists(atPath: destCover.path) {
                            try fm.removeItem(at: destCover)
                        }
                        if fm.fileExists(atPath: destAudio.path) {
                            try fm.removeItem(at: destAudio)
                        }

                        try fm.moveItem(at: localCover, to: destCover)
                        try fm.moveItem(at: localAudio, to: destAudio)

                        finish(success: "✅ “\(safeTitle)” downloaded!")
                    } catch {
                        finish(error: "Save error: \(error.localizedDescription)")
                    }
                }
            }
        }.resume()
    }

    // MARK: — Helpers —

    /// Decodeable struct matching your /info JSON
    struct VideoInfo: Decodable {
        let title: String
        let audioUrl: String
        let coverUrl: String
    }

    /// Clean up on finish (success or error)
    func finish(success: String? = nil, error: String? = nil) {
        DispatchQueue.main.async {
            statusMessage = success ?? "❌ \(error!)"
            isDownloading = false
            if success != nil{
                youtubeLink = ""
            }
            NotificationCenter.default
                .post(name: .init("SongsFolderChanged"), object: nil)
        }
    }

    /// Extracts YouTube video ID via regex
    func extractVideoId(from link: String) -> String? {
        let pattern =
            "((?<=(v|V)/)|(?<=be/)|(?<=(\\?|\\&)v=)|(?<=embed/))([\\w-]++)"
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: .caseInsensitive
        ) else { return nil }
        let range = NSRange(location: 0, length: link.utf16.count)
        guard let match = regex.firstMatch(in: link, options: [], range: range)
        else { return nil }
        return (link as NSString).substring(with: match.range)
    }

    /// Generic download-to-temp helper
    func download(from url: URL, completion: @escaping (URL) -> Void) {
        URLSession.shared.downloadTask(with: url) { tmp, _, err in
            if let tmp = tmp {
                completion(tmp)
            } else {
                finish(error: err?.localizedDescription ?? "Download failed")
            }
        }.resume()
    }
}

#Preview("DownloadView with /info") {
    DownloadView()
}
