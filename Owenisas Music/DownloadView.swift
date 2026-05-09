import SwiftUI
import SwiftData
import UserNotifications

struct DownloadView: View {
    @State private var youtubeLink = ""
    @State private var isDownloading = false
    @State private var statusMessage = ""
    @State private var debugLogLines: [String] = []
    @State private var downloadProgress: Double = 0
    @State private var downloadedCount = 0
    @State private var skippedCount = 0
    @State private var totalCount = 0
    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @FocusState private var linkFieldIsFocused: Bool
    
    @State private var targetPlaylistName: String? = nil
    @State private var targetPlaylistCover: String? = nil
    @State private var downloadedTrackTitles: [String] = []
    @State private var failedTrackTitles: [String] = []
    @State private var activeDownloadToken: UUID? = nil
    
    @State private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    @ObservedObject var dataManager = DataManager.shared
    @Environment(\.modelContext) private var environmentModelContext

    private let youtubeUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    private let desktopUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15"
    private let audioDownloadRetries = 4
    private let audioRetryDelay: TimeInterval = 2
    private let maxAudioDownloadDuration: TimeInterval = 45
    private let slowAudioBytesPerSecond: Double = 75_000
    private let lrclibRequestTimeout: TimeInterval = 4
    private let playlistMetadataConcurrency = 3

    private struct PlaylistPagePayload {
        let title: String
        let coverUrl: String?
        let videos: [String]
        let continuation: String?
        let apiKey: String?
        let context: [String: Any]?
    }

    private static let debugTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 45
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
                        .accessibilityIdentifier("downloadUrlField")

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
                if isDownloading || !statusMessage.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView(value: downloadProgress, total: 1.0)
                            .tint(.green)
                            .animation(.easeInOut, value: downloadProgress)

                        Text(statusMessage)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("downloadStatus")

                        if totalCount > 1 {
                            Text("\(processedCount)/\(totalCount) tracks processed")
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
                .accessibilityIdentifier("downloadButton")
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

                if !debugLogLines.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Debug Log")
                                .font(.subheadline.bold())
                            Spacer()
                            Button("Copy") {
                                UIPasteboard.general.string = debugLogLines.joined(separator: "\n")
                            }
                            .font(.caption.bold())
                            Button("Clear") {
                                debugLogLines.removeAll()
                            }
                            .font(.caption.bold())
                        }

                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(debugLogLines.suffix(60).enumerated()), id: \.offset) { _, line in
                                    Text(line)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .frame(maxHeight: 220)
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(UIColor.secondarySystemBackground))
                    )
                    .padding(.horizontal, 16)
                }

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
        .onAppear {
            if dataManager.modelContext == nil {
                dataManager.configure(with: environmentModelContext)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            guard isDownloading else { return }
            beginBackgroundTaskIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            endBackgroundTask()
        }
    }

    private var canDownload: Bool {
        !isDownloading
    }

    private var processedCount: Int {
        downloadedCount + skippedCount + failedTrackTitles.count
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
        let link = normalizeYouTubeLink(youtubeLink.trimmingCharacters(in: .whitespaces))
        guard !link.isEmpty else { return }
        let downloadToken = UUID()

        linkFieldIsFocused = false
        activeDownloadToken = downloadToken
        youtubeLink = link
        isDownloading = true
        downloadProgress = 0
        downloadedCount = 0
        skippedCount = 0
        totalCount = 0
        targetPlaylistName = nil
        targetPlaylistCover = nil
        downloadedTrackTitles = []
        failedTrackTitles = []
        debugLogLines = []
        debugLog("Start download for link: \(link)")
        
        // Refresh library state before checking duplicates
        dataManager.syncFromFileSystem()

        // Request notification auth
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        
        // Check if it's a playlist link
        if isPlaylistLink(link) {
            statusMessage = "🔍 Fetching playlist info…"
            debugLog("Detected playlist link")
            fetchPlaylistInfo(link: link, token: downloadToken)
        } else if let videoId = extractVideoId(from: link) {
            statusMessage = "🔍 Fetching video info…"
            totalCount = 1
            print("[DEBUG] Starting single video download: \(videoId)")
            debugLog("Detected single video: \(videoId)")
            fetchAndDownloadSingle(videoId: videoId, token: downloadToken)
        } else {
            print("[DEBUG] Invalid URL pasted: \(link)")
            debugLog("Rejected invalid URL")
            showError("Invalid URL", "Please paste a valid YouTube link.", token: downloadToken)
            isDownloading = false
        }
    }

    // MARK: - Single Video Download

    func fetchAndDownloadSingle(videoId: String, token: UUID, retries: Int = 2) {
        fetchYouTubeMetadata(videoId: videoId, retries: retries, token: token) { result in
            switch result {
            case .success(let meta):
                self.debugLog("Metadata fetched for video \(videoId): \(meta.title)")
                self.handleSingleVideoMetadata(meta, token: token)
            case .failure(let error):
                self.debugLog("Metadata fetch failed for \(videoId): \(error.message)")
                self.showError("Video Unavailable", error.message, token: token)
            }
        }
    }

    private func fetchYouTubeMetadata(videoId: String, retries: Int, token: UUID, completion: @escaping (Result<VideoInfo, DownloadError>) -> Void) {
        guard isActiveDownload(token) else {
            completion(.failure(DownloadError(message: "Download was cancelled.")))
            return
        }

        // Prefer the watch page + Innertube endpoint path first because YouTube often blocks /get_video_info in the app environment.
        fetchYouTubeMetadataFromWatchPage(videoId: videoId, token: token) { result in
            switch result {
            case .success:
                completion(result)
            case .failure:
                if retries > 0 {
                    self.debugLog("Watch page metadata parse failed, retrying legacy endpoint for \(videoId)")
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                        self.fetchYouTubeMetadataFromLegacyEndpoint(videoId: videoId, retries: retries - 1, token: token, completion: completion)
                    }
                    return
                }
                self.fetchYouTubeMetadataFromLegacyEndpoint(videoId: videoId, retries: 0, token: token, completion: completion)
            }
        }
    }

    private func fetchYouTubeMetadataFromLegacyEndpoint(videoId: String, retries: Int, token: UUID, completion: @escaping (Result<VideoInfo, DownloadError>) -> Void) {
        guard isActiveDownload(token) else {
            completion(.failure(DownloadError(message: "Download was cancelled.")))
            return
        }

        guard var components = URLComponents(string: "https://www.youtube.com/get_video_info") else {
            completion(.failure(DownloadError(message: "Invalid metadata endpoint.")))
            return
        }
        components.queryItems = [
            URLQueryItem(name: "video_id", value: videoId),
            URLQueryItem(name: "el", value: "embedded"),
            URLQueryItem(name: "ps", value: "default"),
            URLQueryItem(name: "eurl", value: ""),
            URLQueryItem(name: "hl", value: "en"),
            URLQueryItem(name: "gl", value: "US")
        ]

        guard let url = components.url else {
            completion(.failure(DownloadError(message: "Could not build metadata URL.")))
            return
        }

        debugLog("Requesting legacy video metadata for \(videoId)")
        var request = URLRequest(url: url)
        request.setValue(youtubeUserAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        URLSession.shared.dataTask(with: request) { data, response, error in
            guard self.isActiveDownload(token) else { return }

            if let error {
                if retries > 0 {
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                        self.fetchYouTubeMetadataFromLegacyEndpoint(videoId: videoId, retries: retries - 1, token: token, completion: completion)
                    }
                } else {
                    completion(.failure(DownloadError(message: error.localizedDescription)))
                }
                return
            }

            guard let data,
                  let payload = String(data: data, encoding: .utf8) else {
                completion(.failure(DownloadError(message: "Could not read YouTube metadata response.")))
                return
            }
            guard
                let queryItems = self.parseQueryString(payload),
                let playerJSON = queryItems["player_response"]?.removingPercentEncoding,
                let playerData = playerJSON.data(using: .utf8),
                let playerObject = try? JSONSerialization.jsonObject(with: playerData),
                let playerDict = playerObject as? [String: Any],
                let meta = self.videoInfo(from: playerDict, videoId: videoId)
            else {
                if retries > 0 {
                    self.debugLog("Legacy metadata parse failed, retrying for \(videoId)")
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                        self.fetchYouTubeMetadataFromLegacyEndpoint(videoId: videoId, retries: retries - 1, token: token, completion: completion)
                    }
                } else {
                    completion(.failure(DownloadError(message: "Could not parse video metadata.")))
                }
                return
            }

            DispatchQueue.main.async {
                completion(.success(meta))
            }
        }.resume()
    }

    private func fetchYouTubeMetadataFromWatchPage(videoId: String, token: UUID, completion: @escaping (Result<VideoInfo, DownloadError>) -> Void) {
        guard let url = URL(string: "https://www.youtube.com/watch?v=\(videoId)&bpctr=9999999999&has_verified=1&hl=en&gl=US") else {
            completion(.failure(DownloadError(message: "Could not build watch page URL.")))
            return
        }

        var request = URLRequest(url: url)
        request.setValue(youtubeUserAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        URLSession.shared.dataTask(with: request) { data, _, error in
            guard self.isActiveDownload(token) else { return }
            if let error {
                completion(.failure(DownloadError(message: error.localizedDescription)))
                return
            }

            guard let data, let html = String(data: data, encoding: .utf8) else {
                completion(.failure(DownloadError(message: "Could not parse watch page response.")))
                return
            }

            if let playerData = self.extractYouTubeJSON(from: html, marker: "ytInitialPlayerResponse = ")
                ?? self.extractYouTubeJSON(from: html, marker: "ytInitialPlayerResponse={")
                ?? self.extractYouTubeJSON(from: html, marker: "window[\"ytInitialPlayerResponse\"] = "),
               let meta = self.videoInfo(from: playerData, videoId: videoId) {
                self.debugLog("Watch page metadata parsed for \(videoId) from ytInitialPlayerResponse")
                completion(.success(meta))
                return
            }
            self.debugLog("Watch page ytInitialPlayerResponse parse failed for \(videoId), attempting Innertube fallback")

            guard let apiKey = self.extractInnertubeAPIKey(from: html) else {
                completion(.failure(DownloadError(message: "Could not extract YouTube API key from page.")))
                return
            }

            let context = self.extractInnertubeContext(from: html)
            let signatureTimestamp = self.extractInnertubeSignatureTimestamp(from: html)
            
            if let signatureTimestamp {
                let androidVRContext = self.buildAndroidVRClientContext(from: context)
                let fallbackAttempts: [(name: String, context: [String: Any]?, signatureTimestamp: Int?, includeParams: Bool)] = [
                    (name: "android_vr", context: androidVRContext, signatureTimestamp: signatureTimestamp, includeParams: false),
                    (name: "ios_with_params", context: context, signatureTimestamp: signatureTimestamp, includeParams: true),
                    (name: "ios_without_params", context: context, signatureTimestamp: signatureTimestamp, includeParams: false),
                    (name: "android_vr_without_sts", context: androidVRContext, signatureTimestamp: nil, includeParams: false)
                ]

                func tryAttempt(_ index: Int) {
                    guard self.isActiveDownload(token) else {
                        completion(.failure(DownloadError(message: "Download was cancelled.")))
                        return
                    }

                    if index >= fallbackAttempts.count {
                        completion(.failure(DownloadError(message: "Could not fetch playable stream metadata.")))
                        return
                    }

                    let attempt = fallbackAttempts[index]
                    self.debugLog("Trying INNERTUBE path: \(attempt.name), params=\(attempt.includeParams), sts=\(attempt.signatureTimestamp.map { String($0) } ?? "nil")")
                    self.fetchYouTubeMetadataFromInnertube(
                        videoId: videoId,
                        apiKey: apiKey,
                        context: attempt.context,
                        signatureTimestamp: attempt.signatureTimestamp,
                        includeParams: attempt.includeParams,
                        token: token
                    ) { result in
                        switch result {
                        case .success(let metadata):
                            completion(.success(metadata))
                        case .failure(let error):
                            self.debugLog("INNERTUBE path \(attempt.name) failed for \(videoId): \(error.message)")
                            tryAttempt(index + 1)
                        }
                    }
                }

                tryAttempt(0)
                return
            }

            self.fetchYouTubeMetadataFromInnertube(
                videoId: videoId,
                apiKey: apiKey,
                context: context,
                token: token,
                completion: completion
            )
        }.resume()
    }

    private func fetchYouTubeMetadataFromInnertube(
        videoId: String,
        apiKey: String,
        context: [String: Any]? = nil,
        signatureTimestamp: Int? = nil,
        includeParams: Bool = true,
        token: UUID,
        completion: @escaping (Result<VideoInfo, DownloadError>) -> Void
    ) {
        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false") else {
            completion(.failure(DownloadError(message: "Could not build player API URL.")))
            return
        }

        let clientContext = context ?? [
            "client": [
                "clientName": "IOS",
                "clientVersion": "19.09.0",
                "platform": "MOBILE",
                "hl": "en",
                "gl": "US"
            ]
        ]

        let clientDict = clientContext["client"] as? [String: Any] ?? [:]
        let clientName = (clientDict["clientName"] as? String) ?? "IOS"
        let clientVersion = (clientDict["clientVersion"] as? String) ?? "19.09.0"
        let userAgentForClient = (clientDict["userAgent"] as? String) ?? youtubeUserAgent
        let visitorData = clientDict["visitorData"] as? String

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgentForClient, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com/watch?v=\(videoId)", forHTTPHeaderField: "Referer")
        request.setValue(innertubeClientNumber(for: clientName), forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(clientVersion, forHTTPHeaderField: "X-Youtube-Client-Version")
        if let visitorData, !visitorData.isEmpty {
            request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }
        request.timeoutInterval = 20

        var payload: [String: Any] = [
            "context": clientContext,
            "videoId": videoId,
            "racyCheckOk": true,
            "contentCheckOk": true
        ] as [String: Any]

        if let signatureTimestamp {
            payload["playbackContext"] = [
                "contentPlaybackContext": [
                    "html5Preference": "HTML5_PREF_WANTS",
                    "signatureTimestamp": signatureTimestamp
                ]
            ]
        }

        if includeParams {
            payload["params"] = "8AEB"
        }

        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        if let cookies = HTTPCookieStorage.shared.cookies(for: url) {
            let cookieNames = cookies.map { $0.name }.joined(separator: ",")
            debugLog("Innertube cookies (\(cookies.count)) names=\(cookieNames) clientName=\(clientName) visitor=\(visitorData != nil)")
        } else {
            debugLog("Innertube no cookies in shared storage for url")
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            guard self.isActiveDownload(token) else { return }

            if let error {
                self.debugLog("Innertube request failed for \(videoId): \(error.localizedDescription)")
                completion(.failure(DownloadError(message: error.localizedDescription)))
                return
            }

            guard
                let http = response as? HTTPURLResponse,
                (200..<300).contains(http.statusCode)
            else {
                let statusText = (response as? HTTPURLResponse).map { "\($0.statusCode)" } ?? "unknown status"
                let details = String(data: data ?? Data(), encoding: .utf8) ?? ""
                self.debugLog("Innertube request failed for \(videoId): HTTP \(statusText)")
                completion(.failure(DownloadError(message: "Could not fetch Innertube metadata. \(statusText) \(details)")))
                return
            }

            guard
                let data,
                let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                self.debugLog("Innertube response parse failed for \(videoId).")
                completion(.failure(DownloadError(message: "Could not parse Innertube response."))
                )
                return
            }

            if let playability = payload["playabilityStatus"] as? [String: Any],
               let status = playability["status"] as? String,
               status != "OK" {
                let reason = (playability["reason"] as? String) ?? "Unknown reason."
                self.debugLog("Innertube playability blocked for \(videoId): \(status)")
                completion(.failure(DownloadError(message: "YouTube player blocked: \(reason)")))
                return
            }

            guard let meta = self.videoInfo(from: payload, videoId: videoId) else {
                self.debugLog("Innertube response missing playable audio stream for \(videoId).")
                completion(.failure(DownloadError(message: "No playable audio stream found.")))
                return
            }
            completion(.success(meta))
        }.resume()
    }

    private func innertubeClientNumber(for clientName: String) -> String {
        switch clientName.uppercased() {
        case "ANDROID_VR": return "28"
        case "IOS": return "5"
        case "ANDROID": return "3"
        case "WEB": return "1"
        case "MWEB": return "2"
        case "TVHTML5_SIMPLY_EMBEDDED_PLAYER": return "85"
        case "WEB_EMBEDDED_PLAYER": return "56"
        default: return "5"
        }
    }

    private func extractInnertubeContext(from html: String) -> [String: Any]? {
        guard let markerRange = html.range(of: "ytcfg.set(") else { return nil }
        let tail = html[markerRange.upperBound...]
        guard let start = tail.firstIndex(of: "{") else { return nil }

        var depth = 0
        var end: String.Index? = nil
        var inString = false
        var escape = false
        var idx = start
        while idx < tail.endIndex {
            let c = tail[idx]
            if escape {
                escape = false
            } else if inString {
                if c == "\\" { escape = true }
                else if c == "\"" { inString = false }
            } else {
                switch c {
                case "\"": inString = true
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 { end = idx }
                default: break
                }
                if end != nil { break }
            }
            idx = tail.index(after: idx)
        }

        guard let end, end >= start else { return nil }
        let jsonString = String(tail[start...end])
        guard let jsonData = jsonString.data(using: .utf8) else { return nil }
        let config = (try? JSONSerialization.jsonObject(with: jsonData)) as? [String: Any]
        return config?["INNERTUBE_CONTEXT"] as? [String: Any]
    }

    private func buildAndroidVRClientContext(from context: [String: Any]?) -> [String: Any] {
        var clientContext = context?["client"] as? [String: Any] ?? [:]
        clientContext["clientName"] = "ANDROID_VR"
        clientContext["clientVersion"] = "1.65.10"
        clientContext["userAgent"] = "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip"
        clientContext["deviceMake"] = "Oculus"
        clientContext["deviceModel"] = "Quest 3"
        clientContext["androidSdkVersion"] = 32
        clientContext["osName"] = "Android"
        clientContext["osVersion"] = "12L"
        clientContext["gl"] = "US"
        clientContext["hl"] = "en"
        clientContext["timeZone"] = "UTC"
        clientContext["utcOffsetMinutes"] = 0

        return [
            "client": clientContext,
            "request": [
                "useSsl": true,
                "internalExperimentFlags": [],
                "consistencyTokenJars": []
            ],
            "capabilities": [
                "allowsInstantApp": true,
                "desktopLegacyEmbeds": true
            ]
        ]
    }

    private func extractInnertubeSignatureTimestamp(from html: String) -> Int? {
        let pattern = "\"STS\"\\s*:\\s*(\\d+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, range: range), match.numberOfRanges >= 2 else { return nil }
        let stampRange = Range(match.range(at: 1), in: html)
        return stampRange.flatMap { Int(String(html[$0])) }
    }

    private func extractInnertubeAPIKey(from html: String) -> String? {
        let markers = [
            "\"INNERTUBE_API_KEY\":\"",
            "\"innertubeApiKey\":\"",
            "\"INNERTUBE_API_KEY\": \"",
            "\"innertubeApiKey\": \""
        ]

        for marker in markers {
            guard let markerRange = html.range(of: marker) else { continue }
            let rest = html[markerRange.upperBound...]
        guard let end = rest.range(of: "\"") else { continue }
            let key = String(rest[..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                return key
            }
        }

        return nil
    }

    private func parseQueryString(_ value: String) -> [String: String]? {
        var result: [String: String] = [:]
        for pair in value.split(separator: "&") {
            let parts = pair.split(separator: "=", omittingEmptySubsequences: false)
            guard let key = parts.first else { continue }
            let keyString = String(key)
            let rawValue = parts.dropFirst().joined(separator: "=")
            let parsedValue = rawValue.replacingOccurrences(of: "+", with: " ")
            result[keyString] = parsedValue.removingPercentEncoding
        }
        return result.isEmpty ? nil : result
    }

    private func videoInfo(from player: [String: Any], videoId: String) -> VideoInfo? {
        guard let videoDetails = player["videoDetails"] as? [String: Any] else {
            return nil
        }

        let title = (videoDetails["title"] as? String) ?? "Unknown Title"
        let artist = (videoDetails["author"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        let rawDuration = videoDetails["lengthSeconds"]
        let duration = (rawDuration as? String).flatMap(Double.init) ?? (rawDuration as? Double) ?? 0

        let language = (videoDetails["caption"] as? String) == "True" ? "en" : nil

        let thumbnails = (videoDetails["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
        let coverUrl = thumbnails?
            .compactMap({ $0["url"] as? String })
            .last ?? ""

        let streamingData = player["streamingData"] as? [String: Any]
        let adaptiveFormats = streamingData?["adaptiveFormats"] as? [[String: Any]] ?? []
        let formats = streamingData?["formats"] as? [[String: Any]] ?? []
        let allFormats = adaptiveFormats + formats

        guard let audioUrl = bestAudioURL(from: allFormats) else {
            return nil
        }

        var subtitleUrls: [String: String] = [:]
        if let captions = player["captions"] as? [String: Any] {
            let trackList = (captions["playerCaptionsTracklistRenderer"] as? [String: Any])?["captionTracks"] as? [[String: Any]]
            for track in trackList ?? [] {
                guard let base = track["baseUrl"] as? String else { continue }
                let lang = (track["languageCode"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? (track["vssId"] as? String)?
                    .replacingOccurrences(of: ".vtt", with: "")
                    .replacingOccurrences(of: ".srt", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !base.isEmpty {
                    let urlWithVTT = base.contains("fmt=") ? base : "\(base)&fmt=vtt"
                    let subtitleLang = (lang ?? "unknown").isEmpty ? "unknown" : (lang ?? "unknown")
                    subtitleUrls[subtitleLang] = urlWithVTT
                }
            }
        }

        return VideoInfo(
            id: videoId,
            title: title,
            artist: artist,
            album: nil,
            duration: duration,
            language: language,
            audioUrl: audioUrl,
            coverUrl: coverUrl,
            subtitleUrls: subtitleUrls.isEmpty ? nil : subtitleUrls
        )
    }

    private func bestAudioURL(from formats: [[String: Any]]) -> String? {
        let audioFormats = formats.filter {
            guard let mime = ($0["mimeType"] as? String)?.lowercased() else { return false }
            return mime.contains("audio/")
        }
        guard !audioFormats.isEmpty else { return nil }

        let ranked = audioFormats
            .compactMap { item -> (score: Int, format: [String: Any])? in
                let mime = (item["mimeType"] as? String)?.lowercased() ?? ""
                let bitrate = (item["bitrate"] as? Int) ?? (item["averageBitrate"] as? Int) ?? 0
                let codecBoost = mime.contains("mp4") ? 1_000_000 : 0
                let candidateScore = bitrate + codecBoost
                return (candidateScore, item)
            }
            .sorted { $0.score > $1.score }

        for (_, format) in ranked {
            if let url = resolveStreamURL(from: format) { return url }
        }
        return nil
    }

    private func resolveStreamURL(from format: [String: Any]) -> String? {
        if let url = format["url"] as? String, !url.isEmpty {
            debugLog("Resolved direct audio URL from format (mime: \((format["mimeType"] as? String) ?? "unknown"), bitrate: \((format["bitrate"] as? Int) ?? 0))")
            return url
        }

        let cipherValue = (format["signatureCipher"] as? String) ?? (format["cipher"] as? String)
        guard let cipherValue else { return nil }
        guard let cipherDict = parseQueryString(cipherValue) else { return nil }
        let cipherKeys = cipherDict.keys.sorted().joined(separator: ",")
        debugLog("Encountered ciphered audio format keys: \(cipherKeys)")

        guard let encoded = cipherDict["url"]?.removingPercentEncoding else { return nil }
        let signature = cipherDict["s"] ?? cipherDict["sig"]
        let signKey = cipherDict["sp"] ?? "signature"
        if let signature {
            let resolved = "\(encoded)&\(signKey)=\(signature.removingPercentEncoding ?? signature)"
            debugLog("Resolved signatureCipher stream URL using key '\(signKey)'")
            return resolved
        }
        if let playerURL = cipherDict["player_url"] {
            debugLog("Encountered cipher without signature; player url present: \(playerURL)")
        }
        return nil
    }

    @MainActor
    private func handleSingleVideoMetadata(_ meta: VideoInfo, token: UUID) {
        guard isActiveDownload(token) else { return }
        let safeTitle = meta.title.replacingOccurrences(of: "/", with: "-").precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        let stableIdentifier = stableSongIdentifier(for: meta)

        DispatchQueue.main.async {
            self.statusMessage = "🎶 Downloading \"\(safeTitle)\"…"
            self.downloadProgress = 0.2
            self.sendProgressNotification(message: "Downloading: \(safeTitle)")
        }

        Task { @MainActor in
            guard self.isActiveDownload(token) else { return }
            let existingSongs = self.dataManager.fetchAllSongs()
            let isDuplicate = self.isDuplicateSong(meta: meta, stableIdentifier: stableIdentifier, existingSongs: existingSongs)

            if isDuplicate {
                self.debugLog("Single track already exists: \(safeTitle) [\(stableIdentifier)]")
                self.finishSuccess("✅ \"\(safeTitle)\" already exists in library!", token: token)
                return
            }

            self.downloadSingleTrack(meta: meta, safeTitle: safeTitle, stableIdentifier: stableIdentifier, token: token)
        }
    }

    @MainActor
    private func downloadSingleTrack(meta: VideoInfo, safeTitle: String, stableIdentifier: String, token: UUID) {
        guard isActiveDownload(token) else { return }
        guard let audioURL = URL(string: meta.audioUrl) else {
            debugLog("Invalid audio URL for single track: \(safeTitle) [\(stableIdentifier)]")
            showError("Error", "Invalid audio URL", token: token)
            return
        }

        debugLog("Begin single-track download: \(safeTitle) [\(stableIdentifier)]")

        let coverURLStr = meta.coverUrl.isEmpty ? nil : meta.coverUrl
        let coverURL = coverURLStr.flatMap(URL.init(string:))

        let continueWithAudio = { (localCover: URL?) in
            self.download(from: audioURL, kind: .audio, retries: self.audioDownloadRetries, suppressUserFacingError: true, token: token) { localAudio in
                guard self.isActiveDownload(token) else {
                    if let localAudio {
                        try? FileManager.default.removeItem(at: localAudio)
                    }
                    if let localCover {
                        try? FileManager.default.removeItem(at: localCover)
                    }
                    return
                }
                DispatchQueue.main.async { self.downloadProgress = 0.8 }
                guard let localAudio = localAudio else {
                    self.debugLog("Audio download failed for single track: \(safeTitle) [\(stableIdentifier)]")
                    self.showError("Audio Error", "The audio file could not be downloaded. YouTube might be blocking the request.", token: token)
                    return
                }

                self.debugLog("Audio download succeeded for single track: \(safeTitle) [\(stableIdentifier)]")

                var ytSubs = meta.subtitleUrls?.filter({ $0.key != "lyrics" }) ?? [:]
                if ytSubs.count > 3 {
                    let preferred = [meta.language ?? "ja", "en", "zh-Hant"]
                    var limited: [String: String] = [:]
                    for lang in preferred {
                        if let url = ytSubs[lang] { limited[lang] = url }
                    }
                    if limited.isEmpty, let first = ytSubs.first {
                        limited[first.key] = first.value
                    }
                    ytSubs = limited
                }

                let saveWithLyrics = { (ytDownloaded: [(lang: String, url: URL)]) in
                    DispatchQueue.main.async {
                        self.statusMessage = "🎵 Fetching synced lyrics…"
                    }
                    self.fetchLRCLIBLyrics(title: meta.title, artist: meta.artist ?? "", album: meta.album ?? "", duration: meta.duration ?? 0) { lrcFile in
                        guard self.isActiveDownload(token) else {
                            if let lrcFile {
                                try? FileManager.default.removeItem(at: lrcFile)
                            }
                            return
                        }
                        var allSubs = ytDownloaded
                        if let lrcFile = lrcFile {
                            allSubs.append((lang: "lyrics", url: lrcFile))
                        }
                        self.debugLog("Saving single track with \(allSubs.count) subtitle files: \(safeTitle) [\(stableIdentifier)]")
                        self.finishSave(folderIdentifier: stableIdentifier, displayTitle: safeTitle, meta: meta, cover: localCover, audio: localAudio, subtitles: allSubs, token: token)
                    }
                }

                if !ytSubs.isEmpty {
                    DispatchQueue.main.async {
                        self.statusMessage = "💬 Downloading subtitles (\(ytSubs.count) languages)…"
                    }
                    self.downloadAllSubtitles(ytSubs, token: token) { downloaded in
                        guard self.isActiveDownload(token) else {
                            downloaded.forEach { try? FileManager.default.removeItem(at: $0.url) }
                            return
                        }
                        saveWithLyrics(downloaded)
                    }
                } else {
                    saveWithLyrics([])
                }
            }
        }

        if let validCoverURL = coverURL {
            download(from: validCoverURL, kind: .image, suppressUserFacingError: true, token: token) { localCover in
                guard self.isActiveDownload(token) else {
                    if let localCover {
                        try? FileManager.default.removeItem(at: localCover)
                    }
                    return
                }
                DispatchQueue.main.async { self.downloadProgress = 0.4 }
                continueWithAudio(localCover)
            }
        } else {
            DispatchQueue.main.async { self.downloadProgress = 0.4 }
            continueWithAudio(nil)
        }
    }

    private func finishSave(folderIdentifier: String, displayTitle: String, meta: VideoInfo, cover: URL?, audio: URL, subtitles: [(lang: String, url: URL)], token: UUID) {
        guard isActiveDownload(token) else {
            try? FileManager.default.removeItem(at: audio)
            if let cover {
                try? FileManager.default.removeItem(at: cover)
            }
            subtitles.forEach { try? FileManager.default.removeItem(at: $0.url) }
            return
        }
        do {
            try saveSongFiles(title: folderIdentifier, meta: meta, localCover: cover, localAudio: audio, localSubtitles: subtitles)
            debugLog("Saved song files: \(displayTitle) [\(folderIdentifier)]")
            DispatchQueue.main.async {
                guard self.isActiveDownload(token) else { return }
                downloadProgress = 1.0
                downloadedCount += 1
                downloadedTrackTitles.append(folderIdentifier)
                finishSuccess("✅ \"\(displayTitle)\" downloaded!", token: token)
            }
        } catch {
            showError("Save Error", error.localizedDescription, token: token)
        }
    }

    // MARK: - Playlist Download

    func isPlaylistLink(_ link: String) -> Bool {
        link.contains("list=") || link.contains("/playlist")
    }

    func fetchPlaylistInfo(link: String, token: UUID, retries: Int = 2) {
        print("[DEBUG] Fetching playlist metadata for: \(link)")
        debugLog("Fetching playlist metadata")

        guard let playlistId = extractPlaylistId(from: link) else {
            if let videoId = extractVideoId(from: link) {
                DispatchQueue.main.async {
                    self.statusMessage = "Playlist parsing unavailable, downloading single…"
                    self.totalCount = 1
                }
                self.fetchAndDownloadSingle(videoId: videoId, token: token)
            } else {
                showError("Playlist Error", "Could not extract a valid playlist ID.", token: token)
            }
            return
        }

        fetchPlaylistVideoIDs(playlistId: playlistId, retries: retries, token: token) { result in
            switch result {
            case .success(let playlistPayload):
                let ids = playlistPayload.videos
                guard self.isActiveDownload(token) else { return }
                self.debugLog("Playlist page metadata found: \(ids.count) entries")
                guard !ids.isEmpty else {
                    self.showError("Playlist Error", "This playlist appears to be empty or blocked.", token: token)
                    return
                }
                let playlistName = playlistPayload.title.isEmpty ? "Playlist" : playlistPayload.title
                DispatchQueue.main.async {
                    self.totalCount = ids.count
                    self.statusMessage = "📋 Resolving \(ids.count) tracks in \"\(playlistName)\"…"
                    self.targetPlaylistName = playlistName
                    self.targetPlaylistCover = playlistPayload.coverUrl
                }
                self.resolvePlaylistVideoMetadata(ids: ids, token: token) { result in
                    switch result {
                    case .success(let videos):
                        guard self.isActiveDownload(token) else { return }
                        if videos.isEmpty {
                            self.showError("Playlist Error", "Could not resolve playable tracks from this playlist.", token: token)
                        } else {
                            self.debugLog("Resolved playlist tracks: \(videos.count)/\(ids.count)")
                            self.downloadPlaylistTracks(videos, index: 0, token: token)
                        }
                    case .failure(let error):
                        self.showError("Playlist Error", error.message, token: token)
                    }
                }
            case .failure:
                self.debugLog("Playlist metadata request failed, trying single-video fallback if possible")
                if let videoId = self.extractVideoId(from: link) {
                    DispatchQueue.main.async {
                        self.statusMessage = "Playlist metadata unavailable, downloading single…"
                        self.totalCount = 1
                    }
                    self.fetchAndDownloadSingle(videoId: videoId, token: token)
                } else {
                    self.showError("Playlist Error", "The playlist metadata could not be retrieved.", token: token)
                }
            }
        }
    }

    private func fetchPlaylistVideoIDs(playlistId: String, retries: Int, token: UUID, completion: @escaping (Result<(title: String, coverUrl: String?, videos: [String]), DownloadError>) -> Void) {
        guard let url = URL(string: "https://www.youtube.com/playlist?list=\(playlistId)&hl=en&gl=US") else {
            completion(.failure(DownloadError(message: "Could not build playlist URL.")))
            return
        }

        var request = URLRequest(url: url)
        request.setValue(desktopUserAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        URLSession.shared.dataTask(with: request) { data, _, error in
            guard self.isActiveDownload(token) else { return }
            if let error {
                if retries > 0 {
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                        self.fetchPlaylistVideoIDs(playlistId: playlistId, retries: retries - 1, token: token, completion: completion)
                    }
                } else {
                    completion(.failure(DownloadError(message: error.localizedDescription)))
                }
                return
            }

            guard let data, let html = String(data: data, encoding: .utf8) else {
                completion(.failure(DownloadError(message: "Could not read playlist page.")))
                return
            }

            guard let firstPage = self.playlistPagePayload(fromHTML: html) else {
                if retries > 0 {
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                        self.fetchPlaylistVideoIDs(playlistId: playlistId, retries: retries - 1, token: token, completion: completion)
                    }
                } else {
                    completion(.failure(DownloadError(message: "Could not parse playlist page.")))
                }
                return
            }

            var uniqueIDs: [String] = []
            var seenIDs = Set<String>()
            for id in firstPage.videos where seenIDs.insert(id).inserted {
                uniqueIDs.append(id)
            }

            self.debugLog("Playlist first page found \(firstPage.videos.count) entries\(firstPage.continuation == nil ? "" : ", fetching continuation pages")")

            self.fetchPlaylistContinuationPages(
                apiKey: firstPage.apiKey,
                context: firstPage.context,
                continuation: firstPage.continuation,
                seenContinuations: [],
                token: token
            ) { continuationIDs in
                guard self.isActiveDownload(token) else { return }
                for id in continuationIDs where seenIDs.insert(id).inserted {
                    uniqueIDs.append(id)
                }

                self.debugLog("Playlist metadata found \(uniqueIDs.count) unique entries across all pages")
                completion(.success((title: firstPage.title, coverUrl: firstPage.coverUrl, videos: uniqueIDs)))
            }
        }.resume()
    }

    private func playlistPagePayload(fromHTML html: String) -> PlaylistPagePayload? {
        guard
            let initialData = extractYouTubeInitialData(from: html),
            let listRenderer = deepSearch(forKey: "playlistVideoListRenderer", in: initialData),
            let playlistContents = listRenderer["contents"] as? [[String: Any]]
        else {
            return nil
        }

        let ids = extractPlaylistVideoIDs(from: playlistContents)
        let continuation = extractContinuationToken(from: playlistContents)
        let title = extractTextFromNode(deepSearch(forKey: "title", in: initialData)) ?? ""
        let cover = extractPlaylistCover(from: initialData)

        return PlaylistPagePayload(
            title: title,
            coverUrl: cover,
            videos: ids,
            continuation: continuation,
            apiKey: extractInnertubeAPIKey(from: html),
            context: extractInnertubeContext(from: html)
        )
    }

    private func fetchPlaylistContinuationPages(
        apiKey: String?,
        context: [String: Any]?,
        continuation: String?,
        seenContinuations: Set<String>,
        token: UUID,
        completion: @escaping ([String]) -> Void
    ) {
        guard isActiveDownload(token), let continuation, !continuation.isEmpty else {
            completion([])
            return
        }

        var updatedSeenContinuations = seenContinuations
        guard updatedSeenContinuations.insert(continuation).inserted else {
            completion([])
            return
        }

        guard let apiKey, let url = URL(string: "https://www.youtube.com/youtubei/v1/browse?prettyPrint=false&key=\(apiKey)") else {
            debugLog("Playlist continuation unavailable: missing Innertube API key")
            completion([])
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(desktopUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Referer")
        request.setValue("1", forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue("2.20240509.00.00", forHTTPHeaderField: "X-Youtube-Client-Version")

        let browseContext = context ?? [
            "client": [
                "clientName": "WEB",
                "clientVersion": "2.20240509.00.00",
                "hl": "en",
                "gl": "US"
            ]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "context": browseContext,
            "continuation": continuation
        ])

        URLSession.shared.dataTask(with: request) { data, response, error in
            guard self.isActiveDownload(token) else { return }

            if let error {
                self.debugLog("Playlist continuation request failed: \(error.localizedDescription)")
                completion([])
                return
            }

            guard
                let http = response as? HTTPURLResponse,
                (200..<300).contains(http.statusCode),
                let data,
                let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                let status = (response as? HTTPURLResponse).map { "\($0.statusCode)" } ?? "unknown"
                self.debugLog("Playlist continuation request failed: HTTP \(status)")
                completion([])
                return
            }

            let contents = self.extractPlaylistContinuationContents(from: payload)
            let ids = self.extractPlaylistVideoIDs(from: contents)
            let nextContinuation = self.extractContinuationToken(from: contents)
            self.debugLog("Playlist continuation page found \(ids.count) entries")

            self.fetchPlaylistContinuationPages(
                apiKey: apiKey,
                context: context,
                continuation: nextContinuation,
                seenContinuations: updatedSeenContinuations,
                token: token
            ) { nextIDs in
                completion(ids + nextIDs)
            }
        }.resume()
    }

    private func extractPlaylistContinuationContents(from payload: [String: Any]) -> [[String: Any]] {
        let videoRenderers = deepSearchAll(forKey: "playlistVideoRenderer", in: payload)
            .compactMap { $0 as? [String: Any] }
            .map { ["playlistVideoRenderer": $0] }
        let continuations = deepSearchAll(forKey: "continuationItemRenderer", in: payload)
            .compactMap { $0 as? [String: Any] }
            .map { ["continuationItemRenderer": $0] }
        return videoRenderers + continuations
    }

    private func extractPlaylistVideoIDs(from contents: [[String: Any]]) -> [String] {
        contents.compactMap { entry -> String? in
            guard let renderer = entry["playlistVideoRenderer"] as? [String: Any] else { return nil }
            return renderer["videoId"] as? String
        }
    }

    private func extractContinuationToken(from contents: [[String: Any]]) -> String? {
        for entry in contents {
            if let token = (((entry["continuationItemRenderer"] as? [String: Any])?["continuationEndpoint"] as? [String: Any])?["continuationCommand"] as? [String: Any])?["token"] as? String {
                return token
            }
        }
        return nil
    }

    private func deepSearchAll(forKey key: String, in node: Any) -> [Any] {
        var matches: [Any] = []
        if let dict = node as? [String: Any] {
            if let value = dict[key] {
                matches.append(value)
            }
            for value in dict.values {
                matches.append(contentsOf: deepSearchAll(forKey: key, in: value))
            }
        } else if let array = node as? [Any] {
            for item in array {
                matches.append(contentsOf: deepSearchAll(forKey: key, in: item))
            }
        }
        return matches
    }

    private func resolvePlaylistVideoMetadata(ids: [String], token: UUID, completion: @escaping (Result<[VideoInfo], DownloadError>) -> Void) {
        guard !ids.isEmpty else {
            completion(.success([]))
            return
        }

        let lock = NSLock()
        var nextIndex = 0
        var finishedCount = 0
        var didComplete = false
        var resolved: [(index: Int, meta: VideoInfo)] = []

        func finishIfNeeded(force: Bool = false) {
            lock.lock()
            let shouldComplete = !didComplete && (force || finishedCount >= ids.count)
            if shouldComplete { didComplete = true }
            let ordered = resolved.sorted { $0.index < $1.index }.map(\.meta)
            lock.unlock()

            if shouldComplete {
                completion(.success(ordered))
            }
        }

        func resolveNext() {
            guard self.isActiveDownload(token) else {
                finishIfNeeded(force: true)
                return
            }

            lock.lock()
            guard nextIndex < ids.count else {
                lock.unlock()
                finishIfNeeded()
                return
            }
            let index = nextIndex
            nextIndex += 1
            lock.unlock()

            self.fetchYouTubeMetadata(videoId: ids[index], retries: 1, token: token) { result in
                lock.lock()
                switch result {
                case .success(let meta):
                    resolved.append((index: index, meta: meta))
                case .failure(let error):
                    self.debugLog("Skipping playlist item \(ids[index]): \(error.message)")
                }
                finishedCount += 1
                let shouldStartAnother = finishedCount < ids.count
                lock.unlock()

                if shouldStartAnother {
                    resolveNext()
                } else {
                    finishIfNeeded()
                }
            }
        }

        let workerCount = min(playlistMetadataConcurrency, ids.count)
        for _ in 0..<workerCount {
            resolveNext()
        }
    }

    private func extractPlaylistCover(from initialData: [String: Any]) -> String? {
        guard let header = deepSearch(forKey: "playlistHeaderRenderer", in: initialData) else { return nil }
        if let thumbnails = (header["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]],
           let last = thumbnails.last,
           let cover = last["url"] as? String {
            return cover
        }
        if let thumbnails = (header["thumbnailRenderer"] as? [String: Any])?["playlistVideoRenderer"] as? [String: Any],
           let thumbnail = thumbnails["thumbnail"] as? [String: Any],
           let items = thumbnail["thumbnails"] as? [[String: Any]],
           let last = items.last,
           let cover = last["url"] as? String {
            return cover
        }
        return nil
    }

    private func extractYouTubeInitialData(from html: String) -> [String: Any]? {
        if let initialData = extractYouTubeJSON(from: html, marker: "ytInitialData = ") { return initialData }
        if let initialData = extractYouTubeJSON(from: html, marker: "window[\"ytInitialData\"] = ") { return initialData }
        return extractYouTubeJSON(from: html, marker: "ytInitialData=")
    }

    private func extractYouTubeJSON(from html: String, marker: String) -> [String: Any]? {
        guard let markerRange = html.range(of: marker) else { return nil }
        let rest = html[markerRange.upperBound...]
        guard let end = rest.range(of: ";</script>") else { return nil }
        let jsonRaw = String(rest[..<end.lowerBound])
        for payload in [jsonRaw, decodeHexEscapedJSON(jsonRaw)] {
            guard let data = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let dict = object as? [String: Any] else {
                continue
            }
            return dict
        }
        return nil
    }

    private func decodeHexEscapedJSON(_ value: String) -> String {
        var source = value
        if source.count >= 2 {
            let first = source.first
            let last = source.last
            if (first == "'" && last == "'") || (first == "\"" && last == "\"") {
                source.removeFirst()
                source.removeLast()
            }
        }

        var output = ""
        var index = source.startIndex

        while index < source.endIndex {
            if source[index] == "\\" {
                let xIndex = source.index(after: index)
                if xIndex < source.endIndex && source[xIndex] == "x" {
                    let h1Index = source.index(after: xIndex)
                    let h2Index = h1Index < source.endIndex ? source.index(after: h1Index) : source.endIndex
                    if h2Index < source.endIndex {
                        let hex = String(source[h1Index...h2Index])
                        if let byte = UInt8(hex, radix: 16) {
                            output.unicodeScalars.append(UnicodeScalar(byte))
                            index = source.index(after: h2Index)
                            continue
                        }
                    }
                }
            }

            output.append(source[index])
            index = source.index(after: index)
        }

        return output
    }

    private func extractTextFromNode(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let text = value as? String {
            return text
        }
        if let dict = value as? [String: Any] {
            if let simple = dict["simpleText"] as? String { return simple }
            if let runs = dict["runs"] as? [[String: Any]] {
                return runs.compactMap { $0["text"] as? String }.joined()
            }
        }
        return nil
    }

    private func deepSearch(forKey key: String, in node: Any) -> [String: Any]? {
        if let dict = node as? [String: Any] {
            if let target = dict[key] as? [String: Any] {
                return target
            }
            for (_, value) in dict {
                if let found = deepSearch(forKey: key, in: value) {
                    return found
                }
            }
        }
        if let array = node as? [Any] {
            for item in array {
                if let found = deepSearch(forKey: key, in: item) {
                    return found
                }
            }
        }
        return nil
    }

    private func songExistsLocally(safeIdentifier rawId: String) -> Bool {
        let safeIdentifier = rawId.precomposedStringWithCanonicalMapping
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return false }
        let songDir = docs.appendingPathComponent("Songs/\(safeIdentifier)")
        let exists = fm.fileExists(atPath: songDir.path)
        if exists { print("[DEBUG] Song folder already found on disk: \(safeIdentifier)") }
        return exists
    }

    func downloadPlaylistTracks(_ videos: [VideoInfo], index: Int, token: UUID) {
        guard isActiveDownload(token) else { return }
        guard index < videos.count else {
            debugLog("Playlist processing complete. downloaded=\(downloadedCount) skipped=\(skippedCount) failed=\(failedTrackTitles.count)")
            DispatchQueue.main.async {
                guard self.isActiveDownload(token) else { return }
                self.createAutoPlaylist()
                if self.downloadedCount == 0 && self.skippedCount == 0 && !self.failedTrackTitles.isEmpty {
                    self.showError("Playlist Failed", "None of the tracks could be downloaded.", token: token)
                } else {
                    self.finishSuccess(self.playlistCompletionMessage(), token: token)
                }
            }
            return
        }

        let meta = videos[index]
        let safeArtist = (meta.artist ?? "Unknown Artist").replacingOccurrences(of: "/", with: "-").precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeTitle = meta.title.replacingOccurrences(of: "/", with: "-").precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayIdentifier = "\(safeArtist) - \(safeTitle)"
        let stableIdentifier = stableSongIdentifier(for: meta)

        DispatchQueue.main.async {
            statusMessage = "⬇️ (\(index+1)/\(videos.count)) \"\(safeTitle)\""
            downloadProgress = Double(index) / Double(videos.count)
            self.sendProgressNotification(message: "Downloading \(index+1) of \(videos.count)\n\(safeTitle)")
        }
        debugLog("Processing playlist track \(index + 1)/\(videos.count): \(displayIdentifier) [\(stableIdentifier)]")

        // Check if the song has already been downloaded (skip duplicate downloads)
        Task { @MainActor in
            guard self.isActiveDownload(token) else { return }
            let existingSongs = dataManager.fetchAllSongs()
            let isDuplicate = self.isDuplicateSong(meta: meta, stableIdentifier: stableIdentifier, existingSongs: existingSongs)

            if isDuplicate {
                print("[DEBUG] Skipping duplicate: \(displayIdentifier) [\(stableIdentifier)]")
                self.debugLog("Skipped duplicate playlist track: \(displayIdentifier) [\(stableIdentifier)]")
                statusMessage = "⏭ Skipping duplicate: \(safeTitle)"
                self.skippedCount += 1
                self.downloadedTrackTitles.append(stableIdentifier)
                // Skip and move to next track
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                    self.downloadPlaylistTracks(videos, index: index + 1, token: token)
                }
                return
            }
            
            // If not duplicate, proceed with audio download (back to background)
            DispatchQueue.global().async {
                self.proceedWithPlaylistDownload(videos, index: index, meta: meta, stableIdentifier: stableIdentifier, safeTitle: safeTitle, displayIdentifier: displayIdentifier, token: token)
            }
        }
    }

    private func proceedWithPlaylistDownload(_ videos: [VideoInfo], index: Int, meta: VideoInfo, stableIdentifier: String, safeTitle: String, displayIdentifier: String, token: UUID) {
        guard isActiveDownload(token) else { return }
        guard let audioURL = URL(string: meta.audioUrl) else {
            debugLog("Invalid playlist audio URL: \(displayIdentifier) [\(stableIdentifier)]")
            DispatchQueue.main.async { self.failedTrackTitles.append(safeTitle) }
            downloadPlaylistTracks(videos, index: index + 1, token: token)
            return
        }

        debugLog("Begin playlist track download: \(displayIdentifier) [\(stableIdentifier)]")

        // Try track cover first, fallback to playlist cover, then nil
        var finalCoverStr: String? = nil
        if !meta.coverUrl.isEmpty {
            finalCoverStr = meta.coverUrl
        } else if let pCover = targetPlaylistCover, !pCover.isEmpty {
            finalCoverStr = pCover
        }
        
        let coverURL = finalCoverStr != nil ? URL(string: finalCoverStr!) : nil

        let continueWithAudio = { (localCover: URL?) in
            self.download(from: audioURL, kind: .audio, retries: self.audioDownloadRetries, suppressUserFacingError: true, token: token) { localAudio in
                guard self.isActiveDownload(token) else {
                    if let localAudio {
                        try? FileManager.default.removeItem(at: localAudio)
                    }
                    if let localCover {
                        try? FileManager.default.removeItem(at: localCover)
                    }
                    return
                }
                guard let localAudio = localAudio else {
                    print("[DEBUG] Playlist Download: Audio failed for \(safeTitle), skipping track.")
                    self.debugLog("Playlist audio failed: \(displayIdentifier) [\(stableIdentifier)]")
                    DispatchQueue.main.async { self.failedTrackTitles.append(safeTitle) }
                    self.downloadPlaylistTracks(videos, index: index + 1, token: token)
                    return
                }
                self.debugLog("Playlist audio succeeded: \(displayIdentifier) [\(stableIdentifier)]")
                
                let subURLStr = self.bestSubtitleURL(from: meta)
                if let subURLStr = subURLStr, let parsedSubURL = URL(string: subURLStr) {
                    self.download(from: parsedSubURL, kind: .subtitle, retries: 0, suppressUserFacingError: true, token: token) { localSubtitle in
                        guard self.isActiveDownload(token) else {
                            if let localSubtitle {
                                try? FileManager.default.removeItem(at: localSubtitle)
                            }
                            try? FileManager.default.removeItem(at: localAudio)
                            if let localCover {
                                try? FileManager.default.removeItem(at: localCover)
                            }
                            return
                        }
                        let ytSubs: [(lang: String, url: URL)] = localSubtitle != nil
                            ? [(lang: meta.language ?? "und", url: localSubtitle!)]
                            : []
                        self.fetchLRCLIBLyrics(title: meta.title, artist: meta.artist ?? "", album: meta.album ?? "", duration: meta.duration ?? 0) { lyricsFile in
                            guard self.isActiveDownload(token) else {
                                if let lyricsFile {
                                    try? FileManager.default.removeItem(at: lyricsFile)
                                }
                                ytSubs.forEach { try? FileManager.default.removeItem(at: $0.url) }
                                try? FileManager.default.removeItem(at: localAudio)
                                if let localCover {
                                    try? FileManager.default.removeItem(at: localCover)
                                }
                                return
                            }
                            var allSubs = ytSubs
                            if let lyricsFile {
                                allSubs.append((lang: "lyrics", url: lyricsFile))
                            }
                            do {
                                try self.saveSongFiles(title: stableIdentifier, meta: meta, localCover: localCover, localAudio: localAudio, localSubtitles: allSubs)
                                self.debugLog("Saved playlist track with \(allSubs.count) subtitle files: \(displayIdentifier) [\(stableIdentifier)]")
                                DispatchQueue.main.async {
                                    guard self.isActiveDownload(token) else { return }
                                    self.downloadedCount += 1
                                    self.downloadedTrackTitles.append(stableIdentifier)
                                }
                            } catch {
                                print("Failed to save \(displayIdentifier) [\(stableIdentifier)]: \(error)")
                                self.debugLog("Failed saving playlist track: \(displayIdentifier) [\(stableIdentifier)] error=\(error.localizedDescription)")
                                DispatchQueue.main.async { self.failedTrackTitles.append(safeTitle) }
                            }
                            self.downloadPlaylistTracks(videos, index: index + 1, token: token)
                        }
                    }
                } else {
                    self.fetchLRCLIBLyrics(title: meta.title, artist: meta.artist ?? "", album: meta.album ?? "", duration: meta.duration ?? 0) { lyricsFile in
                        guard self.isActiveDownload(token) else {
                            if let lyricsFile {
                                try? FileManager.default.removeItem(at: lyricsFile)
                            }
                            try? FileManager.default.removeItem(at: localAudio)
                            if let localCover {
                                try? FileManager.default.removeItem(at: localCover)
                            }
                            return
                        }
                        let subs = lyricsFile.map { [(lang: "lyrics", url: $0)] } ?? []
                        do {
                            try self.saveSongFiles(title: stableIdentifier, meta: meta, localCover: localCover, localAudio: localAudio, localSubtitles: subs)
                            self.debugLog("Saved playlist track: \(displayIdentifier) [\(stableIdentifier)]")
                            DispatchQueue.main.async {
                                guard self.isActiveDownload(token) else { return }
                                self.downloadedCount += 1
                                self.downloadedTrackTitles.append(stableIdentifier)
                            }
                        } catch {
                            print("Failed to save \(displayIdentifier) [\(stableIdentifier)]: \(error)")
                            self.debugLog("Failed saving playlist track without YouTube subs: \(displayIdentifier) [\(stableIdentifier)] error=\(error.localizedDescription)")
                            DispatchQueue.main.async { self.failedTrackTitles.append(safeTitle) }
                        }
                        self.downloadPlaylistTracks(videos, index: index + 1, token: token)
                    }
                }
            }
        }

        if let validCoverURL = coverURL {
            download(from: validCoverURL, kind: .image, suppressUserFacingError: true, token: token) { localCover in
                guard self.isActiveDownload(token) else {
                    if let localCover {
                        try? FileManager.default.removeItem(at: localCover)
                    }
                    return
                }
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
        let existingPlaylist = dataManager.fetchAllPlaylists().first {
            $0.title.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare(pName.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
        }
        
        let matchingSongs = allSongs.filter { downloadedTrackTitles.contains($0.id) }
        guard !matchingSongs.isEmpty else { return }
        
        // Pick the first downloaded song's cover to represent the playlist locally
        let firstSongCover = matchingSongs.first?.coverImagePath

        if let existingPlaylist {
            if existingPlaylist.coverImagePath == nil {
                existingPlaylist.coverImagePath = firstSongCover
                try? dataManager.modelContext?.save()
            }

            for song in matchingSongs {
                dataManager.addSong(song, to: existingPlaylist)
            }
            return
        }

        if let newPlaylist = dataManager.createPlaylist(title: pName, coverImagePath: firstSongCover) {
            for song in matchingSongs {
                dataManager.addSong(song, to: newPlaylist)
            }
        }
    }

    private func playlistCompletionMessage() -> String {
        let failedCount = failedTrackTitles.count
        if failedCount == 0 && skippedCount == 0 {
            return "✅ Playlist download complete! (\(downloadedCount) tracks)"
        }
        return "✅ Playlist finished. \(downloadedCount) downloaded, \(skippedCount) skipped, \(failedCount) failed."
    }

    struct VideoInfo: Decodable {
        let id: String
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
    func downloadAllSubtitles(_ subs: [String: String], token: UUID, completion: @escaping ([(lang: String, url: URL)]) -> Void) {
        let group = DispatchGroup()
        var results: [(lang: String, url: URL)] = []
        let lock = NSLock()

        for (lang, urlStr) in subs {
            guard let url = URL(string: urlStr) else { continue }
            group.enter()
            download(from: url, kind: .subtitle, retries: 0, suppressUserFacingError: true, token: token) { localFile in
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
        request.timeoutInterval = lrclibRequestTimeout

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
        request.timeoutInterval = lrclibRequestTimeout

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

    enum DownloadAssetKind {
        case audio
        case image
        case subtitle

        var debugLabel: String {
            switch self {
            case .audio:
                return "audio"
            case .image:
                return "image"
            case .subtitle:
                return "subtitle"
            }
        }
    }

    private func normalizeYouTubeLink(_ link: String) -> String {
        guard var components = URLComponents(string: link), let host = components.host?.lowercased() else {
            return link
        }

        if host.contains("music.youtube.com") {
            components.scheme = "https"
            components.host = "www.youtube.com"

            let items = components.queryItems ?? []
            let playlistID = items.first(where: { $0.name == "list" })?.value
            let videoID = items.first(where: { $0.name == "v" })?.value
            let index = items.first(where: { $0.name == "index" })?.value

            if let playlistID, !playlistID.isEmpty, let videoID, !videoID.isEmpty {
                components.path = "/watch"
                components.queryItems = [
                    URLQueryItem(name: "v", value: videoID),
                    URLQueryItem(name: "list", value: playlistID)
                ] + (index.map { [URLQueryItem(name: "index", value: $0)] } ?? [])
            } else if let playlistID, !playlistID.isEmpty {
                components.path = "/playlist"
                components.queryItems = [URLQueryItem(name: "list", value: playlistID)]
            } else if let videoID, !videoID.isEmpty {
                components.path = "/watch"
                components.queryItems = [URLQueryItem(name: "v", value: videoID)]
            }
        }

        return components.url?.absoluteString ?? link
    }

    private func stableSongIdentifier(for meta: VideoInfo) -> String {
        meta.id.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isActiveDownload(_ token: UUID) -> Bool {
        activeDownloadToken == token
    }

    private func normalizedDuplicateKey(_ value: String?) -> String {
        guard let value else { return "" }

        return value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: " - topic", with: "")
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func legacySongFolderName(for meta: VideoInfo) -> String? {
        let artist = normalizedDuplicateKey(meta.artist)
        let title = normalizedDuplicateKey(meta.title)
        guard !artist.isEmpty, !title.isEmpty else { return nil }
        return "\(artist) - \(title)".precomposedStringWithCanonicalMapping
    }

    private func isDuplicateSong(meta: VideoInfo, stableIdentifier: String, existingSongs: [SongData]) -> Bool {
        let normalizedTitle = normalizedDuplicateKey(meta.title)
        let normalizedArtist = normalizedDuplicateKey(meta.artist ?? "Unknown Artist")

        if existingSongs.contains(where: { song in
            song.id == stableIdentifier || (
                normalizedDuplicateKey(song.title) == normalizedTitle &&
                normalizedDuplicateKey(song.artist) == normalizedArtist
            )
        }) {
            return true
        }

        if songExistsLocally(safeIdentifier: stableIdentifier) {
            return true
        }

        if let legacyFolderName = legacySongFolderName(for: meta), songExistsLocally(safeIdentifier: legacyFolderName) {
            return true
        }

        return false
    }

    func saveSongFiles(title: String, meta: VideoInfo, localCover: URL?, localAudio: URL, localSubtitles: [(lang: String, url: URL)]) throws {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let songsFolder = docs.appendingPathComponent("Songs", isDirectory: true)
        try fm.createDirectory(at: songsFolder, withIntermediateDirectories: true)

        let normalizedTitle = title.precomposedStringWithCanonicalMapping
        let songDir = songsFolder.appendingPathComponent(normalizedTitle, isDirectory: true)
        try fm.createDirectory(at: songDir, withIntermediateDirectories: true)

        let destCover = songDir.appendingPathComponent("\(normalizedTitle).jpg")
        let destAudio = songDir.appendingPathComponent("\(normalizedTitle).m4a")

        if fm.fileExists(atPath: destCover.path) { try fm.removeItem(at: destCover) }
        if fm.fileExists(atPath: destAudio.path) { try fm.removeItem(at: destAudio) }

        if let localCover = localCover, fm.fileExists(atPath: localCover.path) {
            if let imageData = try? Data(contentsOf: localCover), !imageData.isEmpty {
                if let uiImage = UIImage(data: imageData),
                   let jpegData = uiImage.jpegData(compressionQuality: 0.9) {
                    try jpegData.write(to: destCover)
                    debugLog("Saved normalized cover: \(destCover.lastPathComponent)")
                } else {
                    debugLog("Could not decode cover image for \(title), discarding cover")
                }
            }
            try? fm.removeItem(at: localCover)
        }
        try fm.moveItem(at: localAudio, to: destAudio)
        if let audioSize = try? fm.attributesOfItem(atPath: destAudio.path)[.size] as? Int64 {
            debugLog("Saved song files: \(normalizedTitle).m4a -> \(destAudio.path) (\(audioSize) bytes)")
        } else {
            debugLog("Saved song files: \(normalizedTitle).m4a -> \(destAudio.path)")
        }

        // Save each subtitle track with language code: {title}.{lang}.vtt
        for sub in localSubtitles {
            let destSubtitle = songDir.appendingPathComponent("\(title).\(sub.lang).vtt")
            if fm.fileExists(atPath: destSubtitle.path) { try fm.removeItem(at: destSubtitle) }
            try fm.moveItem(at: sub.url, to: destSubtitle)
        }

        // Update SwiftData with explicit upsert and metadata
        DispatchQueue.main.async {
            guard let ctx = dataManager.modelContext else {
                debugLog("⚠️ modelContext unavailable while syncing song metadata for \(title)")
                return
            }

            dataManager.syncSingleSong(folderName: title)

            let descriptor = FetchDescriptor<SongData>(predicate: #Predicate { $0.id == title })
            if let existingSong = (try? ctx.fetch(descriptor))?.first {
                existingSong.title = meta.title
                existingSong.artist = meta.artist ?? "Unknown Artist"
                existingSong.albumTitle = meta.album ?? "Unknown Album"
                existingSong.duration = meta.duration ?? 0
                existingSong.audioFilePath = "Songs/\(title)/\(normalizedTitle).m4a"
                existingSong.coverImagePath = fm.fileExists(atPath: destCover.path) ? "Songs/\(title)/\(normalizedTitle).jpg" : nil
                if let firstSubtitle = localSubtitles.first {
                    existingSong.subtitleFilePath = "Songs/\(title)/\(title).\(firstSubtitle.lang).vtt"
                }
                try? ctx.save()
                debugLog("Updated SwiftData entry for \(title)")
            } else {
                let song = SongData(
                    id: title,
                    title: meta.title,
                    artist: meta.artist ?? "Unknown Artist",
                    albumTitle: meta.album ?? "Unknown Album",
                    audioFilePath: "Songs/\(title)/\(normalizedTitle).m4a",
                    coverImagePath: fm.fileExists(atPath: destCover.path) ? "Songs/\(title)/\(normalizedTitle).jpg" : nil,
                    subtitleFilePath: localSubtitles.first.map { "Songs/\(title)/\(title).\($0.lang).vtt" },
                    duration: meta.duration ?? 0
                )
                ctx.insert(song)
                try? ctx.save()
                debugLog("Inserted SwiftData entry for \(title)")
            }
        }
    }

    func finishSuccess(_ message: String, token: UUID) {
        debugLog("Finished successfully: \(message)")
        DispatchQueue.main.async {
            guard self.isActiveDownload(token) else { return }
            self.activeDownloadToken = nil
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

    func showError(_ title: String, _ message: String, token: UUID) {
        debugLog("Show error [\(title)]: \(message)")
        DispatchQueue.main.async {
            guard self.isActiveDownload(token) else { return }
            self.activeDownloadToken = nil
            self.statusMessage = "❌ \(title): \(message)"
            alertTitle = title
            alertMessage = message
            showAlert = true
            isDownloading = false
            youtubeLink = ""
            
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

    private func beginBackgroundTaskIfNeeded() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask {
            DispatchQueue.main.async {
                self.endBackgroundTask()
            }
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

    private func download(from url: URL, kind: DownloadAssetKind, retries: Int = 3, suppressUserFacingError: Bool = false, token: UUID, completion: @escaping (URL?) -> Void) {
        debugLog("Starting download [\(kind.debugLabel)] \(url.lastPathComponent)")
        let startedAt = Date()
        var task: URLSessionDownloadTask?
        let timeoutWorkItem: DispatchWorkItem?

        let request = downloadRequest(for: url, kind: kind)
        if kind == .audio {
            let workItem = DispatchWorkItem {
                guard self.isActiveDownload(token) else { return }
                self.debugLog("Audio download exceeded \(Int(self.maxAudioDownloadDuration))s, cancelling slow stream: \(url.lastPathComponent)")
                task?.cancel()
            }
            timeoutWorkItem = workItem
            DispatchQueue.global().asyncAfter(deadline: .now() + maxAudioDownloadDuration, execute: workItem)
        } else {
            timeoutWorkItem = nil
        }

        task = Self.urlSession.downloadTask(with: request) { tmp, response, err in
            timeoutWorkItem?.cancel()
            guard self.isActiveDownload(token) else {
                if let tmp {
                    try? FileManager.default.removeItem(at: tmp)
                }
                return
            }
            let failureMessage: String?
            let retryDelay: TimeInterval
            if let err {
                failureMessage = err.localizedDescription
                retryDelay = kind == .audio ? self.audioRetryDelay : 2
            } else if let http = response as? HTTPURLResponse, let tmp {
                failureMessage = self.downloadValidationError(for: tmp, response: http, kind: kind)
                retryDelay = (kind == .audio && http.statusCode == 202) ? self.audioRetryDelay : 2
            } else {
                failureMessage = "Invalid download response."
                retryDelay = kind == .audio ? self.audioRetryDelay : 2
            }

            if let failureMessage {
                self.debugLog("Download issue [\(kind.debugLabel)] \(url.lastPathComponent): \(failureMessage)")
                if retries > 0 {
                    print("Retrying download... \(retries) left for \(url.lastPathComponent)")
                    DispatchQueue.global().asyncAfter(deadline: .now() + retryDelay) {
                        guard self.isActiveDownload(token) else { return }
                        self.download(from: url, kind: kind, retries: retries - 1, suppressUserFacingError: suppressUserFacingError, token: token, completion: completion)
                    }
                } else {
                    if suppressUserFacingError {
                        print("[DEBUG] Download failed for \(url.lastPathComponent): \(failureMessage)")
                    } else {
                        self.showError("Download Failed", failureMessage, token: token)
                    }
                    completion(nil)
                }
                return
            }

            guard let tmp else {
                completion(nil)
                return
            }

            let fm = FileManager.default
            let cacheDir = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
            let mimeType = response?.mimeType?.lowercased() ?? ""
            let persistentTempURL = cacheDir
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(preferredFileExtension(for: kind, mimeType: mimeType, url: url))

            do {
                try fm.moveItem(at: tmp, to: persistentTempURL)
                let bytes = (try? fm.attributesOfItem(atPath: persistentTempURL.path)[.size] as? Int64) ?? 0
                let elapsed = max(Date().timeIntervalSince(startedAt), 0.001)
                if kind == .audio {
                    let bytesPerSecond = Double(bytes) / elapsed
                    let speedLabel = ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .binary)
                    self.debugLog("Downloaded [\(kind.debugLabel)] \(url.lastPathComponent) -> \(persistentTempURL.lastPathComponent) (\(bytes) bytes, \(speedLabel)/s)")
                    if bytesPerSecond < self.slowAudioBytesPerSecond {
                        self.debugLog("Audio stream was slow (\(speedLabel)/s).")
                    }
                } else {
                    self.debugLog("Downloaded [\(kind.debugLabel)] \(url.lastPathComponent) -> \(persistentTempURL.lastPathComponent) (\(bytes) bytes)")
                }
                completion(persistentTempURL)
            } catch {
                print("Failed to validate or save persistent temp file: \(error)")
                self.debugLog("Failed moving downloaded file [\(kind.debugLabel)] \(url.lastPathComponent): \(error.localizedDescription)")
                completion(nil)
            }
        }
        task?.resume()
    }

    private func downloadRequest(for url: URL, kind: DownloadAssetKind) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = kind == .audio ? maxAudioDownloadDuration : 15
        request.setValue(youtubeUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        request.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")

        switch kind {
        case .audio:
            request.setValue("*/*", forHTTPHeaderField: "Accept")
            request.setValue("bytes=0-", forHTTPHeaderField: "Range")
        case .image:
            request.setValue("image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        case .subtitle:
            request.setValue("text/vtt,text/plain,text/xml,application/xml,*/*;q=0.8", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 8
        }

        return request
    }

    private func debugLog(_ message: String) {
        let line = "[\(Self.debugTimestampFormatter.string(from: Date()))] \(message)"
        print("[DEBUG] \(line)")
        NSLog("OWENISAS_DOWNLOAD: %@", line)
        Self.appendDebugLogToFile(line)
        DispatchQueue.main.async {
            self.debugLogLines.append(line)
            if self.debugLogLines.count > 120 {
                self.debugLogLines.removeFirst(self.debugLogLines.count - 120)
            }
        }
    }

    private static let debugLogFileURL: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent("download-debug.log")
    }()

    private static let debugLogQueue = DispatchQueue(label: "download.debug.log")

    private static func appendDebugLogToFile(_ line: String) {
        debugLogQueue.async {
            let url = debugLogFileURL
            guard let data = (line + "\n").data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    private func downloadValidationError(for fileURL: URL, response: HTTPURLResponse, kind: DownloadAssetKind) -> String? {
        let mimeType = response.mimeType?.lowercased() ?? ""
        guard (200..<300).contains(response.statusCode) else {
            return readServerError(from: fileURL, fallback: "Server returned \(response.statusCode).")
        }
        guard mimeTypeIsAccepted(mimeType, for: kind) else {
            return readServerError(from: fileURL, fallback: "Unexpected file type returned by the server.")
        }

        let attr = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)) ?? [:]
        let size = attr[.size] as? Int64 ?? 0
        switch kind {
        case .audio where size < 500_000:
            return "The downloaded audio file was too small to be valid."
        case .image where size < 5_000:
            return "The downloaded cover image was too small to be valid."
        case .subtitle where size == 0:
            return "The subtitle file was empty."
        default:
            return nil
        }
    }

    private func mimeTypeIsAccepted(_ mimeType: String, for kind: DownloadAssetKind) -> Bool {
        switch kind {
        case .audio:
            return mimeType.hasPrefix("audio/") || mimeType == "application/octet-stream"
        case .image:
            return mimeType.hasPrefix("image/")
        case .subtitle:
            return mimeType.contains("vtt") || mimeType.hasPrefix("text/") || mimeType.contains("xml") || mimeType == "application/octet-stream"
        }
    }

    private func preferredFileExtension(for kind: DownloadAssetKind, mimeType: String, url: URL) -> String {
        switch kind {
        case .audio:
            return "m4a"
        case .image:
            if mimeType.contains("png") { return "png" }
            if mimeType.contains("webp") { return "webp" }
            if mimeType.contains("gif") { return "gif" }
            return url.pathExtension.isEmpty ? "jpg" : url.pathExtension
        case .subtitle:
            return mimeType.contains("xml") ? "srv1" : "vtt"
        }
    }

    private func readServerError(from fileURL: URL, fallback: String) -> String {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return fallback }
        if let text = String(data: data.prefix(512), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return text
        }
        return fallback
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

struct DownloadError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

