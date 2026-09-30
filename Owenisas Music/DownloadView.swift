#if !APP_STORE
import SwiftUI
import SwiftData
import UserNotifications
import AVFoundation
import BackgroundTasks

struct DownloadView: View {
    @State private var youtubeLink = ""
    @State private var isDownloading = false
    @State private var statusMessage = ""
    @State private var debugLogLines: [String] = []
    @State private var showDetails = false
    @State private var downloadProgress: Double = 0
    @State private var downloadedCount = 0
    @State private var skippedCount = 0
    @State private var totalCount = 0
    @State private var failedTrackTitles: [String] = []
    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var alertOffersRetry = false
    @FocusState private var linkFieldIsFocused: Bool

    @State private var activeJob: DownloadJob? = nil
    @State private var playlistChoice: PlaylistChoice? = nil
    @State private var showPlaylistChoice = false
    /// Keeps the whole session (one job, or several queued links in a row)
    /// running in the background. See `BackgroundDownloadActivity`.
    @State private var backgroundActivity: BackgroundDownloadActivity? = nil

    @ObservedObject var dataManager = DataManager.shared
    /// Links from the share extension / `owenisas://download?url=`.
    @ObservedObject private var requests = DownloadRequestCenter.shared
    @Environment(\.modelContext) private var environmentModelContext

    private let desktopUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15"

    /// Ephemeral (no shared cookie jar / cache): googlevideo answers 403 when
    /// the www.youtube.com cookie jar is attached. 15 s idle / 45 s wall per
    /// request; the first audio chunk also has a 12 s zero-byte watchdog.
    static let urlSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 45
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    struct PlaylistChoice {
        let videoId: String
        let page: PlaylistPage
        let job: DownloadJob
    }

    enum TrackOutcome {
        case downloaded(songID: String, title: String)
        case alreadyInLibrary(songID: String, title: String, lyricsAdded: Bool)
        case failed(TrackFailure)
    }

    struct TrackFailure: Error {
        var title: String?
        let alertTitle: String
        let message: String
        let retryable: Bool

        static let cancelled = TrackFailure(title: nil, alertTitle: "Cancelled", message: "The download was cancelled.", retryable: false)
    }

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

                    if !youtubeLink.isEmpty && !isDownloading {
                        Button {
                            youtubeLink = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel("Clear link")
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
                .disabled(isDownloading)

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

                        if !failedTrackTitles.isEmpty {
                            failedTracksList
                        }

                        if !requests.queue.isEmpty {
                            Text(requests.queue.count == 1 ? "1 more shared link queued" : "\(requests.queue.count) more shared links queued")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("downloadQueueCount")
                        }

                        if isDownloading {
                            Button(role: .destructive) {
                                cancelDownload()
                            } label: {
                                Label("Cancel", systemImage: "xmark.circle")
                                    .font(.subheadline.bold())
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)
                            .accessibilityIdentifier("cancelDownloadButton")
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
                    detailsSection
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
            if alertOffersRetry {
                Button("Retry") { startDownload() }
                Button("OK", role: .cancel) { }
            } else {
                Button("OK") { }
            }
        } message: {
            Text(alertMessage)
        }
        .confirmationDialog(
            "This song is part of a playlist",
            isPresented: $showPlaylistChoice,
            titleVisibility: .visible,
            presenting: playlistChoice
        ) { choice in
            Button("Just this song") { resolvePlaylistChoice(choice, wholePlaylist: false) }
            Button("Whole playlist (\(choice.page.entries.count))") { resolvePlaylistChoice(choice, wholePlaylist: true) }
            Button("Cancel", role: .cancel) {
                playlistChoice = nil
                cancelDownload()
            }
        } message: { choice in
            Text("\"\(choice.page.title)\" has \(choice.page.entries.count) songs.")
        }
        .onChange(of: showPlaylistChoice) { _, isShown in
            guard !isShown else { return }
            // Dismissed by tapping outside: treat as Cancel. Button actions
            // clear `playlistChoice` before this runs.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if playlistChoice != nil {
                    playlistChoice = nil
                    cancelDownload()
                }
            }
        }
        .onTapGesture {
            linkFieldIsFocused = false
        }
        .onAppear {
            if dataManager.modelContext == nil {
                dataManager.configure(with: environmentModelContext)
            }
            startNextQueuedIfIdle()
        }
        .onChange(of: requests.queue.map(\.id)) { _, _ in
            startNextQueuedIfIdle()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            // Under a running continued-processing task iOS keeps the app
            // going, so later network errors are real errors, not suspension.
            if !(backgroundActivity?.isContinuedRunning ?? false) {
                activeJob?.noteBackgrounded()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            // The legacy background grant may have expired; re-arm it for the
            // next trip to the background while the session is still running.
            if activeJob != nil {
                backgroundActivity?.rearmLegacyIfNeeded()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // Queued links wait for the foreground once background time is gone.
            startNextQueuedIfIdle()
        }
    }

    private var failedTracksList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Failed (\(failedTrackTitles.count))")
                .font(.caption.bold())
                .foregroundStyle(.red)
            ForEach(Array(failedTrackTitles.prefix(8).enumerated()), id: \.offset) { _, title in
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if failedTrackTitles.count > 8 {
                Text("and \(failedTrackTitles.count - 8) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var detailsSection: some View {
        DisclosureGroup(isExpanded: $showDetails) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
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
                        ForEach(Array(debugLogLines.suffix(80).enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
            .padding(.top, 8)
        } label: {
            Text("Show details")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(UIColor.secondarySystemBackground))
        )
        .padding(.horizontal, 16)
        .accessibilityIdentifier("downloadDetails")
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

    // MARK: - Starting, cancelling, finishing

    /// The Download button (and Retry): the link in the text field.
    func startDownload() {
        startDownload(link: youtubeLink, choice: nil, requestID: nil)
    }

    /// `choice` comes from the share extension ("Just this song" / "Whole
    /// playlist"); nil asks, as for a pasted link. `requestID` ties the job to
    /// a queued `DownloadRequestCenter` request, which is finished with it.
    private func startDownload(link rawLink: String, choice: SharedInbox.LinkRequest.Choice?, requestID: UUID?) {
        guard !isDownloading else { return }
        let link = rawLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else {
            if let requestID { requests.finish(requestID) }
            return
        }
        linkFieldIsFocused = false

        let kind = YouTubeLinkClassifier.classify(link)
        if kind == .invalid {
            statusMessage = "That doesn't look like a YouTube link."
            presentAlert(title: "Invalid Link", message: "Paste a youtube.com, youtu.be or music.youtube.com link.", offerRetry: false)
            if let requestID {
                requests.finish(requestID)
                DispatchQueue.main.async { startNextQueuedIfIdle() }
            }
            return
        }

        let job = beginJob(requestID: requestID)
        switch kind {
        case .video(let videoId):
            debugLog("Start: single video \(videoId)")
            launch(job) { await runSingle(videoId: videoId, job: job) }
        case .playlist(let listId):
            debugLog("Start: playlist \(listId)")
            launch(job) { await runPlaylist(playlistId: listId, prefetched: nil, job: job) }
        case .videoInPlaylist(let videoId, let listId, let isMix):
            if isMix {
                debugLog("Start: \(videoId) shared from mix \(listId); downloading just this song")
                launch(job) { await runSingle(videoId: videoId, job: job) }
            } else if choice == .song {
                debugLog("Start: \(videoId) inside playlist \(listId); shared as just this song")
                launch(job) { await runSingle(videoId: videoId, job: job) }
            } else if choice == .playlist {
                debugLog("Start: \(videoId) inside playlist \(listId); shared as the whole playlist")
                launch(job) { await askSongOrPlaylist(videoId: videoId, playlistId: listId, preset: .playlist, job: job) }
            } else {
                debugLog("Start: \(videoId) inside playlist \(listId); asking song or playlist")
                launch(job) { await askSongOrPlaylist(videoId: videoId, playlistId: listId, preset: nil, job: job) }
            }
        case .invalid:
            break
        }
    }

    /// Next queued shared link, when nothing else is running. In the
    /// background a new job only starts under the session's existing grant.
    private func startNextQueuedIfIdle() {
        guard !isDownloading, activeJob == nil, playlistChoice == nil else { return }
        guard requests.hasPending else {
            endBackgroundActivity(success: true)
            return
        }
        if UIApplication.shared.applicationState == .background && !(backgroundActivity?.isAlive ?? false) {
            return
        }
        guard let request = requests.takeNext() else { return }
        youtubeLink = request.link
        startDownload(link: request.link, choice: request.choice, requestID: request.id)
    }

    private func beginJob(requestID: UUID? = nil) -> DownloadJob {
        activeJob?.cancel()
        let job = DownloadJob()
        job.requestID = requestID
        activeJob = job
        isDownloading = true
        statusMessage = "Fetching video info…"
        downloadProgress = 0
        downloadedCount = 0
        skippedCount = 0
        totalCount = 0
        failedTrackTitles = []
        debugLogLines = []
        beginBackgroundActivity()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        DownloadTempFiles.sweepStale()
        return job
    }

    private func launch(_ job: DownloadJob, _ operation: @escaping @MainActor () async -> Void) {
        let task = Task { @MainActor in await operation() }
        job.onCancel { task.cancel() }
    }

    private func isActive(_ job: DownloadJob) -> Bool {
        activeJob === job && !job.isCancelled
    }

    enum CancelReason {
        case user
        /// iOS (or the user, from the system progress UI) stopped the
        /// background continued-processing task.
        case backgroundExpired
    }

    private func cancelDownload(reason: CancelReason = .user) {
        guard let job = activeJob else { return }
        job.cancel()
        job.cleanupTemps()
        activeJob = nil
        playlistChoice = nil
        isDownloading = false
        let stopped = reason == .user ? "Cancelled" : "Stopped in the background"
        if totalCount > 1 {
            if let name = job.playlistName, !job.savedSongIDs.isEmpty {
                addToAutoPlaylist(name: name, songIDs: job.savedSongIDs)
            }
            statusMessage = "\(stopped) after \(processedCount) of \(totalCount) tracks. \(downloadedCount) downloaded."
        } else {
            statusMessage = reason == .user ? "Download cancelled." : "Download stopped in the background."
        }
        debugLog("Cancelled (\(reason)): \(statusMessage)")
        if downloadedCount > 0 {
            NotificationCenter.default.post(name: .init("SongsFolderChanged"), object: nil)
        }
        if reason == .backgroundExpired {
            sendCompletionNotification(message: statusMessage)
        }
        jobEnded(job, success: false)
    }

    private func finish(_ job: DownloadJob, message: String) {
        guard isActive(job) else { return }
        let inBackground = UIApplication.shared.applicationState != .active
        debugLog("Finished\(inBackground ? " (app in background)" : ""): \(message)")
        activeJob = nil
        isDownloading = false
        statusMessage = message
        downloadProgress = 1
        youtubeLink = ""
        NotificationCenter.default.post(name: .init("SongsFolderChanged"), object: nil)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        if !inBackground {
            sendCompletionNotification(message: message)
        } else {
            sendCompletionNotification(message: BackgroundDownloadText.completionBody(
                downloaded: downloadedCount, alreadyInLibrary: skippedCount, failed: failedTrackTitles.count,
                singleTitle: totalCount == 1 ? job.currentTrackTitle : nil))
        }
        jobEnded(job, success: true)
    }

    /// Keeps `youtubeLink` so Retry downloads the same link again.
    private func fail(_ job: DownloadJob, title: String, message: String, retry: Bool) {
        guard isActive(job) else { return }
        debugLog("Show error [\(title)]: \(message)")
        activeJob = nil
        isDownloading = false
        statusMessage = "\(title): \(message)"
        presentAlert(title: title, message: message, offerRetry: retry)
        sendCompletionNotification(message: "\(title): \(message)")
        jobEnded(job, success: false)
    }

    /// Every job ends here: the queued request leaves the inbox, and the
    /// background session either carries over to the next queued link or ends.
    private func jobEnded(_ job: DownloadJob, success: Bool) {
        if let requestID = job.requestID {
            requests.finish(requestID)
        }
        if requests.hasPending, let activity = backgroundActivity, activity.isAlive {
            activity.prepareForNextRequest()
        } else {
            endBackgroundActivity(success: success)
        }
        DispatchQueue.main.async { startNextQueuedIfIdle() }
    }

    private func presentAlert(title: String, message: String, offerRetry: Bool) {
        alertTitle = title
        alertMessage = message
        alertOffersRetry = offerRetry
        showAlert = true
    }

    private func setStatus(_ job: DownloadJob, _ message: String) {
        guard isActive(job) else { return }
        statusMessage = message
    }

    private func setTrackProgress(_ job: DownloadJob, index: Int, count: Int, fraction: Double) {
        guard isActive(job) else { return }
        let value = DownloadProgressMath.overall(index: index, count: count, trackFraction: fraction)
        if value > downloadProgress {
            downloadProgress = value
            backgroundActivity?.setFraction(value)
        }
    }

    /// Title/subtitle of the system progress UI (iOS 26+), refreshed when the
    /// job learns its name and as tracks complete.
    private func refreshBackgroundText(_ job: DownloadJob) {
        guard isActive(job), let activity = backgroundActivity else { return }
        activity.update(
            title: BackgroundDownloadText.title(playlistName: job.playlistName, trackTitle: job.currentTrackTitle),
            subtitle: BackgroundDownloadText.subtitle(processed: processedCount, total: totalCount, failed: failedTrackTitles.count)
        )
    }

    // MARK: - Single video

    private func runSingle(videoId: String, job: DownloadJob) async {
        totalCount = 1
        setStatus(job, "Fetching video info…")
        let resolved = await resolveTrack(videoId: videoId, job: job)
        guard isActive(job) else { return }
        if case .success(let info) = resolved {
            job.currentTrackTitle = displayTitle(info.title)
            refreshBackgroundText(job)
        }
        let outcome = await processTrack(videoId: videoId, fallbackTitle: nil, resolved: resolved,
                                         index: 0, count: 1, playlistCover: nil, job: job)
        guard isActive(job) else { return }
        switch outcome {
        case .downloaded(_, let title):
            downloadedCount = 1
            finish(job, message: "Downloaded \"\(title)\".")
        case .alreadyInLibrary(_, let title, let lyricsAdded):
            skippedCount = 1
            finish(job, message: lyricsAdded
                   ? "\"\(title)\" is already in your library. Added its missing lyrics."
                   : "\"\(title)\" is already in your library.")
        case .failed(let failure):
            fail(job, title: failure.alertTitle, message: failure.message, retry: failure.retryable)
        }
    }

    // MARK: - Song vs playlist

    /// `preset == .playlist` (chosen in the share sheet) skips the question;
    /// a playlist that can't be listed still falls back to the song.
    private func askSongOrPlaylist(videoId: String, playlistId: String, preset: SharedInbox.LinkRequest.Choice?,
                                   job: DownloadJob) async {
        setStatus(job, "Checking the playlist…")
        let page: PlaylistPage?
        do {
            page = try await fetchPlaylist(playlistId: playlistId, job: job)
        } catch {
            guard isActive(job) else { return }
            debugLog("Playlist lookup failed (\(error.localizedDescription)); downloading just the song")
            page = nil
        }
        guard isActive(job) else { return }
        guard let page, page.entries.count > 1 else {
            await runSingle(videoId: videoId, job: job)
            return
        }
        if preset == .playlist {
            debugLog("Whole playlist chosen when shared (\(page.entries.count))")
            await runPlaylist(playlistId: "", prefetched: page, job: job)
            return
        }
        playlistChoice = PlaylistChoice(videoId: videoId, page: page, job: job)
        statusMessage = "Download just this song, or the whole playlist?"
        showPlaylistChoice = true
    }

    private func resolvePlaylistChoice(_ choice: PlaylistChoice, wholePlaylist: Bool) {
        playlistChoice = nil
        guard isActive(choice.job) else { return }
        let job = choice.job
        if wholePlaylist {
            debugLog("User chose the whole playlist (\(choice.page.entries.count))")
            launch(job) { await runPlaylist(playlistId: "", prefetched: choice.page, job: job) }
        } else {
            debugLog("User chose just this song")
            launch(job) { await runSingle(videoId: choice.videoId, job: job) }
        }
    }

    // MARK: - Playlist

    private func runPlaylist(playlistId: String, prefetched: PlaylistPage?, job: DownloadJob) async {
        setStatus(job, "Fetching playlist info…")
        let page: PlaylistPage
        if let prefetched {
            page = prefetched
        } else {
            do {
                page = try await fetchPlaylist(playlistId: playlistId, job: job)
            } catch {
                guard isActive(job) else { return }
                fail(job, title: "Playlist Error", message: "Couldn't read this playlist: \(error.localizedDescription)", retry: true)
                return
            }
        }
        guard isActive(job) else { return }
        guard !page.entries.isEmpty else {
            fail(job, title: "Playlist Error", message: "This playlist is empty, private, or an auto-generated mix that can't be listed.", retry: false)
            return
        }

        let entries = page.entries
        totalCount = entries.count
        job.playlistName = page.title
        refreshBackgroundText(job)
        debugLog("Downloading playlist \"\(page.title)\": \(entries.count) tracks")

        var nextResolve: Task<Result<VideoInfo, TrackFailure>, Never>? = nil
        for (index, entry) in entries.enumerated() {
            guard isActive(job) else { break }
            setStatus(job, "(\(index + 1)/\(entries.count)) \(entry.title ?? "Fetching track info…")")
            sendProgressNotification(message: "Downloading \(index + 1) of \(entries.count)\n\(entry.title ?? entry.videoId)")

            let resolved: Result<VideoInfo, TrackFailure>
            if let pending = nextResolve {
                resolved = await pending.value
            } else {
                resolved = await resolveTrack(videoId: entry.videoId, job: job)
            }
            nextResolve = nil
            guard isActive(job) else { break }

            // Resolve the next track while this one downloads.
            if index + 1 < entries.count {
                let nextID = entries[index + 1].videoId
                let task = Task { @MainActor in await resolveTrack(videoId: nextID, job: job) }
                job.onCancel { task.cancel() }
                nextResolve = task
            }

            let outcome = await processTrack(videoId: entry.videoId, fallbackTitle: entry.title, resolved: resolved,
                                             index: index, count: entries.count, playlistCover: page.coverUrl, job: job)
            guard isActive(job) else { break }
            switch outcome {
            case .downloaded(let songID, _):
                downloadedCount += 1
                job.savedSongIDs.append(songID)
            case .alreadyInLibrary(let songID, let title, _):
                skippedCount += 1
                job.savedSongIDs.append(songID)
                debugLog("Already in library: \(title)")
            case .failed(let failure):
                let title = failure.title ?? entry.title ?? entry.videoId
                failedTrackTitles.append(title)
                debugLog("Track failed: \(title): \(failure.message)")
            }
            refreshBackgroundText(job)
        }
        nextResolve?.cancel()
        guard isActive(job) else { return }

        addToAutoPlaylist(name: page.title, songIDs: job.savedSongIDs)
        if downloadedCount == 0 && skippedCount == 0 {
            fail(job, title: "Playlist Failed", message: "None of the \(entries.count) tracks could be downloaded.", retry: true)
        } else {
            finish(job, message: playlistSummary())
        }
    }

    private func playlistSummary() -> String {
        let failed = failedTrackTitles.count
        if failed == 0 && skippedCount == 0 {
            return "Playlist complete: \(downloadedCount) tracks downloaded."
        }
        var parts = ["\(downloadedCount) downloaded"]
        if skippedCount > 0 { parts.append("\(skippedCount) already in library") }
        if failed > 0 { parts.append("\(failed) failed") }
        return "Playlist finished: " + parts.joined(separator: ", ") + "."
    }

    private func fetchPlaylist(playlistId: String, job: DownloadJob) async throws -> PlaylistPage {
        var components = URLComponents(string: "https://www.youtube.com/playlist")!
        components.queryItems = [
            URLQueryItem(name: "list", value: playlistId),
            URLQueryItem(name: "hl", value: "en"),
            URLQueryItem(name: "gl", value: "US"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(desktopUserAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        var firstPage: PlaylistPageParser.FirstPage?
        var lastError: Error = DownloadError(message: "The playlist page couldn't be read.")
        for attempt in 1...2 {
            try Task.checkCancellation()
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if let html = String(data: data, encoding: .utf8),
                   let parsed = PlaylistPageParser.firstPage(fromHTML: html) {
                    firstPage = parsed
                    break
                }
                debugLog("Playlist page not parseable (HTTP \(code), attempt \(attempt))")
            } catch let error as URLError where error.code != .cancelled {
                lastError = error
                debugLog("Playlist page request failed: \(error.localizedDescription) (attempt \(attempt))")
            }
            if attempt == 1 { try await Task.sleep(nanoseconds: 1_500_000_000) }
        }
        guard let firstPage else { throw lastError }

        var seen = Set<String>()
        var entries: [PlaylistEntry] = []
        for entry in firstPage.entries where seen.insert(entry.videoId).inserted {
            entries.append(entry)
        }

        var token = firstPage.continuation
        var seenTokens = Set<String>()
        var pages = 1
        while let current = token, !current.isEmpty, seenTokens.insert(current).inserted, pages < 50,
              let apiKey = firstPage.apiKey {
            try Task.checkCancellation()
            guard let payload = await fetchBrowseContinuation(apiKey: apiKey, context: firstPage.context, token: current) else { break }
            let contents = PlaylistPageParser.continuationContents(fromBrowse: payload)
            let more = PlaylistPageParser.entries(from: contents)
            for entry in more where seen.insert(entry.videoId).inserted {
                entries.append(entry)
            }
            token = PlaylistPageParser.continuationToken(from: contents)
            pages += 1
            debugLog("Playlist continuation page \(pages): \(more.count) entries")
        }

        let title = firstPage.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let page = PlaylistPage(title: title.isEmpty ? "Playlist" : title, coverUrl: firstPage.coverUrl, entries: entries)
        debugLog("Playlist \"\(page.title)\": \(entries.count) unique entries across \(pages) page(s)")
        return page
    }

    private func fetchBrowseContinuation(apiKey: String, context: [String: Any]?, token: String) async -> [String: Any]? {
        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/browse?prettyPrint=false&key=\(apiKey)") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(desktopUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Referer")
        // The header must match the context's client version: an old
        // hard-coded version is answered with HTTP 400.
        let clientVersion = ((context?["client"] as? [String: Any])?["clientVersion"] as? String) ?? "2.20260922.01.00"
        request.setValue("1", forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(clientVersion, forHTTPHeaderField: "X-Youtube-Client-Version")
        let browseContext = context ?? [
            "client": [
                "clientName": "WEB",
                "clientVersion": clientVersion,
                "hl": "en",
                "gl": "US",
            ] as [String: Any],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "context": browseContext,
            "continuation": token,
        ])
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                debugLog("Playlist continuation failed: HTTP \(code)")
                return nil
            }
            return payload
        } catch {
            debugLog("Playlist continuation failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - One track

    private func resolveTrack(videoId: String, job: DownloadJob) async -> Result<VideoInfo, TrackFailure> {
        do {
            let (info, client) = try await YouTubeClient.shared.resolveAudio(
                videoId: videoId, log: backgroundLogger(prefix: "Resolve \(videoId) "))
            debugLog("Resolved \(videoId) via \(client): \(info.captionTracks.count) caption tracks, language \(info.language ?? "unknown")")
            return .success(info)
        } catch let error as YouTubeFetchError {
            debugLog("Resolve failed for \(videoId): \(error.message)")
            let title: String
            switch error.kind {
            case .offline: title = "You're Offline"
            case .unavailable: title = "Video Unavailable"
            case .blocked: title = "Blocked by YouTube"
            case .unsupportedFormat: title = "Unsupported Format"
            case .network: title = "Network Error"
            case .other: title = "Download Failed"
            }
            let retry = error.kind != .unavailable && error.kind != .unsupportedFormat
            return .failure(TrackFailure(title: nil, alertTitle: title, message: error.message, retryable: retry))
        } catch {
            return .failure(.cancelled)
        }
    }

    private func processTrack(videoId: String, fallbackTitle: String?, resolved: Result<VideoInfo, TrackFailure>,
                              index: Int, count: Int, playlistCover: String?, job: DownloadJob) async -> TrackOutcome {
        defer { job.cleanupTemps() }

        let meta: VideoInfo
        switch resolved {
        case .failure(var failure):
            failure.title = failure.title ?? fallbackTitle ?? videoId
            return .failed(failure)
        case .success(let info):
            meta = info
        }

        let title = displayTitle(meta.title)
        let prefix = count > 1 ? "(\(index + 1)/\(count)) " : ""
        setTrackProgress(job, index: index, count: count, fraction: DownloadProgressMath.resolvedFraction)
        setStatus(job, "\(prefix)Downloading \"\(title)\"…")
        if count == 1 { sendProgressNotification(message: "Downloading: \(title)") }

        // Already in the library? Only fill in missing lyrics.
        if let existingID = libraryMatch(for: meta, job: job) {
            debugLog("Already in library: \(title) [\(existingID)]")
            let lyricsAdded = await addMissingLyricsIfNeeded(songID: existingID, meta: meta, job: job)
            setTrackProgress(job, index: index, count: count, fraction: 1)
            return .alreadyInLibrary(songID: existingID, title: title, lyricsAdded: lyricsAdded)
        }

        // Cover (track thumbnail, else the playlist's cover).
        let coverString = !meta.coverUrl.isEmpty ? meta.coverUrl : (playlistCover ?? "")
        var coverTemp: URL? = nil
        if !coverString.isEmpty, let coverURL = URL(string: coverString) {
            coverTemp = await downloadSmallFile(from: coverURL, kind: .image, job: job)
        }
        guard isActive(job) else { return .failed(.cancelled) }
        setTrackProgress(job, index: index, count: count, fraction: DownloadProgressMath.coverFraction)

        // Audio.
        guard let audioURL = URL(string: meta.audioUrl) else {
            return .failed(TrackFailure(title: title, alertTitle: "Download Failed", message: "YouTube returned an invalid audio URL.", retryable: true))
        }
        let audioTemp: URL
        do {
            audioTemp = try await downloadAudio(from: audioURL, job: job) { fraction in
                setTrackProgress(job, index: index, count: count, fraction: DownloadProgressMath.audioFraction(fraction))
            }
        } catch let error as AudioDownloadError {
            if error == .cancelled { return .failed(.cancelled) }
            debugLog("Audio failed for \(title): \(error.logDescription)")
            return .failed(TrackFailure(title: title, alertTitle: error.alertTitle, message: error.userMessage, retryable: error.isRetryable))
        } catch {
            return .failed(TrackFailure(title: title, alertTitle: "Download Failed", message: error.localizedDescription, retryable: true))
        }
        guard isActive(job) else { return .failed(.cancelled) }
        setTrackProgress(job, index: index, count: count, fraction: DownloadProgressMath.audioDoneFraction)

        // Captions (original language + English) and LRCLIB lyrics.
        setStatus(job, "\(prefix)Fetching lyrics for \"\(title)\"…")
        let lyricFiles = await fetchLyricFiles(for: meta, skip: [], job: job)
        guard isActive(job) else { return .failed(.cancelled) }
        setTrackProgress(job, index: index, count: count, fraction: DownloadProgressMath.lyricsFraction)

        // Save to Documents/Songs/<videoId>/ off the main thread, then index
        // only this folder.
        let folderID = stableID(for: meta)
        let logger = backgroundLogger()
        do {
            let saved = try await Task.detached(priority: .userInitiated) {
                try SongFileSaver.save(folderID: folderID, meta: meta, cover: coverTemp, audio: audioTemp,
                                       subtitles: lyricFiles, log: logger)
            }.value
            indexSavedSong(saved, meta: meta, job: job)
            setTrackProgress(job, index: index, count: count, fraction: 1)
            debugLog("Saved \(title) [\(saved.folderID)] with \(lyricFiles.count) lyric file(s)")
            return .downloaded(songID: saved.folderID, title: title)
        } catch {
            debugLog("Save failed for \(title): \(error.localizedDescription)")
            return .failed(TrackFailure(title: title, alertTitle: "Save Error", message: "The song couldn't be saved: \(error.localizedDescription)", retryable: true))
        }
    }

    private func downloadAudio(from url: URL, job: DownloadJob, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        let dest = DownloadTempFiles.newURL(ext: "m4a")
        job.trackTemp(dest)
        debugLog("Starting chunked audio download host=\(url.host ?? "?")")
        let downloader = ChunkedAudioDownloader(
            session: Self.urlSession,
            userAgent: YouTubeClient.safariUserAgent,
            log: backgroundLogger(),
            wasBackgrounded: { job.wasBackgrounded }
        )
        _ = try await downloader.download(from: url, to: dest) { done, total in
            guard let total, total > 0 else { return }
            let fraction = Double(done) / Double(total)
            Task { @MainActor in progress(fraction) }
        }
        return dest
    }

    enum SmallFileKind {
        case image
        case subtitle
    }

    /// Covers are tiny; one data request, validated, written to a tracked temp file.
    private func downloadSmallFile(from url: URL, kind: SmallFileKind, job: DownloadJob) async -> URL? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(YouTubeClient.safariUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(kind == .image ? "image/avif,image/webp,image/*,*/*;q=0.8" : "text/vtt,*/*;q=0.8",
                         forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await Self.urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                debugLog("Cover request failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return nil
            }
            let mime = http.mimeType?.lowercased() ?? ""
            guard mime.hasPrefix("image/"), data.count >= 5_000 else {
                debugLog("Cover rejected (\(mime), \(data.count) bytes)")
                return nil
            }
            let ext = mime.contains("png") ? "png" : mime.contains("webp") ? "webp" : "jpg"
            let dest = DownloadTempFiles.newURL(ext: ext)
            job.trackTemp(dest)
            try data.write(to: dest, options: .atomic)
            return dest
        } catch {
            if !job.isCancelled { debugLog("Cover download failed: \(error.localizedDescription)") }
            return nil
        }
    }

    private func fetchLyricFiles(for meta: VideoInfo, skip: Set<String>, job: DownloadJob) async -> [(lang: String, vtt: String)] {
        let result = await LyricsFetcher.fetchLyricFiles(
            captions: meta.captionTracks,
            language: meta.language,
            title: meta.title,
            artist: meta.artist,
            duration: meta.duration ?? 0,
            skipLanguages: skip,
            includeLRCLIB: job.lrclibNetworkFailures < 2 && !skip.contains("lyrics"),
            log: backgroundLogger()
        )
        if result.lrclibAttempted {
            job.lrclibNetworkFailures = result.lrclibNetworkFailed ? job.lrclibNetworkFailures + 1 : 0
            if job.lrclibNetworkFailures == 2 { debugLog("LRCLIB unreachable twice in a row; skipping it for the rest of this download") }
        }
        return result.files
    }

    // MARK: - Library bookkeeping

    private func stableID(for meta: VideoInfo) -> String {
        meta.id.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func displayTitle(_ title: String) -> String {
        title.replacingOccurrences(of: "/", with: "-")
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Built once per job from the store and the Songs folder names (no
    /// folder contents are read), updated as tracks are saved.
    private func ensureLibraryIndexes(_ job: DownloadJob) {
        if job.libraryIndex == nil {
            var index: [String: String] = [:]
            for song in dataManager.fetchAllSongs() {
                index[LibraryKey.id(song.id)] = song.id
                let key = LibraryKey.titleArtist(song.title, song.artist)
                if index[key] == nil { index[key] = song.id }
            }
            job.libraryIndex = index
        }
        if job.folderIndex == nil {
            var folders: [String: String] = [:]
            let names = (try? FileManager.default.contentsOfDirectory(atPath: SongFileSaver.songsDirectory.path)) ?? []
            for name in names where !name.hasPrefix(".") {
                folders[LibraryKey.folder(name)] = name
            }
            job.folderIndex = folders
        }
    }

    /// The id of the matching playable song already in the library, if any.
    private func libraryMatch(for meta: VideoInfo, job: DownloadJob) -> String? {
        ensureLibraryIndexes(job)
        let stable = stableID(for: meta)
        let candidates = [
            job.libraryIndex?[LibraryKey.id(stable)],
            job.libraryIndex?[LibraryKey.titleArtist(meta.title, meta.artist ?? "Unknown Artist")],
        ].compactMap { $0 }
        for songID in candidates where songIsPlayable(id: songID) {
            return songID
        }
        // On disk but not in the store (store lost or reset): index it now.
        if folderHasPlayableAudio(stable) {
            dataManager.syncSingleSong(folderName: stable)
            job.libraryIndex?[LibraryKey.id(stable)] = stable
            return stable
        }
        if let artist = meta.artist,
           let legacy = job.folderIndex?[LibraryKey.folder("\(artist) - \(meta.title)")],
           folderHasPlayableAudio(legacy) {
            dataManager.syncSingleSong(folderName: legacy)
            return legacy
        }
        return nil
    }

    private func songIsPlayable(id: String) -> Bool {
        guard let ctx = dataManager.modelContext else { return folderHasPlayableAudio(id) }
        let descriptor = FetchDescriptor<SongData>(predicate: #Predicate { $0.id == id })
        guard let song = (try? ctx.fetch(descriptor))?.first else { return false }
        return PlayableLocalAudio.isPlayable(at: song.audioFileURL)
    }

    private func folderHasPlayableAudio(_ folderName: String) -> Bool {
        let dir = SongFileSaver.songsDirectory.appendingPathComponent(folderName.precomposedStringWithCanonicalMapping)
        guard let contents = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return false
        }
        return contents.contains { PlayableLocalAudio.isPlayable(at: $0) }
    }

    /// Re-downloading a song that exists: fetch lyrics if the folder has none.
    private func addMissingLyricsIfNeeded(songID: String, meta: VideoInfo, job: DownloadJob) async -> Bool {
        let folder = SongFileSaver.songsDirectory.appendingPathComponent(songID)
        guard FileManager.default.fileExists(atPath: folder.path) else { return false }
        if songID == stableID(for: meta), SongFolderMetadata.read(from: folder) == nil {
            try? SongFileSaver.metadata(for: meta).write(to: folder)
        }
        guard !LyricsFetcher.folderHasSubtitles(folder) else { return false }
        setStatus(job, "Adding missing lyrics for \"\(displayTitle(meta.title))\"…")
        let files = await fetchLyricFiles(for: meta, skip: [], job: job)
        guard isActive(job), !files.isEmpty else { return false }
        var wrote = false
        for file in files {
            let dest = folder.appendingPathComponent("\(songID).\(file.lang).vtt")
            if FileManager.default.fileExists(atPath: dest.path) { continue }
            do {
                try file.vtt.write(to: dest, atomically: true, encoding: .utf8)
                wrote = true
            } catch {
                debugLog("Couldn't write \(dest.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if wrote {
            Song.invalidateSubtitleCache(forFolder: folder)
            dataManager.syncSingleSong(folderName: songID)
            debugLog("Added \(files.count) lyric file(s) to existing song \(songID)")
        }
        return wrote
    }

    /// Index just the saved folder (no full library scan) so it shows up in
    /// Library right away, and make the row carry the real metadata.
    private func indexSavedSong(_ saved: SongFileSaver.SavedSong, meta: VideoInfo, job: DownloadJob) {
        let folderID = saved.folderID
        dataManager.syncSingleSong(folderName: folderID)
        if let ctx = dataManager.modelContext {
            let descriptor = FetchDescriptor<SongData>(predicate: #Predicate { $0.id == folderID })
            if let song = (try? ctx.fetch(descriptor))?.first {
                song.title = meta.title
                song.artist = meta.artist ?? "Unknown Artist"
                if let album = meta.album { song.albumTitle = album }
                if let duration = meta.duration, duration > 0 { song.duration = duration }
                try? ctx.save()
            } else {
                debugLog("Saved \(folderID) but it isn't playable yet, so it wasn't indexed")
            }
        } else {
            debugLog("Library store unavailable; \(folderID) will appear after the next library sync")
        }
        Song.invalidateSubtitleCache(forFolder: saved.folderURL)
        job.libraryIndex?[LibraryKey.id(folderID)] = folderID
        job.libraryIndex?[LibraryKey.titleArtist(meta.title, meta.artist ?? "Unknown Artist")] = folderID
    }

    /// Adds songs to the playlist named after the YouTube playlist, in
    /// playlist order, including ones that were already in the library.
    private func addToAutoPlaylist(name: String, songIDs: [String]) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !songIDs.isEmpty, let ctx = dataManager.modelContext else { return }
        var seen = Set<String>()
        let orderedIDs = songIDs.filter { seen.insert($0).inserted }
        let descriptor = FetchDescriptor<SongData>(predicate: #Predicate { orderedIDs.contains($0.id) })
        let songs = (try? ctx.fetch(descriptor)) ?? []
        let byID = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let orderedSongs = orderedIDs.compactMap { byID[$0] }
        guard !orderedSongs.isEmpty else {
            debugLog("Playlist \"\(trimmedName)\": none of the \(orderedIDs.count) songs were found in the library")
            return
        }

        let playlist: PlaylistData
        if let existing = dataManager.fetchAllPlaylists().first(where: {
            $0.title.trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedCaseInsensitiveCompare(trimmedName) == .orderedSame
        }) {
            playlist = existing
            if playlist.coverImagePath == nil {
                playlist.coverImagePath = orderedSongs.first?.coverImagePath
            }
        } else if let created = dataManager.createPlaylist(title: trimmedName, coverImagePath: orderedSongs.first?.coverImagePath) {
            playlist = created
        } else {
            return
        }
        dataManager.appendSongsInOrder(orderedSongs, to: playlist)
        debugLog("Playlist \"\(trimmedName)\": \(orderedSongs.count) songs in playlist order")
    }

    // MARK: - Background time

    /// One activity per session: a job started while another session's
    /// activity is still alive (the next queued link) reuses it.
    private func beginBackgroundActivity() {
        if let activity = backgroundActivity, activity.isAlive {
            activity.update(title: BackgroundDownloadText.title(playlistName: nil, trackTitle: nil),
                            subtitle: BackgroundDownloadText.subtitle(processed: 0, total: 0, failed: 0))
            return
        }
        let activity = BackgroundDownloadActivity(
            title: BackgroundDownloadText.title(playlistName: nil, trackTitle: nil),
            subtitle: BackgroundDownloadText.subtitle(processed: 0, total: 0, failed: 0),
            log: backgroundLogger(prefix: "Background: ")
        )
        activity.onLegacyExpired = {
            // iOS is about to suspend the app: later failures of this job are
            // interruptions, not YouTube errors.
            activeJob?.noteBackgrounded()
        }
        activity.onContinuedExpired = {
            // Stopped by iOS or from the system progress UI: same as Cancel
            // (saved tracks stay); queued links wait for the foreground.
            backgroundActivity = nil
            cancelDownload(reason: .backgroundExpired)
        }
        backgroundActivity = activity
        activity.start()
    }

    private func endBackgroundActivity(success: Bool) {
        backgroundActivity?.end(success: success)
        backgroundActivity = nil
    }

    // MARK: - Logging

    private func debugLog(_ message: String) {
        appendDebugLine(DownloadDebugLog.write(message))
    }

    private func appendDebugLine(_ line: String) {
        debugLogLines.append(line)
        if debugLogLines.count > 200 {
            debugLogLines.removeFirst(debugLogLines.count - 200)
        }
    }

    /// For code running off the main actor: file + NSLog now, UI on main.
    private func backgroundLogger(prefix: String = "") -> (String) -> Void {
        return { message in
            let line = DownloadDebugLog.write(prefix + message)
            Task { @MainActor in self.appendDebugLine(line) }
        }
    }

    // MARK: - Notifications

    private func sendProgressNotification(message: String) {
        // iOS 26+ shows the continued-processing progress itself.
        if backgroundActivity?.isContinuedRunning ?? false { return }
        // Single downloads, or every 5th track of a playlist, to avoid spam.
        if totalCount > 1 && processedCount % 5 != 0 { return }

        let content = UNMutableNotificationContent()
        content.title = "Music Download"
        content.body = message
        content.sound = nil

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

// MARK: - Shared-link queue

/// Links handed over by the share extension (App Group inbox) or
/// `owenisas://download?url=…`, downloaded one at a time, in order, by
/// DownloadView. A request leaves the inbox only when its job ends
/// (finished, failed or cancelled), so a download killed with the app is
/// picked up again on the next launch.
@MainActor
final class DownloadRequestCenter: ObservableObject {
    typealias Request = SharedInbox.LinkRequest

    static let shared = DownloadRequestCenter(inbox: SharedInbox.shared)

    /// Waiting requests, oldest first (the running one is `current`).
    @Published private(set) var queue: [Request] = []
    private(set) var current: Request?
    private let inbox: SharedInbox?

    init(inbox: SharedInbox?) {
        self.inbox = inbox
    }

    var hasPending: Bool { !queue.isEmpty }

    /// Adds requests not seen yet (drains repeat on every activation).
    /// Returns how many were new.
    @discardableResult
    func accept(_ requests: [Request]) -> Int {
        var added = 0
        for request in requests where request.id != current?.id && !queue.contains(where: { $0.id == request.id }) {
            queue.append(request)
            added += 1
        }
        return added
    }

    /// Starts the oldest request, unless one is already running.
    func takeNext() -> Request? {
        guard current == nil, !queue.isEmpty else { return nil }
        let next = queue.removeFirst()
        current = next
        return next
    }

    /// The job for `id` ended; drop it here and from the inbox.
    func finish(_ id: UUID) {
        if current?.id == id { current = nil }
        queue.removeAll { $0.id == id }
        inbox?.removeLinks(ids: [id])
    }
}

// MARK: - Background execution

/// `BGContinuedProcessingTask` identifiers: `<bundle id>.download.<uuid>`,
/// matching the Info.plist wildcard `com.Owenisas-Music.download.*`.
enum BackgroundDownloadIdentifier {
    static let permittedPattern = "com.Owenisas-Music.download.*"
    static let prefix = "com.Owenisas-Music.download."

    static func make(_ uuid: UUID = UUID()) -> String {
        prefix + uuid.uuidString
    }

    /// Whether `identifier` fits a `BGTaskSchedulerPermittedIdentifiers`
    /// entry (exact, or `prefix.*` with a non-empty suffix).
    static func matches(_ identifier: String, pattern: String) -> Bool {
        guard pattern.hasSuffix(".*") else { return identifier == pattern }
        let base = String(pattern.dropLast(1))
        return identifier.hasPrefix(base) && identifier.count > base.count
    }
}

/// Progress units reported to the system for one background session. Each
/// job (a queued link, or the typed link) is 1000 units, so a session that
/// runs several queued links in a row never moves backwards.
struct BackgroundDownloadProgress: Equatable {
    static let unitsPerRequest: Int64 = 1000

    private(set) var requestCount = 1
    private(set) var finishedRequests = 0
    private(set) var currentFraction: Double = 0

    var totalUnits: Int64 { Int64(requestCount) * Self.unitsPerRequest }

    var completedUnits: Int64 {
        let current = Int64((currentFraction * Double(Self.unitsPerRequest)).rounded(.down))
        return min(totalUnits, Int64(finishedRequests) * Self.unitsPerRequest + current)
    }

    /// Overall fraction (0…1) of the running job; never goes backwards.
    mutating func update(fraction: Double) {
        let clamped = min(max(fraction.isFinite ? fraction : 0, 0), 1)
        currentFraction = max(currentFraction, clamped)
    }

    /// The running job ended and another queued one follows.
    mutating func startNextRequest() {
        finishedRequests = min(finishedRequests + 1, requestCount)
        requestCount += 1
        currentFraction = 0
    }
}

/// Strings for the system progress UI and the completion notification.
enum BackgroundDownloadText {
    static func title(playlistName: String?, trackTitle: String?) -> String {
        if let name = playlistName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return "Downloading \u{201C}\(name)\u{201D}"
        }
        if let track = trackTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !track.isEmpty {
            return "Downloading \u{201C}\(track)\u{201D}"
        }
        return "Downloading music"
    }

    static func subtitle(processed: Int, total: Int, failed: Int) -> String {
        guard total > 1 else {
            return total == 1 && processed >= 1 ? "Saving to your library" : "Getting the song…"
        }
        var text = "\(min(processed, total)) of \(total) songs"
        if failed > 0 { text += ", \(failed) failed" }
        return text
    }

    /// "Downloaded N songs" when the job ends with the app in the background.
    static func completionBody(downloaded: Int, alreadyInLibrary: Int, failed: Int, singleTitle: String? = nil) -> String {
        var text: String
        if downloaded == 1, alreadyInLibrary == 0, failed == 0,
           let title = singleTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return "Downloaded 1 song: \u{201C}\(title)\u{201D}."
        }
        if downloaded == 0 && alreadyInLibrary > 0 {
            text = alreadyInLibrary == 1 ? "Already in your library" : "All \(alreadyInLibrary) songs were already in your library"
        } else {
            text = downloaded == 1 ? "Downloaded 1 song" : "Downloaded \(downloaded) songs"
            if alreadyInLibrary > 0 { text += ", \(alreadyInLibrary) already in your library" }
        }
        if failed > 0 { text += ", \(failed) failed" }
        return text + "."
    }
}

/// Keeps a user-started download session running when the app leaves the
/// foreground or the phone locks.
///
/// - iOS 26+: a `BGContinuedProcessingTask` (system progress UI; runs until
///   the work ends, or the user/system stops it). Per Apple DTS, a handler
///   registered for the wildcard itself is never matched, so each session
///   registers its own `com.Owenisas-Music.download.<uuid>` right before
///   submitting it (each identifier exactly once: a second registration
///   kills the app). Submission uses `.fail`: the work starts immediately
///   either way, the task only adds background time.
/// - Always, until the continued task is running (and on iOS < 26 or when
///   submission fails): `beginBackgroundTask`, as before.
@MainActor
final class BackgroundDownloadActivity {
    /// Legacy background time ran out; iOS suspends the app next.
    var onLegacyExpired: (() -> Void)?
    /// The continued-processing task was expired by iOS or stopped by the
    /// user. The activity has already ended itself.
    var onContinuedExpired: (() -> Void)?

    private(set) var progress = BackgroundDownloadProgress()
    private(set) var title: String
    private(set) var subtitle: String
    private(set) var continuedIdentifier: String?
    private var continuedTask: AnyObject?
    private var legacyTask: UIBackgroundTaskIdentifier = .invalid
    private var ended = false
    private let log: (String) -> Void

    init(title: String, subtitle: String, log: @escaping (String) -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.log = log
    }

    var isAlive: Bool { !ended }
    var isContinuedRunning: Bool { !ended && continuedTask != nil }

    func start() {
        beginLegacy()
        if #available(iOS 26.0, *) {
            submitContinued()
        }
    }

    func setFraction(_ fraction: Double) {
        guard !ended else { return }
        progress.update(fraction: fraction)
        applyProgress()
    }

    func prepareForNextRequest() {
        guard !ended else { return }
        progress.startNextRequest()
        applyProgress()
    }

    func update(title newTitle: String, subtitle newSubtitle: String) {
        guard !ended, newTitle != title || newSubtitle != subtitle else { return }
        title = newTitle
        subtitle = newSubtitle
        if #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask {
            task.updateTitle(newTitle, subtitle: newSubtitle)
        }
    }

    /// After a trip to the foreground: the legacy grant may have expired.
    func rearmLegacyIfNeeded() {
        guard !ended, continuedTask == nil, legacyTask == .invalid else { return }
        beginLegacy()
    }

    func end(success: Bool) {
        guard !ended else { return }
        ended = true
        if #available(iOS 26.0, *) {
            if let task = continuedTask as? BGContinuedProcessingTask {
                if success { task.progress.completedUnitCount = task.progress.totalUnitCount }
                task.setTaskCompleted(success: success)
                log("continued processing completed (success: \(success))")
            } else if let identifier = continuedIdentifier {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
            }
        }
        continuedTask = nil
        endLegacy()
    }

    // MARK: Legacy background task

    private func beginLegacy() {
        endLegacy()
        legacyTask = UIApplication.shared.beginBackgroundTask(withName: "OwenisasDownload") { [weak self] in
            // Called on the main thread; must end the task before returning.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.log("background time expired")
                self.onLegacyExpired?()
                self.endLegacy()
            }
        }
    }

    private func endLegacy() {
        if legacyTask != .invalid {
            UIApplication.shared.endBackgroundTask(legacyTask)
            legacyTask = .invalid
        }
    }

    // MARK: Continued processing (iOS 26+)

    private func applyProgress() {
        if #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask {
            task.progress.totalUnitCount = progress.totalUnits
            task.progress.completedUnitCount = progress.completedUnits
        }
    }

    @available(iOS 26.0, *)
    private func submitContinued() {
        let identifier = BackgroundDownloadIdentifier.make()
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let task = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                guard let self, !self.ended else {
                    // The session ended before the system started the task.
                    task.setTaskCompleted(success: true)
                    return
                }
                self.attach(task)
            }
        }
        guard registered else {
            log("continued processing not registered (identifier not permitted by Info.plist)")
            return
        }
        continuedIdentifier = identifier
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        request.strategy = .fail
        #if canImport(MediaIntents)
        if #available(iOS 27.0, *) {
            // The async submit must not run on the main thread.
            Task.detached { [weak self] in
                do {
                    try await BGTaskScheduler.shared.submitTaskRequest(request)
                } catch {
                    await self?.submissionFailed(error)
                }
            }
        } else {
            do {
                try BGTaskScheduler.shared.submit(request)
            } catch {
                submissionFailed(error)
            }
        }
        #else
        // Stable SDK 26 exposes the synchronous submit API only.
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            submissionFailed(error)
        }
        #endif
    }

    private func submissionFailed(_ error: Error) {
        let code = (error as NSError).code
        log("continued processing unavailable (BGTaskScheduler error \(code)); using the short background grant")
        continuedIdentifier = nil
    }

    @available(iOS 26.0, *)
    private func attach(_ task: BGContinuedProcessingTask) {
        continuedTask = task
        task.expirationHandler = { [weak self] in
            Task { @MainActor in self?.continuedDidExpire() }
        }
        applyProgress()
        task.updateTitle(title, subtitle: subtitle)
        // The continued task keeps the app running; the ~30 s grant would
        // only expire and mark the job as interrupted.
        endLegacy()
        log("continued processing running")
    }

    private func continuedDidExpire() {
        guard !ended else { return }
        log("continued processing expired; stopping like Cancel")
        ended = true
        let task = continuedTask
        continuedTask = nil
        endLegacy()
        onContinuedExpired?()
        if #available(iOS 26.0, *), let task = task as? BGContinuedProcessingTask {
            task.setTaskCompleted(success: false)
        }
    }
}

// MARK: - Job (cancellation, temp files, background state)

/// One user-started download. Cancelling it cancels every registered task
/// (and through them the URLSession requests); temp files it tracks are
/// deleted at the end of each track and on cancel.
final class DownloadJob {
    private let lock = NSLock()
    private var cancelled = false
    private var cancelHandlers: [() -> Void] = []
    private var tempFiles: Set<URL> = []
    private var backgrounded = false

    // Main-actor bookkeeping.
    /// The queued shared-link request this job serves, if any.
    var requestID: UUID?
    /// Title of the song of a single-video job, once resolved.
    var currentTrackTitle: String?
    var playlistName: String?
    var savedSongIDs: [String] = []
    var libraryIndex: [String: String]?
    var folderIndex: [String: String]?
    var lrclibNetworkFailures = 0

    var isCancelled: Bool { lock.withLock { cancelled } }
    var wasBackgrounded: Bool { lock.withLock { backgrounded } }

    func cancel() {
        let handlers: [() -> Void] = lock.withLock {
            guard !cancelled else { return [] }
            cancelled = true
            defer { cancelHandlers = [] }
            return cancelHandlers
        }
        handlers.forEach { $0() }
    }

    func onCancel(_ handler: @escaping () -> Void) {
        let runNow: Bool = lock.withLock {
            if cancelled { return true }
            cancelHandlers.append(handler)
            return false
        }
        if runNow { handler() }
    }

    func noteBackgrounded() {
        lock.withLock { backgrounded = true }
    }

    func trackTemp(_ url: URL) {
        _ = lock.withLock { tempFiles.insert(url) }
    }

    /// Deletes tracked temp files that still exist (saved files were moved away).
    func cleanupTemps() {
        let urls: Set<URL> = lock.withLock {
            defer { tempFiles = [] }
            return tempFiles
        }
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

enum DownloadTempFiles {
    static let prefix = "owenisas-dl-"

    static func newURL(ext: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(prefix + UUID().uuidString)
            .appendingPathExtension(ext)
    }

    /// Leftovers from a crash or kill mid-download (ours, and the older
    /// bare-UUID names) older than an hour.
    static func sweepStale(olderThan age: TimeInterval = 3600) {
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            guard let files = try? fm.contentsOfDirectory(at: caches, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
            let cutoff = Date().addingTimeInterval(-age)
            let legacyExts: Set<String> = ["m4a", "jpg", "jpeg", "png", "webp", "gif", "vtt", "srv1"]
            for file in files {
                let stem = file.deletingPathExtension().lastPathComponent
                let ours = stem.hasPrefix(prefix)
                let legacy = UUID(uuidString: stem) != nil && legacyExts.contains(file.pathExtension.lowercased())
                guard ours || legacy else { continue }
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if modified < cutoff { try? fm.removeItem(at: file) }
            }
        }
    }
}

// MARK: - Debug log (Documents/download-debug.log, rotated at ~1 MB)

enum DownloadDebugLog {
    static let maxBytes: UInt64 = 1_000_000

    static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("download-debug.log")
    }

    static var rotatedFileURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("download-debug.1.log")
    }

    private static let queue = DispatchQueue(label: "owenisas.download.debug-log")
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// Logs to NSLog and the file; returns the timestamped line for the UI.
    /// Never pass cookies, headers or full stream URLs here.
    @discardableResult
    static func write(_ message: String) -> String {
        let line = "[\(formatter.string(from: Date()))] \(message)"
        NSLog("OWENISAS_DOWNLOAD: %@", line)
        queue.async { append(line + "\n", to: fileURL, rotatedTo: rotatedFileURL, maxBytes: maxBytes) }
        return line
    }

    static func append(_ text: String, to url: URL, rotatedTo rotated: URL, maxBytes: UInt64) {
        guard let data = text.data(using: .utf8) else { return }
        let fm = FileManager.default
        let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
        if size + UInt64(data.count) > maxBytes {
            try? fm.removeItem(at: rotated)
            try? fm.moveItem(at: url, to: rotated)
        }
        if fm.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}

// MARK: - Link classification

// `YouTubeLinkKind` / `YouTubeLinkClassifier` live in Shared/YouTubeLinkClassifier.swift
// (also used by the share extension).

// MARK: - Progress

enum DownloadProgressMath {
    static let resolvedFraction = 0.10
    static let coverFraction = 0.15
    static let audioDoneFraction = 0.90
    static let lyricsFraction = 0.95

    /// Overall bar for track `index` of `count`: (index + trackFraction) / count.
    static func overall(index: Int, count: Int, trackFraction: Double) -> Double {
        guard count > 0 else { return 0 }
        let clampedIndex = min(max(index, 0), count)
        let fraction = min(max(trackFraction.isFinite ? trackFraction : 0, 0), 1)
        return min((Double(clampedIndex) + fraction) / Double(count), 1)
    }

    /// Bytes downloaded (0…1) mapped into the track's audio phase.
    static func audioFraction(_ bytesFraction: Double) -> Double {
        let clamped = min(max(bytesFraction.isFinite ? bytesFraction : 0, 0), 1)
        return coverFraction + (audioDoneFraction - coverFraction) * clamped
    }
}

// MARK: - Playlist page parsing

struct PlaylistEntry: Equatable {
    let videoId: String
    let title: String?
}

struct PlaylistPage {
    var title: String
    var coverUrl: String?
    var entries: [PlaylistEntry]
}

enum PlaylistPageParser {
    struct FirstPage {
        let title: String?
        let coverUrl: String?
        let entries: [PlaylistEntry]
        let continuation: String?
        let apiKey: String?
        let context: [String: Any]?
    }

    static func firstPage(fromHTML html: String) -> FirstPage? {
        guard let initialData = initialData(fromHTML: html) else { return nil }
        let contents: [[String: Any]]
        if let listRenderer = deepSearch(forKey: "playlistVideoListRenderer", in: initialData),
           let legacy = listRenderer["contents"] as? [[String: Any]] {
            contents = legacy
        } else if let lockups = lockupList(in: initialData) {
            contents = lockups
        } else {
            return nil
        }
        return FirstPage(
            title: title(fromInitialData: initialData),
            coverUrl: cover(fromInitialData: initialData),
            entries: entries(from: contents),
            continuation: continuationToken(from: contents),
            apiKey: apiKey(fromHTML: html),
            context: innertubeContext(fromHTML: html)
        )
    }

    /// 2026 playlist layout: `itemSectionRenderer.contents` holds
    /// `lockupViewModel` items plus a trailing `continuationItemViewModel`.
    /// Pick the largest such list on the page.
    static func lockupList(in data: [String: Any]) -> [[String: Any]]? {
        let lists = deepSearchAll(forKey: "contents", in: data)
            .compactMap { $0 as? [[String: Any]] }
            .filter { list in list.contains { $0["lockupViewModel"] != nil } }
        return lists.max { lhs, rhs in
            lhs.filter { $0["lockupViewModel"] != nil }.count < rhs.filter { $0["lockupViewModel"] != nil }.count
        }
    }

    /// Videos in a page or continuation, in order. Reads both the legacy
    /// `playlistVideoRenderer` and the 2026 `lockupViewModel` items.
    static func entries(from contents: [[String: Any]]) -> [PlaylistEntry] {
        contents.compactMap { entry in
            if let renderer = entry["playlistVideoRenderer"] as? [String: Any] {
                guard let id = renderer["videoId"] as? String, !id.isEmpty else { return nil }
                let title = text(fromNode: renderer["title"])?.trimmingCharacters(in: .whitespacesAndNewlines)
                return PlaylistEntry(videoId: id, title: (title?.isEmpty ?? true) ? nil : title)
            }
            if let lockup = entry["lockupViewModel"] as? [String: Any] {
                if let type = lockup["contentType"] as? String, type != "LOCKUP_CONTENT_TYPE_VIDEO" { return nil }
                let watch = ((((lockup["rendererContext"] as? [String: Any])?["commandContext"] as? [String: Any])?["onTap"] as? [String: Any])?["innertubeCommand"] as? [String: Any])?["watchEndpoint"] as? [String: Any]
                guard let id = (lockup["contentId"] as? String) ?? (watch?["videoId"] as? String), !id.isEmpty else { return nil }
                let title = ((((lockup["metadata"] as? [String: Any])?["lockupMetadataViewModel"] as? [String: Any])?["title"] as? [String: Any])?["content"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return PlaylistEntry(videoId: id, title: (title?.isEmpty ?? true) ? nil : title)
            }
            return nil
        }
    }

    static func continuationToken(from contents: [[String: Any]]) -> String? {
        for entry in contents {
            if let token = (((entry["continuationItemRenderer"] as? [String: Any])?["continuationEndpoint"] as? [String: Any])?["continuationCommand"] as? [String: Any])?["token"] as? String {
                return token
            }
            if let viewModel = entry["continuationItemViewModel"] as? [String: Any],
               let token = deepSearchAll(forKey: "token", in: viewModel).compactMap({ $0 as? String }).first(where: { !$0.isEmpty }) {
                return token
            }
        }
        return nil
    }

    /// Items of a browse continuation response, in order.
    static func continuationContents(fromBrowse payload: [String: Any]) -> [[String: Any]] {
        let arrays = deepSearchAll(forKey: "continuationItems", in: payload).compactMap { $0 as? [[String: Any]] }
        if !arrays.isEmpty { return arrays.flatMap { $0 } }
        let videos = deepSearchAll(forKey: "playlistVideoRenderer", in: payload)
            .compactMap { $0 as? [String: Any] }
            .map { ["playlistVideoRenderer": $0] }
        let continuations = deepSearchAll(forKey: "continuationItemRenderer", in: payload)
            .compactMap { $0 as? [String: Any] }
            .map { ["continuationItemRenderer": $0] }
        return videos + continuations
    }

    /// The playlist's own name. A generic deep search for "title" returned
    /// whatever title key the dictionary happened to visit first.
    static func title(fromInitialData data: [String: Any]) -> String? {
        func nonEmpty(_ value: String?) -> String? {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
            return trimmed
        }
        if let title = nonEmpty(((data["metadata"] as? [String: Any])?["playlistMetadataRenderer"] as? [String: Any])?["title"] as? String) {
            return title
        }
        let header = data["header"] as? [String: Any]
        if let renderer = header?["playlistHeaderRenderer"] as? [String: Any],
           let title = nonEmpty(text(fromNode: renderer["title"])) {
            return title
        }
        if let renderer = header?["pageHeaderRenderer"] as? [String: Any] {
            if let title = nonEmpty(renderer["pageTitle"] as? String) { return title }
            let viewModel = (renderer["content"] as? [String: Any])?["pageHeaderViewModel"] as? [String: Any]
            let dynamic = (viewModel?["title"] as? [String: Any])?["dynamicTextViewModel"] as? [String: Any]
            if let title = nonEmpty((dynamic?["text"] as? [String: Any])?["content"] as? String) { return title }
        }
        if let title = nonEmpty(((data["microformat"] as? [String: Any])?["microformatDataRenderer"] as? [String: Any])?["title"] as? String) {
            return title
        }
        return nil
    }

    static func cover(fromInitialData data: [String: Any]) -> String? {
        if let header = deepSearch(forKey: "playlistHeaderRenderer", in: data) {
            if let thumbnails = (header["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]],
               let url = thumbnails.last?["url"] as? String {
                return url
            }
            if let renderer = (header["playlistHeaderBanner"] as? [String: Any])?["heroPlaylistThumbnailRenderer"] as? [String: Any],
               let thumbnails = (renderer["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]],
               let url = thumbnails.last?["url"] as? String {
                return url
            }
        }
        if let thumbnails = (((data["microformat"] as? [String: Any])?["microformatDataRenderer"] as? [String: Any])?["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]],
           let url = thumbnails.last?["url"] as? String {
            return url
        }
        return nil
    }

    static func initialData(fromHTML html: String) -> [String: Any]? {
        extractJSON(fromHTML: html, marker: "ytInitialData = ")
            ?? extractJSON(fromHTML: html, marker: "window[\"ytInitialData\"] = ")
            ?? extractJSON(fromHTML: html, marker: "ytInitialData=")
    }

    static func extractJSON(fromHTML html: String, marker: String) -> [String: Any]? {
        guard let markerRange = html.range(of: marker) else { return nil }
        let rest = html[markerRange.upperBound...]
        guard let end = rest.range(of: ";</script>") else { return nil }
        let jsonRaw = String(rest[..<end.lowerBound])
        for payload in [jsonRaw, decodeHexEscapedJSON(jsonRaw)] {
            guard let data = payload.data(using: .utf8),
                  let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            return dict
        }
        return nil
    }

    static func decodeHexEscapedJSON(_ value: String) -> String {
        var source = value
        if source.count >= 2 {
            let first = source.first, last = source.last
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
                    let h1 = source.index(after: xIndex)
                    let h2 = h1 < source.endIndex ? source.index(after: h1) : source.endIndex
                    if h2 < source.endIndex, let byte = UInt8(String(source[h1...h2]), radix: 16) {
                        output.unicodeScalars.append(UnicodeScalar(byte))
                        index = source.index(after: h2)
                        continue
                    }
                }
            }
            output.append(source[index])
            index = source.index(after: index)
        }
        return output
    }

    static func apiKey(fromHTML html: String) -> String? {
        for marker in ["\"INNERTUBE_API_KEY\":\"", "\"innertubeApiKey\":\"", "\"INNERTUBE_API_KEY\": \"", "\"innertubeApiKey\": \""] {
            guard let markerRange = html.range(of: marker) else { continue }
            let rest = html[markerRange.upperBound...]
            guard let end = rest.range(of: "\"") else { continue }
            let key = String(rest[..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { return key }
        }
        return nil
    }

    /// INNERTUBE_CONTEXT from whichever `ytcfg.set({...})` call carries it.
    /// The page has several `ytcfg.set(` calls and the first is not JSON.
    static func innertubeContext(fromHTML html: String) -> [String: Any]? {
        var searchStart = html.startIndex
        while let markerRange = html.range(of: "ytcfg.set(", range: searchStart..<html.endIndex) {
            searchStart = markerRange.upperBound
            let rest = html[markerRange.upperBound...].drop(while: { $0 == " " })
            guard rest.first == "{",
                  let config = balancedJSONObject(in: html, from: rest.startIndex),
                  let context = config["INNERTUBE_CONTEXT"] as? [String: Any] else { continue }
            return context
        }
        return nil
    }

    private static func balancedJSONObject(in html: String, from start: String.Index) -> [String: Any]? {
        let tail = html[start...]
        var depth = 0
        var end: String.Index?
        var inString = false
        var escape = false
        var idx = start
        while idx < tail.endIndex {
            let c = tail[idx]
            if escape {
                escape = false
            } else if inString {
                if c == "\\" { escape = true } else if c == "\"" { inString = false }
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
        guard let end else { return nil }
        guard let data = String(tail[start...end]).data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func text(fromNode value: Any?) -> String? {
        if let text = value as? String { return text }
        if let dict = value as? [String: Any] {
            if let simple = dict["simpleText"] as? String { return simple }
            if let runs = dict["runs"] as? [[String: Any]] {
                return runs.compactMap { $0["text"] as? String }.joined()
            }
        }
        return nil
    }

    static func deepSearch(forKey key: String, in node: Any) -> [String: Any]? {
        if let dict = node as? [String: Any] {
            if let target = dict[key] as? [String: Any] { return target }
            for (_, value) in dict {
                if let found = deepSearch(forKey: key, in: value) { return found }
            }
        }
        if let array = node as? [Any] {
            for item in array {
                if let found = deepSearch(forKey: key, in: item) { return found }
            }
        }
        return nil
    }

    static func deepSearchAll(forKey key: String, in node: Any) -> [Any] {
        var matches: [Any] = []
        if let dict = node as? [String: Any] {
            if let value = dict[key] { matches.append(value) }
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
}

// MARK: - Library keys

enum LibraryKey {
    static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: " - topic", with: "")
            .replacingOccurrences(of: "/", with: "-")
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Video IDs are case-sensitive, so no folding here.
    static func id(_ id: String) -> String {
        "id:" + id.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func titleArtist(_ title: String, _ artist: String) -> String {
        "ta:" + normalize(title) + "|" + normalize(artist)
    }

    static func folder(_ name: String) -> String {
        normalize(name)
    }
}

// MARK: - Audio download (sequential Range GETs)

enum AudioDownloadError: Error, Equatable {
    case blocked(status: Int)
    case stalled
    case timedOut
    case offline
    case backgrounded
    case unsupportedFormat
    case notAudio
    case tooSmall(bytes: Int64)
    case httpStatus(Int)
    case badRange
    case network(String)
    case fileSystem(String)
    case cancelled

    var alertTitle: String {
        switch self {
        case .blocked: return "Blocked by YouTube"
        case .stalled, .timedOut: return "Download Stalled"
        case .offline: return "You're Offline"
        case .backgrounded: return "Download Interrupted"
        case .unsupportedFormat, .notAudio: return "Unsupported Format"
        case .tooSmall: return "Incomplete Download"
        case .httpStatus, .badRange, .network: return "Network Error"
        case .fileSystem: return "Storage Error"
        case .cancelled: return "Cancelled"
        }
    }

    var userMessage: String {
        switch self {
        case .blocked(let status):
            return "YouTube refused the audio stream (HTTP \(status)). The video may be region-locked or protected. Try again later or try another upload of the song."
        case .stalled:
            return "YouTube accepted the request but sent no audio for 12 seconds. Check your connection and tap Retry."
        case .timedOut:
            return "The download stopped making progress. Check your connection and tap Retry."
        case .offline:
            return "You're offline. Connect to the internet and tap Retry."
        case .backgrounded:
            return "The download was interrupted while the app was in the background. Keep the app open until it finishes, then tap Retry."
        case .unsupportedFormat:
            return "YouTube sent WebM/Opus audio, which the player can't play."
        case .notAudio:
            return "The server didn't send a playable audio file."
        case .tooSmall(let bytes):
            return "The downloaded audio was too small to be a real track (\(bytes / 1024) KB)."
        case .httpStatus(let code):
            return "YouTube's audio server answered HTTP \(code). Tap Retry in a moment."
        case .badRange:
            return "YouTube's audio server sent the wrong part of the file. Tap Retry."
        case .network(let reason):
            return "Network error: \(reason)"
        case .fileSystem(let reason):
            return reason
        case .cancelled:
            return "The download was cancelled."
        }
    }

    var isRetryable: Bool {
        switch self {
        case .unsupportedFormat, .notAudio, .cancelled: return false
        default: return true
        }
    }

    var logDescription: String {
        switch self {
        case .blocked(let status): return "blocked HTTP \(status)"
        case .tooSmall(let bytes): return "too small (\(bytes) bytes)"
        case .httpStatus(let code): return "HTTP \(code)"
        case .network(let reason): return "network: \(reason)"
        default: return "\(self)"
        }
    }
}

enum RangeChunkOutcome: Equatable {
    /// 206 starting at the requested offset.
    case partial(total: Int64?)
    /// 200: the body is the whole file. `restart` when bytes were already
    /// written (server ignored Range): truncate and start over.
    case whole(restart: Bool)
    /// 416 past the end.
    case endOfStream
    case blocked(Int)
    case retryable(Int)
    case rangeMismatch(expected: Int64, got: Int64)
    case unexpected(Int)
}

enum RangeResponse {
    static func classify(status: Int, contentRange: String?, requestedOffset: Int64) -> RangeChunkOutcome {
        switch status {
        case 206:
            if let header = contentRange, let parsed = parseContentRange(header) {
                guard parsed.start == requestedOffset else {
                    return .rangeMismatch(expected: requestedOffset, got: parsed.start)
                }
                return .partial(total: parsed.total)
            }
            return .partial(total: nil)
        case 200:
            return .whole(restart: requestedOffset > 0)
        case 416:
            return requestedOffset > 0 ? .endOfStream : .unexpected(416)
        case 401, 403:
            return .blocked(status)
        case 429, 500...599:
            return .retryable(status)
        default:
            return .unexpected(status)
        }
    }

    /// `bytes 0-1023/4567` (total may be `*`).
    static func parseContentRange(_ header: String) -> (start: Int64, end: Int64, total: Int64?)? {
        var value = header.trimmingCharacters(in: .whitespaces)
        guard value.lowercased().hasPrefix("bytes") else { return nil }
        value = String(value.dropFirst(5)).trimmingCharacters(in: CharacterSet(charactersIn: " ="))
        let halves = value.split(separator: "/", maxSplits: 1)
        guard halves.count == 2 else { return nil }
        let bounds = halves[0].split(separator: "-", maxSplits: 1)
        guard bounds.count == 2,
              let start = Int64(bounds[0].trimmingCharacters(in: .whitespaces)),
              let end = Int64(bounds[1].trimmingCharacters(in: .whitespaces)),
              end >= start else { return nil }
        return (start, end, Int64(halves[1].trimmingCharacters(in: .whitespaces)))
    }
}

/// googlevideo on iOS: URLSessionDownloadTask with the iOS YouTube UA stalls
/// at 0 bytes (phone log 2026-08-29). Fetch like the resolve probe instead:
/// cookie-free session, Safari UA, sequential Range requests via data(for:).
final class ChunkedAudioDownloader {
    struct Config {
        /// Small first request: proves bytes flow within the stall window.
        var firstChunkSize: Int64 = 64 * 1024
        var chunkSize: Int64 = 512 * 1024
        var minChunkSize: Int64 = 128 * 1024
        var firstByteTimeout: TimeInterval = 12
        var maxTotalRetries = 3
        var retryDelay: TimeInterval = 1
        var minimumBytes: Int64 = 20_000
    }

    private struct Stall: Error {}

    private enum Race {
        case finished(Data, URLResponse)
        case deadline
    }

    /// Captures the URLSessionTask behind `data(for:delegate:)` so the stall
    /// watchdog can read how many bytes have arrived.
    private final class TaskCapture: NSObject, URLSessionTaskDelegate {
        private let lock = NSLock()
        private var created: URLSessionTask?
        var task: URLSessionTask? { lock.withLock { created } }

        func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
            lock.withLock { created = task }
        }
    }

    let session: URLSession
    let userAgent: String
    let config: Config
    let log: (String) -> Void
    let wasBackgrounded: () -> Bool

    init(session: URLSession, userAgent: String, config: Config = Config(),
         log: @escaping (String) -> Void, wasBackgrounded: @escaping () -> Bool = { false }) {
        self.session = session
        self.userAgent = userAgent
        self.config = config
        self.log = log
        self.wasBackgrounded = wasBackgrounded
    }

    /// Downloads `url` into `dest`. Throws `AudioDownloadError`.
    @discardableResult
    func download(from url: URL, to dest: URL, progress: @escaping (Int64, Int64?) -> Void) async throws -> Int64 {
        let fm = FileManager.default
        guard fm.createFile(atPath: dest.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: dest) else {
            throw AudioDownloadError.fileSystem("Couldn't create a temporary file for the download.")
        }
        defer { try? handle.close() }

        let started = Date()
        var offset: Int64 = 0
        var total: Int64?
        var chunkSize = config.firstChunkSize
        var steadyChunkSize = config.chunkSize
        var retriedAtOffset: Int64 = -1
        var totalRetries = 0

        func retryOrThrow(_ error: AudioDownloadError, reason: String, shrink: Bool) async throws {
            guard retriedAtOffset != offset, totalRetries < config.maxTotalRetries else { throw error }
            retriedAtOffset = offset
            totalRetries += 1
            if shrink {
                steadyChunkSize = max(config.minChunkSize, steadyChunkSize / 2)
                if offset > 0 { chunkSize = steadyChunkSize }
            }
            log("Audio chunk at byte \(offset) failed (\(reason)); retrying once from byte \(offset)")
            do {
                try await Task.sleep(nanoseconds: UInt64(config.retryDelay * 1_000_000_000))
            } catch {
                throw AudioDownloadError.cancelled
            }
        }

        transfer: while true {
            if Task.isCancelled { throw AudioDownloadError.cancelled }
            var end = offset + chunkSize - 1
            if let total { end = min(end, total - 1) }
            let requested = end - offset + 1

            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("*/*", forHTTPHeaderField: "Accept")
            request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")

            let data: Data
            let http: HTTPURLResponse
            do {
                (data, http) = try await fetch(request, stallTimeout: offset == 0 ? config.firstByteTimeout : nil)
            } catch is Stall {
                log("Audio stalled: 0 bytes in \(Int(config.firstByteTimeout))s on the first chunk; not retrying this URL")
                throw wasBackgrounded() ? AudioDownloadError.backgrounded : AudioDownloadError.stalled
            } catch is CancellationError {
                throw AudioDownloadError.cancelled
            } catch let error as URLError {
                if Task.isCancelled { throw AudioDownloadError.cancelled }
                let final = finalError(for: error)
                if final == .offline, offset == 0 { throw final }
                try await retryOrThrow(final, reason: "\(error.code.rawValue) \(error.localizedDescription)",
                                       shrink: error.code == .timedOut)
                continue transfer
            } catch {
                if Task.isCancelled { throw AudioDownloadError.cancelled }
                throw AudioDownloadError.network(error.localizedDescription)
            }

            let outcome = RangeResponse.classify(status: http.statusCode,
                                                 contentRange: http.value(forHTTPHeaderField: "Content-Range"),
                                                 requestedOffset: offset)
            if offset == 0 {
                log("Audio first chunk HTTP \(http.statusCode) bytes=\(data.count)")
            }
            switch outcome {
            case .partial(let reportedTotal):
                guard !data.isEmpty else {
                    if offset > 0 { break transfer }
                    throw AudioDownloadError.tooSmall(bytes: 0)
                }
                try write(data, to: handle)
                offset += Int64(data.count)
                if let reportedTotal, reportedTotal > 0 { total = reportedTotal }
                chunkSize = steadyChunkSize
                progress(offset, total)
                if let total, offset >= total { break transfer }
                if total == nil && Int64(data.count) < requested { break transfer }
            case .whole(let restart):
                if restart {
                    log("HTTP 200 at byte \(offset): the server ignored Range; restarting the file from byte 0")
                    do {
                        try handle.truncate(atOffset: 0)
                    } catch {
                        throw AudioDownloadError.fileSystem("Couldn't reset the temporary file.")
                    }
                }
                try write(data, to: handle)
                offset = Int64(data.count)
                total = offset
                progress(offset, total)
                break transfer
            case .endOfStream:
                break transfer
            case .blocked(let status):
                log("Audio HTTP \(status): not retrying this URL")
                throw AudioDownloadError.blocked(status: status)
            case .retryable(let status):
                try await retryOrThrow(.httpStatus(status), reason: "HTTP \(status)", shrink: false)
                continue transfer
            case .rangeMismatch(let expected, let got):
                log("Audio Content-Range starts at \(got), expected \(expected)")
                throw AudioDownloadError.badRange
            case .unexpected(let status):
                log("Audio unexpected HTTP \(status) bytes=\(data.count)")
                throw AudioDownloadError.httpStatus(status)
            }
        }

        do {
            try handle.synchronize()
        } catch {
            throw AudioDownloadError.fileSystem("Couldn't finish writing the download.")
        }
        let head: Data = {
            guard let reader = try? FileHandle(forReadingFrom: dest) else { return Data() }
            defer { try? reader.close() }
            return (try? reader.read(upToCount: 16)) ?? Data()
        }()
        let container = PlayableLocalAudio.container(of: head)
        let elapsed = max(Date().timeIntervalSince(started), 0.001)
        log("Audio saved \(offset) bytes container=\(container) in \(String(format: "%.1f", elapsed))s")

        if head.count >= 4 && head.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) {
            throw AudioDownloadError.unsupportedFormat
        }
        if offset < config.minimumBytes {
            throw AudioDownloadError.tooSmall(bytes: offset)
        }
        if container == .unplayable {
            throw AudioDownloadError.notAudio
        }
        return offset
    }

    private func write(_ data: Data, to handle: FileHandle) throws {
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw AudioDownloadError.fileSystem("Couldn't write the download (is the phone out of space?).")
        }
    }

    private func finalError(for error: URLError) -> AudioDownloadError {
        if YouTubeClient.isOffline(error) { return .offline }
        let interruptible: [URLError.Code] = [.networkConnectionLost, .timedOut, .cancelled, .backgroundSessionWasDisconnected]
        if wasBackgrounded() && interruptible.contains(error.code) { return .backgrounded }
        if error.code == .timedOut { return .timedOut }
        return .network(error.localizedDescription)
    }

    /// One request. For the first chunk, cancel with `Stall` if no byte has
    /// arrived after `stallTimeout`; once bytes flow the request is left to
    /// the session's idle (15 s) and per-request (45 s) limits.
    private func fetch(_ request: URLRequest, stallTimeout: TimeInterval?) async throws -> (Data, HTTPURLResponse) {
        let capture = TaskCapture()
        let session = self.session
        guard let stallTimeout else {
            let (data, response) = try await session.data(for: request, delegate: capture)
            return (data, try Self.http(response))
        }
        return try await withThrowingTaskGroup(of: Race.self) { group in
            group.addTask {
                let (data, response) = try await session.data(for: request, delegate: capture)
                return .finished(data, response)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(stallTimeout * 1_000_000_000))
                return .deadline
            }
            while let next = try await group.next() {
                switch next {
                case .finished(let data, let response):
                    group.cancelAll()
                    return (data, try Self.http(response))
                case .deadline:
                    if (capture.task?.countOfBytesReceived ?? 0) == 0 {
                        group.cancelAll()
                        throw Stall()
                    }
                }
            }
            throw URLError(.unknown)
        }
    }

    private static func http(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return http
    }
}

// MARK: - Saving

enum SongFileSaver {
    struct SavedSong {
        let folderID: String
        let folderURL: URL
    }

    static var songsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Songs", isDirectory: true)
    }

    static func metadata(for meta: VideoInfo) -> SongFolderMetadata {
        SongFolderMetadata(title: meta.title, artist: meta.artist, album: meta.album,
                           videoId: meta.id, duration: meta.duration, source: "youtube")
    }

    /// Writes meta.json, cover, lyric files and finally the audio (a folder
    /// only counts as a song once playable audio is in it). Existing files
    /// are replaced only by files that are known good.
    static func save(folderID rawID: String, meta: VideoInfo, cover: URL?, audio: URL,
                     subtitles: [(lang: String, vtt: String)], log: (String) -> Void) throws -> SavedSong {
        let fm = FileManager.default
        let folderID = rawID.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        let songDir = songsDirectory.appendingPathComponent(folderID, isDirectory: true)
        try fm.createDirectory(at: songDir, withIntermediateDirectories: true)

        try metadata(for: meta).write(to: songDir)

        if let cover {
            defer { try? fm.removeItem(at: cover) }
            let destCover = songDir.appendingPathComponent("\(folderID).jpg")
            if let data = try? Data(contentsOf: cover),
               let image = UIImage(data: data),
               let jpeg = image.jpegData(compressionQuality: 0.9) {
                try jpeg.write(to: destCover, options: .atomic)
            } else {
                log("Cover didn't decode; keeping the existing cover, if any")
            }
        }

        for subtitle in subtitles {
            let dest = songDir.appendingPathComponent("\(folderID).\(subtitle.lang).vtt")
            try subtitle.vtt.write(to: dest, atomically: true, encoding: .utf8)
        }

        let destAudio = songDir.appendingPathComponent("\(folderID).m4a")
        if fm.fileExists(atPath: destAudio.path) {
            _ = try fm.replaceItemAt(destAudio, withItemAt: audio)
        } else {
            try fm.moveItem(at: audio, to: destAudio)
        }
        let size = (try? fm.attributesOfItem(atPath: destAudio.path)[.size] as? NSNumber)?.int64Value ?? 0
        log("Saved \(destAudio.lastPathComponent) (\(size) bytes)")
        return SavedSong(folderID: folderID, folderURL: songDir)
    }
}

// MARK: - Lyrics (YouTube captions + LRCLIB)

struct LyricsQuery: Equatable {
    let track: String
    let artist: String
}

/// Turns YouTube text ("Luis Fonsi - Despacito ft. Daddy Yankee",
/// channel "LuisFonsiVEVO") into a clean track/artist for LRCLIB, and gives
/// comparison keys for validating LRCLIB hits.
enum LyricsQueryNormalizer {
    private static let bracketNoise: Set<String> = [
        "official", "video", "audio", "lyric", "lyrics", "mv", "m/v", "visualizer", "visualiser",
        "hd", "hq", "4k", "1080p", "720p", "remaster", "remastered", "explicit", "ft", "feat", "featuring", "prod",
    ]

    static func query(videoTitle rawTitle: String, channel rawChannel: String?) -> LyricsQuery {
        let channel = cleanChannel(rawChannel ?? "")
        var title = firstPipeSegment(stripNoiseBrackets(rawTitle))

        // Japanese convention: Artist「Title」
        if let open = title.firstIndex(of: "「"), let close = title[open...].firstIndex(of: "」") {
            let inner = String(title[title.index(after: open)..<close])
            let before = String(title[..<open])
            let track = cleanTrack(inner)
            if !track.isEmpty {
                let artist = cleanArtistPart(before)
                return LyricsQuery(track: track, artist: artist.isEmpty ? channel : artist)
            }
        }

        title = collapse(title)
        if let (left, right) = splitArtistTitle(title) {
            var artistPart = left
            var trackPart = right
            let channelKey = key(channel)
            if !channelKey.isEmpty, key(right).contains(channelKey), !key(left).contains(channelKey) {
                swap(&artistPart, &trackPart)
            }
            let artist = cleanArtistPart(artistPart)
            let track = cleanTrack(trackPart)
            if !track.isEmpty {
                return LyricsQuery(track: track, artist: artist.isEmpty ? channel : artist)
            }
        }
        return LyricsQuery(track: cleanTrack(title), artist: channel)
    }

    static func cleanChannel(_ raw: String) -> String {
        var channel = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in [" - topic", " – topic"] where channel.lowercased().hasSuffix(suffix) {
            channel = String(channel.dropLast(suffix.count))
        }
        if channel.lowercased().hasSuffix("vevo"), channel.count > 4 {
            channel = String(channel.dropLast(4)).trimmingCharacters(in: .whitespaces)
            if !channel.contains(" ") { channel = splitCamelCase(channel) }
        }
        for suffix in [" official youtube channel", " official channel", " official"] where channel.lowercased().hasSuffix(suffix) {
            let trimmed = String(channel.dropLast(suffix.count))
            if !trimmed.trimmingCharacters(in: .whitespaces).isEmpty { channel = trimmed }
        }
        return collapse(channel.trimmingCharacters(in: CharacterSet(charactersIn: " -–—")))
    }

    static func cleanTrack(_ raw: String) -> String {
        var track = firstPipeSegment(stripNoiseBrackets(raw))
        track = stripFeaturing(track)
        let trailingNoise = "(?i)[\\s\\-–—:]+(official\\s+(music\\s+|lyric\\s+)?video|official\\s+audio|lyric\\s+video|lyrics?|audio|mv|m/v|visuali[sz]er)\\s*$"
        while let range = track.range(of: trailingNoise, options: .regularExpression), range.lowerBound > track.startIndex {
            track.removeSubrange(range)
        }
        track = track.trimmingCharacters(in: CharacterSet(charactersIn: " -–—\"'“”‘’"))
        return collapse(track)
    }

    static func cleanArtistPart(_ raw: String) -> String {
        let artist = stripFeaturing(stripNoiseBrackets(raw))
        return collapse(artist.trimmingCharacters(in: CharacterSet(charactersIn: " -–—:\"'")))
    }

    /// Lowercased, diacritic-folded, letters and digits only.
    static func key(_ value: String) -> String {
        var folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "&", with: " and ")
        for apostrophe in ["'", "’", "‘", "`"] {
            folded = folded.replacingOccurrences(of: apostrophe, with: "")
        }
        let mapped = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return collapse(String(mapped))
    }

    static func splitArtistTitle(_ title: String) -> (String, String)? {
        for separator in [" - ", " – ", " — ", " -- "] {
            if let range = title.range(of: separator) {
                let left = String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                let right = String(title[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !left.isEmpty && !right.isEmpty { return (left, right) }
            }
        }
        return nil
    }

    private static func stripNoiseBrackets(_ value: String) -> String {
        var result = value
        let patterns = ["\\([^()]*\\)", "\\[[^\\[\\]]*\\]", "【[^【】]*】", "（[^（）]*）", "〔[^〔〕]*〕"]
        for pattern in patterns {
            var searchStart = result.startIndex
            while let range = result.range(of: pattern, options: .regularExpression, range: searchStart..<result.endIndex) {
                let inner = result[range].dropFirst().dropLast().lowercased()
                let tokens = inner.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "/") }).map(String.init)
                if tokens.contains(where: { bracketNoise.contains($0) }) {
                    result.replaceSubrange(range, with: " ")
                    searchStart = result.startIndex
                } else {
                    searchStart = range.upperBound
                }
            }
        }
        return collapse(result)
    }

    private static func stripFeaturing(_ value: String) -> String {
        var result = value
        if let range = result.range(of: "(?i)\\s+(ft|feat|featuring)\\b\\.?\\s+.*$", options: .regularExpression) {
            result.removeSubrange(range)
        }
        return result
    }

    private static func firstPipeSegment(_ value: String) -> String {
        let first = value.components(separatedBy: " | ").first ?? value
        return first.trimmingCharacters(in: .whitespaces).isEmpty ? value : first
    }

    private static func splitCamelCase(_ value: String) -> String {
        var output = ""
        var previous: Character?
        for character in value {
            if let previous, previous.isLowercase, character.isUppercase { output.append(" ") }
            output.append(character)
            previous = character
        }
        return output
    }

    private static func collapse(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

struct LRCLIBRecord: Decodable, Equatable {
    let trackName: String?
    let artistName: String?
    let albumName: String?
    let duration: Double?
    let instrumental: Bool?
    let plainLyrics: String?
    let syncedLyrics: String?

    init(trackName: String?, artistName: String?, albumName: String? = nil, duration: Double?,
         instrumental: Bool? = false, plainLyrics: String? = nil, syncedLyrics: String? = nil) {
        self.trackName = trackName
        self.artistName = artistName
        self.albumName = albumName
        self.duration = duration
        self.instrumental = instrumental
        self.plainLyrics = plainLyrics
        self.syncedLyrics = syncedLyrics
    }
}

/// Never take an unvalidated hit: the title must match after normalization
/// and the length must be within 5 s (or, when the length is unknown, the
/// artist must match too).
enum LRCLIBMatcher {
    static let maxDurationDifference: Double = 5

    static func titleMatches(_ record: LRCLIBRecord, query: LyricsQuery) -> Bool {
        guard let name = record.trackName, !name.isEmpty else { return false }
        let target = LyricsQueryNormalizer.key(query.track)
        guard !target.isEmpty else { return false }
        let direct = LyricsQueryNormalizer.key(LyricsQueryNormalizer.cleanTrack(name))
        // Some LRCLIB entries carry the full YouTube title "Artist - Title (Official Video)".
        let split = LyricsQueryNormalizer.key(LyricsQueryNormalizer.query(videoTitle: name, channel: record.artistName).track)
        return direct == target || split == target
    }

    static func artistMatches(_ record: LRCLIBRecord, query: LyricsQuery) -> Bool {
        let candidate = LyricsQueryNormalizer.key(LyricsQueryNormalizer.cleanChannel(record.artistName ?? ""))
        let wanted = LyricsQueryNormalizer.key(query.artist)
        guard !candidate.isEmpty, !wanted.isEmpty else { return false }
        return candidate == wanted
            || (candidate.count >= 3 && wanted.contains(candidate))
            || (wanted.count >= 3 && candidate.contains(wanted))
    }

    static func durationDifference(_ record: LRCLIBRecord, duration: Double) -> Double? {
        guard duration > 0, let candidate = record.duration, candidate > 0 else { return nil }
        return abs(candidate - duration)
    }

    static func hasLyrics(_ record: LRCLIBRecord) -> Bool {
        guard record.instrumental != true else { return false }
        let synced = record.syncedLyrics?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let plain = record.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !synced.isEmpty || !plain.isEmpty
    }

    static func isAcceptable(_ record: LRCLIBRecord, query: LyricsQuery, duration: Double) -> Bool {
        guard hasLyrics(record), titleMatches(record, query: query) else { return false }
        if duration > 0 {
            guard let diff = durationDifference(record, duration: duration) else { return false }
            return diff <= maxDurationDifference
        }
        return artistMatches(record, query: query)
    }

    static func best(_ records: [LRCLIBRecord], query: LyricsQuery, duration: Double) -> LRCLIBRecord? {
        records.filter { isAcceptable($0, query: query, duration: duration) }
            .sorted { a, b in
                let aArtist = artistMatches(a, query: query), bArtist = artistMatches(b, query: query)
                if aArtist != bArtist { return aArtist }
                let aSynced = !(a.syncedLyrics ?? "").isEmpty, bSynced = !(b.syncedLyrics ?? "").isEmpty
                if aSynced != bSynced { return aSynced }
                return (durationDifference(a, duration: duration) ?? 0) < (durationDifference(b, duration: duration) ?? 0)
            }
            .first
    }

    static func vtt(for record: LRCLIBRecord, fallbackDuration: Double) -> String? {
        if let synced = record.syncedLyrics, let vtt = LyricsVTTWriter.vtt(fromLRC: synced) { return vtt }
        if let plain = record.plainLyrics,
           let vtt = LyricsVTTWriter.vtt(fromPlainLyrics: plain, duration: record.duration ?? fallbackDuration) {
            return vtt
        }
        return nil
    }
}

enum LRCLIBClient {
    struct Lookup {
        let vtt: String?
        let networkFailed: Bool
    }

    private enum Response {
        case ok(Data)
        case status(Int)
        case network
    }

    static let userAgent = "OwenisasMusic/1.0 (https://github.com/owenisas/Owenisas-Music)"

    /// get (exact signature) → search by fields → free-text search; every
    /// hit is validated by `LRCLIBMatcher`.
    static func lyricsVTT(title: String, artist: String?, duration: Double, log: @escaping (String) -> Void) async -> Lookup {
        let query = LyricsQueryNormalizer.query(videoTitle: title, channel: artist)
        guard !query.track.isEmpty else { return Lookup(vtt: nil, networkFailed: false) }
        log("LRCLIB query track=\"\(query.track)\" artist=\"\(query.artist)\" duration=\(Int(duration))")

        if !query.artist.isEmpty, duration > 0 {
            let items = [
                URLQueryItem(name: "track_name", value: query.track),
                URLQueryItem(name: "artist_name", value: query.artist),
                URLQueryItem(name: "duration", value: String(Int(duration.rounded()))),
            ]
            switch await request(path: "/api/get", items: items, log: log) {
            case .network:
                return Lookup(vtt: nil, networkFailed: true)
            case .ok(let data):
                if let record = try? JSONDecoder().decode(LRCLIBRecord.self, from: data),
                   LRCLIBMatcher.isAcceptable(record, query: query, duration: duration),
                   let vtt = LRCLIBMatcher.vtt(for: record, fallbackDuration: duration) {
                    log("LRCLIB get: hit (\(record.syncedLyrics?.isEmpty == false ? "synced" : "plain"))")
                    return Lookup(vtt: vtt, networkFailed: false)
                }
                log("LRCLIB get: miss (no validated match)")
            case .status:
                log("LRCLIB get: miss")
            }
        }

        var searches: [[URLQueryItem]] = []
        var fields = [URLQueryItem(name: "track_name", value: query.track)]
        if !query.artist.isEmpty { fields.append(URLQueryItem(name: "artist_name", value: query.artist)) }
        searches.append(fields)
        searches.append([URLQueryItem(name: "q", value: [query.artist, query.track].filter { !$0.isEmpty }.joined(separator: " "))])

        for (index, items) in searches.enumerated() {
            if Task.isCancelled { break }
            switch await request(path: "/api/search", items: items, log: log) {
            case .network:
                return Lookup(vtt: nil, networkFailed: true)
            case .ok(let data):
                let records = (try? JSONDecoder().decode([LRCLIBRecord].self, from: data)) ?? []
                if let best = LRCLIBMatcher.best(records, query: query, duration: duration),
                   let vtt = LRCLIBMatcher.vtt(for: best, fallbackDuration: duration) {
                    log("LRCLIB search \(index + 1): hit \"\(best.trackName ?? "")\" by \(best.artistName ?? "?") (\(Int(best.duration ?? 0))s)")
                    return Lookup(vtt: vtt, networkFailed: false)
                }
                log("LRCLIB search \(index + 1): miss (\(records.count) results, none validated)")
            case .status:
                continue
            }
        }
        return Lookup(vtt: nil, networkFailed: false)
    }

    private static func request(path: String, items: [URLQueryItem], log: (String) -> Void) async -> Response {
        var components = URLComponents(string: "https://lrclib.net" + path)!
        components.queryItems = items
        guard let url = components.url else { return .status(0) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await LyricsFetcher.session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            log("LRCLIB \(path) HTTP \(code) (\(data.count) bytes)")
            return code == 200 ? .ok(data) : .status(code)
        } catch {
            log("LRCLIB \(path) failed: \(error.localizedDescription)")
            return .network
        }
    }
}

enum LyricsFetcher {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    struct Result {
        var files: [(lang: String, vtt: String)] = []
        var lrclibAttempted = false
        var lrclibNetworkFailed = false
    }

    /// Finds lyrics for a song already in the library (NowPlayingView's
    /// "Find lyrics"). Tries YouTube captions when meta.json or the folder
    /// name gives a video ID, then LRCLIB by title/artist/duration, so it also
    /// works for imported songs. Writes `{folder}.lyrics.vtt` /
    /// `{folder}.{lang}.vtt`, refreshes the subtitle cache and the library
    /// row, and returns true if any file was written.
    static func fetchMissingLyrics(for song: Song) async -> Bool {
        guard let folder = song.songFolderURL else { return false }
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.path) else { return false }
        let stem = folder.lastPathComponent
        let log: (String) -> Void = { DownloadDebugLog.write("Find lyrics [\(stem)]: \($0)") }

        let meta = SongFolderMetadata.read(from: folder)
        var title = meta?.title ?? song.title
        var artist: String? = meta?.artist ?? (song.artist == "Unknown Artist" ? nil : song.artist)
        var duration = meta?.duration ?? 0
        let existing = existingLyricLanguages(in: folder)

        var tracks: [CaptionTrack] = []
        var language: String?
        let inferredID = YouTubeLinkClassifier.isVideoID(stem) ? stem : nil
        if let videoId = meta?.videoId ?? inferredID {
            do {
                let info = try await YouTubeClient.shared.fetchCaptionInfo(videoId: videoId)
                // A folder that merely looks like a video ID must also match
                // by title before its captions are trusted.
                let trusted = meta?.videoId != nil
                    || title == stem
                    || LyricsQueryNormalizer.key(title) == LyricsQueryNormalizer.key(info.title)
                if trusted {
                    tracks = info.tracks
                    language = info.language
                    if title == stem || title.isEmpty { title = info.title }
                    if artist == nil { artist = info.author }
                    if duration <= 0 { duration = info.duration ?? 0 }
                } else {
                    log("folder name looks like a video ID but the titles differ; skipping captions")
                }
            } catch {
                log("caption lookup failed: \(error.localizedDescription)")
            }
        }
        if duration <= 0 {
            duration = await audioDuration(of: song.audioFileURL)
        }

        let result = await fetchLyricFiles(captions: tracks, language: language, title: title, artist: artist,
                                           duration: duration, skipLanguages: existing,
                                           includeLRCLIB: !existing.contains("lyrics"), log: log)
        var wrote = false
        for file in result.files {
            let dest = folder.appendingPathComponent("\(stem).\(file.lang).vtt")
            guard !fm.fileExists(atPath: dest.path) else { continue }
            do {
                try file.vtt.write(to: dest, atomically: true, encoding: .utf8)
                wrote = true
            } catch {
                log("couldn't write \(dest.lastPathComponent): \(error.localizedDescription)")
            }
        }
        log(wrote ? "wrote \(result.files.count) file(s)" : "nothing found")
        if wrote {
            await MainActor.run {
                Song.invalidateSubtitleCache(forFolder: folder)
                DataManager.shared.syncSingleSong(folderName: stem)
            }
        }
        return wrote
    }

    /// Caption files (original language + English) and LRCLIB lyrics
    /// ("lyrics") as VTT text. Nothing is written here.
    static func fetchLyricFiles(captions: [CaptionTrack], language: String?, title: String, artist: String?,
                                duration: Double, skipLanguages: Set<String> = [], includeLRCLIB: Bool = true,
                                log: @escaping (String) -> Void) async -> Result {
        var result = Result()
        for pick in CaptionTrackPicker.select(from: captions, originalLanguage: language)
        where !skipLanguages.contains(pick.lang) {
            if Task.isCancelled { return result }
            if let vtt = await downloadCaption(pick.url, log: log) {
                result.files.append((pick.lang, vtt))
                log("captions \(pick.lang): saved")
            }
        }
        if includeLRCLIB, !Task.isCancelled {
            result.lrclibAttempted = true
            let lookup = await LRCLIBClient.lyricsVTT(title: title, artist: artist, duration: duration, log: log)
            result.lrclibNetworkFailed = lookup.networkFailed
            if let vtt = lookup.vtt { result.files.append(("lyrics", vtt)) }
        }
        return result
    }

    static func folderHasSubtitles(_ folder: URL) -> Bool {
        !existingLyricLanguages(in: folder).isEmpty
    }

    /// Language suffixes of `*.{lang}.vtt` files already in the folder.
    static func existingLyricLanguages(in folder: URL) -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var languages = Set<String>()
        for file in files where file.pathExtension.lowercased() == "vtt" {
            let stem = file.deletingPathExtension().lastPathComponent
            let parts = stem.components(separatedBy: ".")
            languages.insert(parts.count >= 2 ? (parts.last ?? "original") : "original")
        }
        return languages
    }

    private static func downloadCaption(_ urlString: String, log: (String) -> Void) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue(YouTubeClient.safariUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/vtt,*/*;q=0.8", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, let text = String(data: data, encoding: .utf8) else {
                log("captions HTTP \(code) (\(data.count) bytes)")
                return nil
            }
            let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}").union(.whitespacesAndNewlines))
            guard trimmed.hasPrefix("WEBVTT"), trimmed.contains("-->"),
                  !LyricsParser.parseVTT(content: trimmed).isEmpty else {
                log("captions response wasn't usable VTT (\(data.count) bytes)")
                return nil
            }
            return trimmed + "\n"
        } catch {
            log("captions request failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func audioDuration(of url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return 0 }
        let seconds = duration.seconds
        return seconds.isFinite && seconds > 0 ? seconds : 0
    }
}
#endif
