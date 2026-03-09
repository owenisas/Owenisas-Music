import SwiftUI

struct DownloadView: View {
    @State private var youtubeLink = ""
    @State private var isDownloading = false
    @State private var statusMessage = ""
    @State private var downloadProgress: Double = 0
    @State private var downloadedCount = 0
    @State private var totalCount = 0
    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @FocusState private var linkFieldIsFocused: Bool

    @ObservedObject var dataManager = DataManager.shared

    private let baseURL = "https://owenisas.pythonanywhere.com"

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.green, .blue],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    Text("Download Music")
                        .font(.title2.bold())

                    Text("Paste a YouTube link or playlist URL")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 20)

                // Input field
                HStack(spacing: 10) {
                    Image(systemName: "link")
                        .foregroundStyle(.secondary)

                    TextField("YouTube link or playlist URL", text: $youtubeLink)
                        .textFieldStyle(.plain)
                        .focused($linkFieldIsFocused)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    if !youtubeLink.isEmpty {
                        Button {
                            youtubeLink = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(UIColor.secondarySystemBackground))
                )
                .padding(.horizontal, 16)

                // Paste from clipboard
                Button {
                    if let clip = UIPasteboard.general.string {
                        youtubeLink = clip
                    }
                } label: {
                    Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                }

                // Download status
                if isDownloading {
                    VStack(spacing: 12) {
                        ProgressView(value: downloadProgress, total: 1.0)
                            .tint(.green)
                            .animation(.easeInOut, value: downloadProgress)

                        Text(statusMessage)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)

                        if totalCount > 1 {
                            Text("\(downloadedCount)/\(totalCount) tracks")
                                .font(.caption.bold())
                                .foregroundStyle(.green)
                        }
                    }
                    .padding(.horizontal, 16)
                }

                // Download button
                Button(action: startDownload) {
                    HStack {
                        if isDownloading {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "arrow.down.circle.fill")
                        }
                        Text(isDownloading ? "Downloading…" : "Download")
                            .font(.headline)
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(canDownload ? .green : .gray.opacity(0.3))
                    )
                }
                .disabled(!canDownload)
                .padding(.horizontal, 16)

                // Tips section
                VStack(alignment: .leading, spacing: 12) {
                    Text("Supported Links")
                        .font(.subheadline.bold())

                    tipRow(icon: "play.rectangle.fill", text: "Single YouTube video")
                    tipRow(icon: "list.bullet.rectangle.fill", text: "YouTube playlist URL")
                    tipRow(icon: "music.note", text: "YouTube Music links")
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(UIColor.secondarySystemBackground))
                )
                .padding(.horizontal, 16)

                Spacer().frame(height: 100)
            }
        }
        .background(Color(UIColor.systemBackground))
        .navigationTitle("Download")
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { linkFieldIsFocused = false }
            }
        }
        .alert(alertTitle, isPresented: $showAlert) {
            Button("OK") { }
            if alertTitle.contains("Error") {
                Button("Retry") { startDownload() }
            }
        } message: {
            Text(alertMessage)
        }
        .onTapGesture {
            linkFieldIsFocused = false
        }
    }

    private var canDownload: Bool {
        !isDownloading && !youtubeLink.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func tipRow(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.green)
                .frame(width: 24)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Download Logic

    func startDownload() {
        let link = youtubeLink.trimmingCharacters(in: .whitespaces)
        guard !link.isEmpty else { return }

        linkFieldIsFocused = false
        isDownloading = true
        downloadProgress = 0
        downloadedCount = 0
        totalCount = 0

        // Check if it's a playlist link
        if isPlaylistLink(link) {
            statusMessage = "🔍 Fetching playlist info…"
            fetchPlaylistInfo(link: link)
        } else if let videoId = extractVideoId(from: link) {
            statusMessage = "🔍 Fetching video info…"
            totalCount = 1
            fetchAndDownloadSingle(videoId: videoId)
        } else {
            showError("Invalid URL", "Please paste a valid YouTube link.")
            isDownloading = false
        }
    }

    // MARK: - Single Video Download

    func fetchAndDownloadSingle(videoId: String) {
        let infoURL = URL(string: "\(baseURL)/info?id=\(videoId)")!
        URLSession.shared.dataTask(with: infoURL) { data, _, error in
            if let error = error {
                showError("Network Error", error.localizedDescription)
                return
            }
            guard let data = data,
                  let meta = try? JSONDecoder().decode(VideoInfo.self, from: data)
            else {
                showError("Parse Error", "Failed to parse video metadata.")
                return
            }

            let safeTitle = meta.title.replacingOccurrences(of: "/", with: "-")
            DispatchQueue.main.async {
                statusMessage = "🎶 Downloading \"\(safeTitle)\"…"
                downloadProgress = 0.2
            }

            // Download cover
            guard let coverURL = URL(string: meta.coverUrl) else {
                showError("Error", "Invalid cover URL")
                return
            }
            download(from: coverURL) { localCover in
                DispatchQueue.main.async { downloadProgress = 0.4 }

                // Download audio
                guard let audioURL = URL(string: meta.audioUrl) else {
                    showError("Error", "Invalid audio URL")
                    return
                }
                DispatchQueue.main.async {
                    statusMessage = "🎵 Downloading audio…"
                }
                download(from: audioURL) { localAudio in
                    DispatchQueue.main.async { downloadProgress = 0.8 }

                    // Check for subtitles
                    let subURL = meta.subtitleUrls?.first(where: { $0.key == "en" })?.value ?? meta.subtitleUrls?.first?.value
                    if let subURLStr = subURL, let parsedSubURL = URL(string: subURLStr) {
                        DispatchQueue.main.async {
                            statusMessage = "💬 Downloading subtitles…"
                        }
                        self.download(from: parsedSubURL) { localSubtitle in
                            finishSave(title: safeTitle, meta: meta, cover: localCover, audio: localAudio, subtitle: localSubtitle)
                        }
                    } else {
                        finishSave(title: safeTitle, meta: meta, cover: localCover, audio: localAudio, subtitle: nil)
                    }
                }
            }
        }.resume()
    }

    private func finishSave(title: String, meta: VideoInfo, cover: URL, audio: URL, subtitle: URL?) {
        do {
            try saveSongFiles(title: title, meta: meta, localCover: cover, localAudio: audio, localSubtitle: subtitle)
            DispatchQueue.main.async {
                downloadProgress = 1.0
                downloadedCount += 1
                if isPlaylistLink(youtubeLink) {
                    // This was single download from invalid playlist link fallback.
                    finishSuccess("✅ \"\(title)\" downloaded!")
                } else {
                    finishSuccess("✅ \"\(title)\" downloaded!")
                }
            }
        } catch {
            showError("Save Error", error.localizedDescription)
        }
    }

    // MARK: - Playlist Download

    func isPlaylistLink(_ link: String) -> Bool {
        link.contains("list=") || link.contains("/playlist")
    }

    func fetchPlaylistInfo(link: String) {
        // Extract playlist ID
        guard let playlistId = extractPlaylistId(from: link) else {
            showError("Invalid URL", "Could not extract playlist ID.")
            return
        }

        let infoURL = URL(string: "\(baseURL)/playlist-info?id=\(playlistId)")!
        URLSession.shared.dataTask(with: infoURL) { data, _, error in
            if let error = error {
                // Fallback: try as single video if playlist endpoint doesn't exist
                if let videoId = extractVideoId(from: link) {
                    DispatchQueue.main.async {
                        statusMessage = "Playlist endpoint unavailable, downloading single…"
                        totalCount = 1
                    }
                    fetchAndDownloadSingle(videoId: videoId)
                } else {
                    showError("Network Error", error.localizedDescription)
                }
                return
            }
            guard let data = data,
                  let playlist = try? JSONDecoder().decode(PlaylistInfo.self, from: data)
            else {
                // Fallback to single video
                if let videoId = extractVideoId(from: link) {
                    DispatchQueue.main.async {
                        statusMessage = "Downloading single track…"
                        totalCount = 1
                    }
                    fetchAndDownloadSingle(videoId: videoId)
                } else {
                    showError("Parse Error", "Failed to parse playlist data.")
                }
                return
            }

            DispatchQueue.main.async {
                totalCount = playlist.videos.count
                statusMessage = "📋 Found \(totalCount) tracks in \"\(playlist.title)\""
            }

            // Download each track sequentially
            downloadPlaylistTracks(playlist.videos, index: 0)
        }.resume()
    }

    func downloadPlaylistTracks(_ videos: [VideoInfo], index: Int) {
        guard index < videos.count else {
            DispatchQueue.main.async {
                finishSuccess("✅ Playlist download complete! (\(downloadedCount) tracks)")
            }
            return
        }

        let meta = videos[index]
        let safeTitle = meta.title.replacingOccurrences(of: "/", with: "-")

        DispatchQueue.main.async {
            statusMessage = "⬇️ (\(index+1)/\(videos.count)) \"\(safeTitle)\""
            downloadProgress = Double(index) / Double(videos.count)
        }

        guard let coverURL = URL(string: meta.coverUrl),
              let audioURL = URL(string: meta.audioUrl)
        else {
            // Skip this track and continue
            downloadPlaylistTracks(videos, index: index + 1)
            return
        }

        download(from: coverURL) { localCover in
            download(from: audioURL) { localAudio in
                let subURLStr = meta.subtitleUrls?.first(where: { $0.key == "en" })?.value ?? meta.subtitleUrls?.first?.value
                if let subURLStr = subURLStr, let parsedSubURL = URL(string: subURLStr) {
                    self.download(from: parsedSubURL) { localSubtitle in
                        do {
                            try self.saveSongFiles(title: safeTitle, meta: meta, localCover: localCover, localAudio: localAudio, localSubtitle: localSubtitle)
                            DispatchQueue.main.async {
                                self.downloadedCount += 1
                            }
                        } catch {
                            print("Failed to save \(safeTitle): \(error)")
                        }
                        // Continue to next track
                        self.downloadPlaylistTracks(videos, index: index + 1)
                    }
                } else {
                    do {
                        try self.saveSongFiles(title: safeTitle, meta: meta, localCover: localCover, localAudio: localAudio, localSubtitle: nil)
                        DispatchQueue.main.async {
                            self.downloadedCount += 1
                        }
                    } catch {
                        print("Failed to save \(safeTitle): \(error)")
                    }
                    // Continue to next track
                    self.downloadPlaylistTracks(videos, index: index + 1)
                }
            }
        }
    }

    // MARK: - Helpers

    struct VideoInfo: Decodable {
        let title: String
        let artist: String?
        let album: String?
        let duration: Double?
        let audioUrl: String
        let coverUrl: String
        let subtitleUrls: [String: String]?
    }

    struct PlaylistInfo: Decodable {
        let title: String
        let artist: String?
        let videos: [VideoInfo]
    }

    func saveSongFiles(title: String, meta: VideoInfo, localCover: URL, localAudio: URL, localSubtitle: URL?) throws {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let songsFolder = docs.appendingPathComponent("Songs", isDirectory: true)
        try fm.createDirectory(at: songsFolder, withIntermediateDirectories: true)

        let songDir = songsFolder.appendingPathComponent(title, isDirectory: true)
        try fm.createDirectory(at: songDir, withIntermediateDirectories: true)

        let destCover = songDir.appendingPathComponent("\(title).jpg")
        let destAudio = songDir.appendingPathComponent("\(title).mp3")

        if fm.fileExists(atPath: destCover.path) { try fm.removeItem(at: destCover) }
        if fm.fileExists(atPath: destAudio.path) { try fm.removeItem(at: destAudio) }

        try fm.moveItem(at: localCover, to: destCover)
        try fm.moveItem(at: localAudio, to: destAudio)

        if let localSubtitle = localSubtitle {
            let destSubtitle = songDir.appendingPathComponent("\(title).vtt")
            if fm.fileExists(atPath: destSubtitle.path) { try fm.removeItem(at: destSubtitle) }
            try fm.moveItem(at: localSubtitle, to: destSubtitle)
        }

        // Update SwiftData with artist/album metadata
        DispatchQueue.main.async {
            dataManager.syncFromFileSystem()
            // Find the newly created song and update its metadata
            let allSongs = dataManager.fetchAllSongs()
            if let songData = allSongs.first(where: { $0.id == title }) {
                songData.artist = meta.artist ?? "Unknown Artist"
                songData.albumTitle = meta.album ?? ""
                songData.duration = meta.duration ?? 0
                try? dataManager.modelContext?.save()
            }
        }
    }

    func finishSuccess(_ message: String) {
        statusMessage = message
        isDownloading = false
        youtubeLink = ""
        // Sync with SwiftData
        dataManager.syncFromFileSystem()
        NotificationCenter.default.post(name: .init("SongsFolderChanged"), object: nil)

        // Haptic feedback
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
    }

    func showError(_ title: String, _ message: String) {
        DispatchQueue.main.async {
            alertTitle = title
            alertMessage = message
            showAlert = true
            isDownloading = false
        }
    }

    func extractVideoId(from link: String) -> String? {
        let patterns = [
            "(?<=v=)[\\w-]+",
            "(?<=be/)[\\w-]+",
            "(?<=embed/)[\\w-]+",
            "(?<=shorts/)[\\w-]+"
        ]
        for p in patterns {
            if let regex = try? NSRegularExpression(pattern: p, options: .caseInsensitive) {
                let range = NSRange(location: 0, length: link.utf16.count)
                if let match = regex.firstMatch(in: link, options: [], range: range) {
                    return (link as NSString).substring(with: match.range)
                }
            }
        }
        return nil
    }

    func extractPlaylistId(from link: String) -> String? {
        let pattern = "(?<=list=)[\\w-]+"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(location: 0, length: link.utf16.count)
        guard let match = regex.firstMatch(in: link, options: [], range: range) else { return nil }
        return (link as NSString).substring(with: match.range)
    }

    func download(from url: URL, completion: @escaping (URL) -> Void) {
        URLSession.shared.downloadTask(with: url) { tmp, _, err in
            if let tmp = tmp {
                completion(tmp)
            } else {
                showError("Download Failed", err?.localizedDescription ?? "Unknown error")
            }
        }.resume()
    }
}
