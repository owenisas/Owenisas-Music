import SwiftUI
import UserNotifications

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
    
    @State private var targetPlaylistName: String? = nil
    @State private var targetPlaylistCover: String? = nil
    @State private var downloadedTrackTitles: [String] = []
    
    @State private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    @ObservedObject var dataManager = DataManager.shared

    private let baseURL = "https://owenisas.pythonanywhere.com"

    private static let urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300 // 5 minutes (for large playlists)
        config.timeoutIntervalForResource = 3600 // 1 hour background tolerance
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }()

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
        targetPlaylistName = nil
        targetPlaylistCover = nil
        downloadedTrackTitles = []

        // Request notification auth
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        
        // Start background task bound to download process
        backgroundTask = UIApplication.shared.beginBackgroundTask {
            UIApplication.shared.endBackgroundTask(self.backgroundTask)
            self.backgroundTask = .invalid
        }

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

    func fetchAndDownloadSingle(videoId: String, retries: Int = 2) {
        let infoURL = URL(string: "\(baseURL)/info?id=\(videoId)")!
        Self.urlSession.dataTask(with: infoURL) { data, _, error in
            if let error = error {
                if retries > 0 {
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                        self.fetchAndDownloadSingle(videoId: videoId, retries: retries - 1)
                    }
                } else {
                    showError("Network Error", error.localizedDescription)
                }
                return
            }
            guard let data = data,
                  let meta = try? JSONDecoder().decode(VideoInfo.self, from: data)
            else {
                showError("Parse Error", "Failed to parse video metadata.")
                return
            }

            let safeTitle = meta.title.replacingOccurrences(of: "/", with: "-")
            let safeArtist = (meta.artist ?? "Unknown Artist").replacingOccurrences(of: "/", with: "-")
            let safeIdentifier = "\(safeArtist) - \(safeTitle)"
            
            DispatchQueue.main.async {
                self.statusMessage = "🎶 Downloading \"\(safeTitle)\"…"
                self.downloadProgress = 0.2
                self.sendProgressNotification(message: "Downloading: \(safeTitle)")
            }

            let existingSongs = self.dataManager.fetchAllSongs()
            if existingSongs.contains(where: { $0.title == meta.title && $0.artist == (meta.artist ?? "Unknown Artist") }) {
                DispatchQueue.main.async {
                    self.finishSuccess("✅ \"\(safeTitle)\" already exists in library!")
                }
                return
            }

            guard let audioURL = URL(string: meta.audioUrl) else {
                showError("Error", "Invalid audio URL")
                return
            }
            
            let coverURLStr = meta.coverUrl.isEmpty ? nil : meta.coverUrl
            let coverURL = coverURLStr != nil ? URL(string: coverURLStr!) : nil

            // Download audio
            let continueWithAudio = { (localCover: URL?) in
                self.download(from: audioURL) { localAudio in
                    DispatchQueue.main.async { self.downloadProgress = 0.8 }
                    guard let localAudio = localAudio else { return }

                    // Download YouTube subtitle tracks
                    let ytSubs = meta.subtitleUrls?.filter({ $0.key != "lyrics" }) ?? [:]

                    let saveWithLyrics = { (ytDownloaded: [(lang: String, url: URL)]) in
                        // Also try LRCLIB for high-quality synced lyrics
                        DispatchQueue.main.async {
                            self.statusMessage = "🎵 Fetching synced lyrics…"
                        }
                        self.fetchLRCLIBLyrics(title: meta.title, artist: meta.artist ?? "", album: meta.album ?? "", duration: meta.duration ?? 0) { lrcFile in
                            var allSubs = ytDownloaded
                            if let lrcFile = lrcFile {
                                allSubs.append((lang: "lyrics", url: lrcFile))
                            }
                            self.finishSave(title: safeIdentifier, meta: meta, cover: localCover, audio: localAudio, subtitles: allSubs)
                        }
                    }

                    if !ytSubs.isEmpty {
                        DispatchQueue.main.async {
                            self.statusMessage = "💬 Downloading subtitles (\(ytSubs.count) languages)…"
                        }
                        self.downloadAllSubtitles(ytSubs) { downloaded in
                            saveWithLyrics(downloaded)
                        }
                    } else {
                        saveWithLyrics([])
                    }
                }
            }

            if let validCoverURL = coverURL {
                download(from: validCoverURL) { localCover in
                    DispatchQueue.main.async { self.downloadProgress = 0.4 }
                    continueWithAudio(localCover)
                }
            } else {
                DispatchQueue.main.async { self.downloadProgress = 0.4 }
                continueWithAudio(nil)
            }
        }.resume()
    }

    private func finishSave(title: String, meta: VideoInfo, cover: URL?, audio: URL, subtitles: [(lang: String, url: URL)]) {
        do {
            try saveSongFiles(title: title, meta: meta, localCover: cover, localAudio: audio, localSubtitles: subtitles)
            DispatchQueue.main.async {
                downloadProgress = 1.0
                downloadedCount += 1
                downloadedTrackTitles.append(title)
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

    func fetchPlaylistInfo(link: String, retries: Int = 2) {
        let encodedLink = link.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? link
        let infoURL = URL(string: "\(baseURL)/playlist-info?url=\(encodedLink)")!
        Self.urlSession.dataTask(with: infoURL) { data, _, error in
            if let error = error {
                if retries > 0 {
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                        self.fetchPlaylistInfo(link: link, retries: retries - 1)
                    }
                } else {
                    // Fallback: try as single video if playlist endpoint continues failing
                    if let videoId = extractVideoId(from: link) {
                        DispatchQueue.main.async {
                            statusMessage = "Playlist endpoint unavailable, downloading single…"
                            totalCount = 1
                        }
                        fetchAndDownloadSingle(videoId: videoId)
                    } else {
                        showError("Network Error", error.localizedDescription)
                    }
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
                targetPlaylistName = playlist.title
                targetPlaylistCover = playlist.coverUrl
            }

            // Download each track sequentially
            downloadPlaylistTracks(playlist.videos, index: 0)
        }.resume()
    }

    func downloadPlaylistTracks(_ videos: [VideoInfo], index: Int) {
        guard index < videos.count else {
            DispatchQueue.main.async {
                self.createAutoPlaylist()
                self.finishSuccess("✅ Playlist download complete! (\(self.downloadedCount) tracks)")
            }
            return
        }

        let meta = videos[index]
        let safeTitle = meta.title.replacingOccurrences(of: "/", with: "-")
        let safeArtist = (meta.artist ?? "Unknown Artist").replacingOccurrences(of: "/", with: "-")
        let safeIdentifier = "\(safeArtist) - \(safeTitle)"

        DispatchQueue.main.async {
            statusMessage = "⬇️ (\(index+1)/\(videos.count)) \"\(safeTitle)\""
            downloadProgress = Double(index) / Double(videos.count)
            self.sendProgressNotification(message: "Downloading \(index+1) of \(videos.count)\n\(safeTitle)")
        }

        // Check if the song has already been downloaded (skip duplicate downloads)
        let existingSongs = dataManager.fetchAllSongs()
        if existingSongs.contains(where: { $0.title == meta.title && $0.artist == (meta.artist ?? "Unknown Artist") }) {
            DispatchQueue.main.async {
                self.downloadedCount += 1
                self.downloadedTrackTitles.append(safeIdentifier)
            }
            // Skip and move to next track
            self.downloadPlaylistTracks(videos, index: index + 1)
            return
        }

        guard let audioURL = URL(string: meta.audioUrl) else {
            // Skip this track and continue
            DispatchQueue.main.async {
                self.downloadedTrackTitles.append(safeIdentifier)
            }
            downloadPlaylistTracks(videos, index: index + 1)
            return
        }

        // Try track cover first, fallback to playlist cover, then nil
        var finalCoverStr: String? = nil
        if !meta.coverUrl.isEmpty {
            finalCoverStr = meta.coverUrl
        } else if let pCover = targetPlaylistCover, !pCover.isEmpty {
            finalCoverStr = pCover
        }
        
        let coverURL = finalCoverStr != nil ? URL(string: finalCoverStr!) : nil

        let continueWithAudio = { (localCover: URL?) in
            self.download(from: audioURL) { localAudio in
                guard let localAudio = localAudio else {
                    // Audio failed, skip this track gracefully!
                    self.downloadPlaylistTracks(videos, index: index + 1)
                    return
                }
                
                let subURLStr = self.bestSubtitleURL(from: meta)
                if let subURLStr = subURLStr, let parsedSubURL = URL(string: subURLStr) {
                    self.download(from: parsedSubURL) { localSubtitle in
                        let subs: [(lang: String, url: URL)] = localSubtitle != nil
                            ? [(lang: meta.language ?? "und", url: localSubtitle!)]
                            : []
                        do {
                            try self.saveSongFiles(title: safeIdentifier, meta: meta, localCover: localCover, localAudio: localAudio, localSubtitles: subs)
                            DispatchQueue.main.async {
                                self.downloadedCount += 1
                                self.downloadedTrackTitles.append(safeIdentifier)
                            }
                        } catch {
                            print("Failed to save \(safeIdentifier): \(error)")
                        }
                        self.downloadPlaylistTracks(videos, index: index + 1)
                    }
                } else {
                    do {
                        try self.saveSongFiles(title: safeIdentifier, meta: meta, localCover: localCover, localAudio: localAudio, localSubtitles: [])
                        DispatchQueue.main.async {
                            self.downloadedCount += 1
                            self.downloadedTrackTitles.append(safeIdentifier)
                        }
                    } catch {
                        print("Failed to save \(safeIdentifier): \(error)")
                    }
                    self.downloadPlaylistTracks(videos, index: index + 1)
                }
            }
        }

        if let validCoverURL = coverURL {
            download(from: validCoverURL) { localCover in
                continueWithAudio(localCover)
            }
        } else {
            continueWithAudio(nil)
        }
    }

    // MARK: - Helpers

    private func createAutoPlaylist() {
        guard let pName = targetPlaylistName, !pName.isEmpty, !downloadedTrackTitles.isEmpty else { return }
        
        dataManager.syncFromFileSystem() // Ensure files are loaded
        let allSongs = dataManager.fetchAllSongs()
        
        let matchingSongs = allSongs.filter { downloadedTrackTitles.contains($0.id) }
        guard !matchingSongs.isEmpty else { return }
        
        // Pick the first downloaded song's cover to represent the playlist locally
        let firstSongCover = matchingSongs.first?.coverImagePath
        
        if let newPlaylist = dataManager.createPlaylist(title: pName, coverImagePath: firstSongCover) {
            for song in matchingSongs {
                dataManager.addSong(song, to: newPlaylist)
            }
        }
    }

    struct VideoInfo: Decodable {
        let title: String
        let artist: String?
        let album: String?
        let duration: Double?
        let language: String?
        let audioUrl: String
        let coverUrl: String
        let subtitleUrls: [String: String]?
    }

    /// Pick the best subtitle URL based on the video's original language.
    /// Priority: LRCLIB lyrics → original language → "en" → first available.
    func bestSubtitleURL(from meta: VideoInfo) -> String? {
        guard let subs = meta.subtitleUrls, !subs.isEmpty else { return nil }

        // 1. LRCLIB synced lyrics (highest quality)
        if let lyrics = subs["lyrics"] { return lyrics }

        // 2. Try video's original language (e.g. "ja" for a Japanese song)
        if let lang = meta.language, !lang.isEmpty, let url = subs[lang] {
            return url
        }

        // 3. Try original language with region prefix (e.g. "ja" matches "ja-JP")
        if let lang = meta.language, !lang.isEmpty {
            if let match = subs.first(where: { $0.key.hasPrefix(lang) }) {
                return match.value
            }
        }

        // 4. Fallback to English
        if let en = subs["en"] { return en }
        if let match = subs.first(where: { $0.key.hasPrefix("en") }) {
            return match.value
        }

        // 5. Last resort: first available
        return subs.first?.value
    }

    /// Download all subtitle tracks concurrently. Returns array of (language, local file URL).
    func downloadAllSubtitles(_ subs: [String: String], completion: @escaping ([(lang: String, url: URL)]) -> Void) {
        let group = DispatchGroup()
        var results: [(lang: String, url: URL)] = []
        let lock = NSLock()

        for (lang, urlStr) in subs {
            guard let url = URL(string: urlStr) else { continue }
            group.enter()
            download(from: url, retries: 1) { localFile in
                if let localFile = localFile {
                    lock.lock()
                    results.append((lang: lang, url: localFile))
                    lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            completion(results)
        }
    }

    // MARK: - LRCLIB Lyrics (client-side, bypasses PythonAnywhere whitelist)

    struct LRCLIBResponse: Decodable {
        let syncedLyrics: String?
        let plainLyrics: String?
    }

    /// Fetch synced lyrics from LRCLIB and convert to VTT. Returns a local temp file URL on success.
    func fetchLRCLIBLyrics(title: String, artist: String, album: String = "", duration: Double = 0, completion: @escaping (URL?) -> Void) {
        // Clean up auto-generated YouTube artist names
        let cleanArtist = artist.replacingOccurrences(of: " - Topic", with: "").trimmingCharacters(in: .whitespaces)

        // 1. Try exact match
        var components = URLComponents(string: "https://lrclib.net/api/get")!
        var queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: cleanArtist)
        ]
        if !album.isEmpty { queryItems.append(URLQueryItem(name: "album_name", value: album)) }
        if duration > 0 { queryItems.append(URLQueryItem(name: "duration", value: String(Int(duration)))) }
        components.queryItems = queryItems

        guard let url = components.url else { completion(nil); return }

        var request = URLRequest(url: url)
        request.setValue("OwenisasMusic/1.0 github.com/owenisas/Owenisas-Music", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let data = data, let result = try? JSONDecoder().decode(LRCLIBResponse.self, from: data) {
                if let synced = result.syncedLyrics, let vtt = self.lrcToVTT(synced) {
                    completion(self.writeVTTToTemp(vtt))
                    return
                }
                if let plain = result.plainLyrics {
                    let vtt = "WEBVTT\n\n00:00.000 --> 99:59.999\n" + plain
                    completion(self.writeVTTToTemp(vtt))
                    return
                }
            }

            // 2. Fallback: search
            self.searchLRCLIB(query: "\(cleanArtist) \(title)") { vttFile in
                completion(vttFile)
            }
        }.resume()
    }

    private func searchLRCLIB(query: String, completion: @escaping (URL?) -> Void) {
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]

        guard let url = components.url else { completion(nil); return }

        var request = URLRequest(url: url)
        request.setValue("OwenisasMusic/1.0 github.com/owenisas/Owenisas-Music", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data = data, let results = try? JSONDecoder().decode([LRCLIBResponse].self, from: data) else {
                completion(nil)
                return
            }

            // Pick first result with synced lyrics
            for r in results {
                if let synced = r.syncedLyrics, let vtt = self.lrcToVTT(synced) {
                    completion(self.writeVTTToTemp(vtt))
                    return
                }
            }
            // Plain lyrics as last resort
            if let first = results.first, let plain = first.plainLyrics {
                let vtt = "WEBVTT\n\n00:00.000 --> 99:59.999\n" + plain
                completion(self.writeVTTToTemp(vtt))
                return
            }
            completion(nil)
        }.resume()
    }

    /// Convert LRC format ([MM:SS.xx]text) to WebVTT format.
    private func lrcToVTT(_ lrc: String) -> String? {
        let lines = lrc.components(separatedBy: "\n")
        var entries: [(time: Double, text: String)] = []

        let pattern = /\[(\d+):(\d+)\.(\d+)\](.*)/
        for line in lines {
            guard let match = line.firstMatch(of: pattern) else { continue }
            let mins = Double(match.1) ?? 0
            let secs = Double(match.2) ?? 0
            let msStr = String(match.3)
            let ms = Double(msStr.padding(toLength: 3, withPad: "0", startingAt: 0).prefix(3)) ?? 0
            let text = String(match.4).trimmingCharacters(in: .whitespaces)
            if text.isEmpty { continue }
            entries.append((time: mins * 60 + secs + ms / 1000.0, text: text))
        }

        guard !entries.isEmpty else { return nil }

        var vtt = "WEBVTT\n\n"
        for (i, entry) in entries.enumerated() {
            let end = i + 1 < entries.count ? entries[i + 1].time : entry.time + 5.0
            vtt += "\(formatVTTTime(entry.time)) --> \(formatVTTTime(end))\n"
            vtt += "\(entry.text)\n\n"
        }
        return vtt
    }

    private func formatVTTTime(_ t: Double) -> String {
        let m = Int(t) / 60
        let s = t - Double(m * 60)
        return String(format: "%02d:%06.3f", m, s)
    }

    private func writeVTTToTemp(_ vtt: String) -> URL? {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".vtt")
        do {
            try vtt.write(to: tmp, atomically: true, encoding: .utf8)
            return tmp
        } catch {
            return nil
        }
    }

    struct PlaylistInfo: Decodable {
        let title: String
        let artist: String?
        let coverUrl: String?
        let videos: [VideoInfo]
    }

    func saveSongFiles(title: String, meta: VideoInfo, localCover: URL?, localAudio: URL, localSubtitles: [(lang: String, url: URL)]) throws {
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

        if let localCover = localCover, fm.fileExists(atPath: localCover.path) {
            // Convert to actual JPEG — downloaded files may be WebP/PNG despite .jpg extension
            if let imageData = try? Data(contentsOf: localCover),
               let uiImage = UIImage(data: imageData),
               let jpegData = uiImage.jpegData(compressionQuality: 0.9) {
                try jpegData.write(to: destCover)
                try? fm.removeItem(at: localCover) // clean up temp file
            } else {
                // Fallback: just move the file as-is
                try fm.moveItem(at: localCover, to: destCover)
            }
        }
        try fm.moveItem(at: localAudio, to: destAudio)

        // Save each subtitle track with language code: {title}.{lang}.vtt
        for sub in localSubtitles {
            let destSubtitle = songDir.appendingPathComponent("\(title).\(sub.lang).vtt")
            if fm.fileExists(atPath: destSubtitle.path) { try fm.removeItem(at: destSubtitle) }
            try fm.moveItem(at: sub.url, to: destSubtitle)
        }

        // Update SwiftData with artist/album metadata
        DispatchQueue.main.async {
            dataManager.syncSingleSong(folderName: title)
            // Find the newly created song and update its metadata
            let allSongs = dataManager.fetchAllSongs()
            if let songData = allSongs.first(where: { $0.id == title }) {
                songData.title = meta.title
                songData.artist = meta.artist ?? "Unknown Artist"
                songData.albumTitle = meta.album ?? ""
                songData.duration = meta.duration ?? 0
                try? dataManager.modelContext?.save()
            }
        }
    }

    func finishSuccess(_ message: String) {
        DispatchQueue.main.async {
            self.statusMessage = message
            self.isDownloading = false
            self.youtubeLink = ""
            // Sync with SwiftData
            self.dataManager.syncFromFileSystem()
            NotificationCenter.default.post(name: .init("SongsFolderChanged"), object: nil)

            // Haptic feedback
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
            
            self.sendCompletionNotification(message: message)
            self.endBackgroundTask()
        }
    }

    func showError(_ title: String, _ message: String) {
        DispatchQueue.main.async {
            alertTitle = title
            alertMessage = message
            showAlert = true
            isDownloading = false
            
            self.sendCompletionNotification(message: "Error: \(message)")
            self.endBackgroundTask()
        }
    }
    
    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
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

    func download(from url: URL, retries: Int = 3, completion: @escaping (URL?) -> Void) {
        Self.urlSession.downloadTask(with: url) { tmp, response, err in
            if let tmp = tmp, err == nil {
                // Move to a persistent temporary location immediately
                let fm = FileManager.default
                let cacheDir = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
                let persistentTempURL = cacheDir.appendingPathComponent(UUID().uuidString).appendingPathExtension(url.pathExtension)
                do {
                    try fm.moveItem(at: tmp, to: persistentTempURL)
                    completion(persistentTempURL)
                } catch {
                    print("Failed to save persistent temp file: \(error)")
                    completion(nil)
                }
            } else {
                if retries > 0 {
                    print("Retrying download... \(retries) left for \(url.lastPathComponent)")
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                        self.download(from: url, retries: retries - 1, completion: completion)
                    }
                } else {
                    self.showError("Download Failed", err?.localizedDescription ?? "Failed to fetch file.")
                    completion(nil)
                }
            }
        }.resume()
    }

    private func sendProgressNotification(message: String) {
        // Only send progress notifications for single downloads or every 5th track in a playlist to avoid spam
        if totalCount > 1 && downloadedCount % 5 != 0 { return }
        
        let content = UNMutableNotificationContent()
        content.title = "Music Download"
        content.body = message
        content.sound = nil // silent for progress updates
        
        let request = UNNotificationRequest(identifier: "download_progress", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
    
    private func sendCompletionNotification(message: String) {
        let content = UNMutableNotificationContent()
        content.title = "Download Update"
        content.body = message
        content.sound = .default
        
        let request = UNNotificationRequest(identifier: "download_progress", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
