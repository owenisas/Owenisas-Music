import Foundation
import UIKit

/// iCloud sync of songs + library data across the owner's devices.
///
/// `Documents/Songs/<folder>/` stays the only place the app reads and plays
/// from. The iCloud container is a mirror: new local folders are copied up
/// (then the container copy is evicted), folders from other devices are
/// downloaded, copied in, indexed and evicted. Likes, playlists, play counts
/// and resume positions travel as one JSON file per device, merged here.
///
/// Everything no-ops with a clear status when iCloud is unavailable. The
/// container URL is resolved off the main thread; file work runs on a
/// serial utility queue; SwiftData is only touched on the main actor.
/// (`@unchecked Sendable`: mutable state is confined to the main actor,
/// except `lastSavedState`, which only the serial I/O queue touches.)
final class LibraryCloudSync: ObservableObject, @unchecked Sendable {
    static let shared = LibraryCloudSync()

    @Published private(set) var status: CloudSyncStatus = .off
    /// Songs in iCloud and their total size, once the container was listed.
    @Published private(set) var cloudSongCount: Int?
    @Published private(set) var cloudBytes: Int64?

    private let ioQueue = DispatchQueue(label: "com.Owenisas-Music.cloudsync", qos: .utility)
    private let queryQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.Owenisas-Music.cloudsync.query"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()

    // Main-actor state.
    private var started = false
    private var generation = 0
    private var engine: CloudSyncEngine?
    private var query: NSMetadataQuery?
    private var queryObservers: [NSObjectProtocol] = []
    private var observers: [NSObjectProtocol] = []
    private var latestQueryEntries: [RemoteFileEntry] = []
    private var queryGathered = false
    private var scheduledPass: DispatchWorkItem?
    private var scheduledFireDate: Date?
    private var passInFlight = false
    private var rerunRequested = false
    private var isApplying = false
    private var allowDestructiveOnce = true
    private var reenabledByUser = false
    private var periodicTimer: Timer?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// Last state bytes written (I/O queue only).
    private var lastSavedState: Data?
    /// Deletions made before the engine finished loading.
    private var earlySongDeletions: [(ids: [String], at: Date)] = []
    private var earlyPlaylistDeletions: [(id: String, title: String?, at: Date)] = []

    private init() {}

    // MARK: - Public API

    /// Called once at launch (FeatureBootstrap), after the library is indexed.
    func start() {
        Task { @MainActor in self.startOnMain() }
    }

    /// Persisted user choice; defaults to on when an iCloud account exists.
    var isEnabled: Bool {
        if let stored = UserDefaults.standard.object(forKey: CloudSyncConstants.enabledDefaultsKey) as? Bool {
            return stored
        }
        return FileManager.default.ubiquityIdentityToken != nil
    }

    var isICloudAvailable: Bool { FileManager.default.ubiquityIdentityToken != nil }

    /// The Settings toggle.
    func setEnabled(_ enabled: Bool) {
        onMain { self.applyEnabled(enabled) }
    }

    /// Settings calls this on appear: picks up a sign-in or sign-out.
    func refreshAvailability() {
        onMain { self.refreshAvailabilityOnMain() }
    }

    private func onMain(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated(body) }
        }
    }

    @MainActor
    private func applyEnabled(_ enabled: Bool) {
        let wasEnabled = isEnabled
        UserDefaults.standard.set(enabled, forKey: CloudSyncConstants.enabledDefaultsKey)
        objectWillChange.send()
        if enabled, !wasEnabled { reenabledByUser = true }
        startOnMain()
        activate()
    }

    @MainActor
    private func refreshAvailabilityOnMain() {
        startOnMain()
        let available = isICloudAvailable
        if !available, status != .unavailable {
            activate()
        } else if available, status == .unavailable || (engine == nil && isEnabled && status != .checking) {
            activate()
        } else if engine != nil {
            schedulePass(after: 0.2)
        }
    }

    /// "12 (340 MB)" for Settings, nil until known.
    var cloudLibrarySummary: String? {
        guard let count = cloudSongCount else { return nil }
        let size = ByteCountFormatter.string(fromByteCount: cloudBytes ?? 0, countStyle: .file)
        return "\(count) (\(size))"
    }

    // MARK: - Lifecycle

    @MainActor
    private func startOnMain() {
        guard !started else { return }
        started = true
        registerObservers()
        activate()
    }

    /// (Re)builds everything for the current account and setting.
    @MainActor
    private func activate() {
        generation += 1
        let token = generation
        tearDown()

        guard let identity = FileManager.default.ubiquityIdentityToken else {
            status = .unavailable
            cloudSongCount = nil
            cloudBytes = nil
            return
        }
        guard isEnabled else {
            status = .off
            cloudSongCount = nil
            cloudBytes = nil
            return
        }
        status = .checking

        let paths = CloudSyncLocalPaths.standard()
        let deviceID = Self.deviceID()
        let deviceName = UIDevice.current.name
        let fingerprint = try? NSKeyedArchiver.archivedData(withRootObject: identity, requiringSecureCoding: false)
        let localSongs = documentsDirectoryURL.appendingPathComponent("Songs", isDirectory: true)

        ioQueue.async {
            // Can block on first use; never on the main thread.
            let container = FileManager.default.url(forUbiquityContainerIdentifier: CloudSyncConstants.containerIdentifier)
            var loaded = CloudSyncEngine.loadState(from: paths.stateURL)
            if let stored = loaded?.accountFingerprint, !Self.isSameAccount(stored, as: fingerprint) {
                loaded = nil
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard token == self.generation else { return }
                    guard let container else {
                        self.status = .unavailable
                        return
                    }
                    let mirror = CloudFileMirror(
                        localSongs: localSongs,
                        containerDocuments: container.appendingPathComponent("Documents", isDirectory: true),
                        stagingDirectory: paths.stagingDirectory,
                        holdingDirectory: paths.holdingDirectory
                    )
                    let engine = CloudSyncEngine(
                        mirror: mirror,
                        stateURL: paths.stateURL,
                        loadedState: loaded,
                        deviceID: deviceID,
                        deviceName: deviceName,
                        accountFingerprint: fingerprint
                    )
                    self.install(engine)
                }
            }
        }
    }

    @MainActor
    private func install(_ engine: CloudSyncEngine) {
        self.engine = engine
        ioQueue.async { self.lastSavedState = nil }
        for deletion in earlySongDeletions { engine.recordSongDeletions(deletion.ids, at: deletion.at) }
        for deletion in earlyPlaylistDeletions { engine.recordPlaylistDeletion(id: deletion.id, title: deletion.title, at: deletion.at) }
        if !earlySongDeletions.isEmpty || !earlyPlaylistDeletions.isEmpty { persistState() }
        earlySongDeletions.removeAll()
        earlyPlaylistDeletions.removeAll()
        if reenabledByUser, engine.resumedExistingState {
            // Likes changed while sync was off are this device's edits.
            engine.treatNextDiffsAsExplicit()
        }
        reenabledByUser = false
        allowDestructiveOnce = true
        startQuery(containerDocuments: engine.mirror.containerDocuments)
        startPeriodicTimer()
        schedulePass(after: 0.5)
        let mirror = engine.mirror
        ioQueue.async { mirror.purgeHolding() }
    }

    @MainActor
    private func tearDown() {
        scheduledPass?.cancel()
        scheduledPass = nil
        scheduledFireDate = nil
        periodicTimer?.invalidate()
        periodicTimer = nil
        stopQuery()
        engine = nil
        latestQueryEntries = []
        queryGathered = false
        passInFlight = false
        rerunRequested = false
    }

    static func deviceID() -> String {
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: CloudSyncConstants.deviceIDDefaultsKey), !id.isEmpty { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: CloudSyncConstants.deviceIDDefaultsKey)
        return id
    }

    /// Identity tokens are compared with `isEqual` (archives aren't
    /// guaranteed byte-stable). Unreadable → assume the same account, since
    /// a needless reset would double-count this device's plays.
    static func isSameAccount(_ stored: Data, as current: Data?) -> Bool {
        guard let current else { return true }
        if stored == current { return true }
        guard let old = unarchive(stored), let new = unarchive(current) else { return true }
        return old.isEqual(new)
    }

    private static func unarchive(_ data: Data) -> NSObject? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = false
        defer { unarchiver.finishDecoding() }
        return unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? NSObject
    }

    // MARK: - Metadata query

    @MainActor
    private func startQuery(containerDocuments: URL) {
        // Only used on `queryQueue` after this point (start, results, stop).
        nonisolated(unsafe) let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K LIKE %@", NSMetadataItemFSNameKey, "*")
        query.operationQueue = queryQueue
        let documentsPath = containerDocuments.path
        let token = generation
        // The observer tokens (removed in stopQuery) own this closure, so
        // holding the query strongly here makes no cycle.
        let handler: @Sendable (Notification) -> Void = { [weak self] note in
            query.disableUpdates()
            let items = query.results.compactMap { $0 as? NSMetadataItem }
            let entries = CloudFileMirror.entries(fromQueryResults: items, documentsPath: documentsPath)
            query.enableUpdates()
            let finishedGathering = note.name == .NSMetadataQueryDidFinishGathering
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, token == self.generation else { return }
                    self.latestQueryEntries = entries
                    if finishedGathering { self.queryGathered = true }
                    self.schedulePass(after: finishedGathering ? 0.2 : CloudSyncConstants.changeDebounce)
                }
            }
        }
        queryObservers = [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate].map {
            NotificationCenter.default.addObserver(forName: $0, object: query, queue: nil, using: handler)
        }
        self.query = query
        queryQueue.addOperation { query.start() }
    }

    @MainActor
    private func stopQuery() {
        for observer in queryObservers { NotificationCenter.default.removeObserver(observer) }
        queryObservers = []
        if let running = query {
            nonisolated(unsafe) let stopping = running
            queryQueue.addOperation { stopping.stop() }
        }
        query = nil
    }

    // MARK: - Triggers

    @MainActor
    private func registerObservers() {
        let center = NotificationCenter.default
        func observe(_ name: Notification.Name, _ handler: @escaping @MainActor (Notification) -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                MainActor.assumeIsolated { handler(note) }
            })
        }
        func fromLibrary(_ note: Notification) -> Bool {
            (note.object as AnyObject?) === DataManager.shared
        }

        observe(.init("SongPlayed")) { [weak self] _ in
            self?.schedulePass(after: CloudSyncConstants.changeDebounce)
        }
        observe(.init("SongFavoriteToggled")) { [weak self] _ in
            self?.schedulePass(after: CloudSyncConstants.changeDebounce)
        }
        observe(.libraryFavoriteChanged) { [weak self] note in
            guard let self, fromLibrary(note),
                  let id = note.userInfo?["id"] as? String,
                  let value = note.userInfo?["isFavorited"] as? Bool else { return }
            self.engine?.recordFavorite(songID: id, value: value, at: Date())
            self.schedulePass(after: CloudSyncConstants.changeDebounce)
        }
        observe(.init("SongPositionChanged")) { [weak self] note in
            guard let self, let id = note.object as? String,
                  let position = note.userInfo?["position"] as? TimeInterval else { return }
            self.engine?.recordPosition(songID: id, value: position, at: Date())
            self.schedulePass(after: CloudSyncConstants.positionDebounce)
        }
        observe(.init("PlaylistsChanged")) { [weak self] _ in
            guard let self, !self.isApplying else { return }
            self.schedulePass(after: CloudSyncConstants.changeDebounce)
        }
        observe(.init("SongsFolderChanged")) { [weak self] _ in
            guard let self, !self.isApplying else { return }
            self.schedulePass(after: CloudSyncConstants.changeDebounce)
        }
        observe(.librarySongIndexed) { [weak self] note in
            guard let self, !self.isApplying, fromLibrary(note) else { return }
            self.schedulePass(after: CloudSyncConstants.changeDebounce)
        }
        observe(.librarySongsDeleted) { [weak self] note in
            guard let self, fromLibrary(note), let ids = note.userInfo?["ids"] as? [String], !ids.isEmpty else { return }
            self.recordSongDeletions(ids)
        }
        observe(.libraryPlaylistDeleted) { [weak self] note in
            guard let self, fromLibrary(note), let id = note.userInfo?["id"] as? String else { return }
            self.recordPlaylistDeletion(id: id, title: note.userInfo?["title"] as? String)
        }
        observe(.libraryBackupImported) { [weak self] note in
            guard let self, fromLibrary(note) else { return }
            self.engine?.treatNextDiffsAsExplicit()
            self.schedulePass(after: CloudSyncConstants.changeDebounce)
        }
        observe(.NSUbiquityIdentityDidChange) { [weak self] _ in
            self?.activate()
        }
        observe(UIApplication.didBecomeActiveNotification) { [weak self] _ in
            guard let self, self.started else { return }
            self.refreshAvailabilityOnMain()
            if self.engine != nil { self.startPeriodicTimer() }
        }
        observe(UIApplication.didEnterBackgroundNotification) { [weak self] _ in
            self?.enteredBackground()
        }
    }

    /// Deletions are recorded only while sync is on and an account exists,
    /// and saved immediately so they survive the app being killed.
    @MainActor
    private func recordSongDeletions(_ ids: [String]) {
        guard isEnabled, isICloudAvailable else { return }
        let now = Date()
        if let engine {
            engine.recordSongDeletions(ids, at: now)
            persistState()
        } else {
            earlySongDeletions.append((ids, now))
        }
        schedulePass(after: CloudSyncConstants.changeDebounce)
    }

    @MainActor
    private func recordPlaylistDeletion(id: String, title: String?) {
        guard isEnabled, isICloudAvailable else { return }
        let now = Date()
        if let engine {
            engine.recordPlaylistDeletion(id: id, title: title, at: now)
            persistState()
        } else {
            earlyPlaylistDeletions.append((id, title, now))
        }
        schedulePass(after: CloudSyncConstants.changeDebounce)
    }

    @MainActor
    private func startPeriodicTimer() {
        periodicTimer?.invalidate()
        let timer = Timer(timeInterval: CloudSyncConstants.periodicInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, UIApplication.shared.applicationState == .active else { return }
                self.schedulePass(after: 0)
            }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        periodicTimer = timer
    }

    @MainActor
    private func enteredBackground() {
        periodicTimer?.invalidate()
        periodicTimer = nil
        guard engine != nil else { return }
        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "iCloud library sync") { [weak self] in
                MainActor.assumeIsolated { self?.endBackgroundTask() }
            }
        }
        // Background is when removals from other devices are applied.
        schedulePass(after: 0)
    }

    @MainActor
    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: - Passes

    /// Coalesces triggers: an earlier scheduled pass absorbs later requests.
    @MainActor
    private func schedulePass(after delay: TimeInterval) {
        guard engine != nil else { return }
        let fireDate = Date().addingTimeInterval(delay)
        if let scheduled = scheduledFireDate, scheduled <= fireDate { return }
        scheduledPass?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.runPass() }
        }
        scheduledPass = work
        scheduledFireDate = fireDate
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: work)
    }

    @MainActor
    private func runPass() {
        scheduledPass = nil
        scheduledFireDate = nil
        guard let engine else { return }
        if passInFlight {
            rerunRequested = true
            return
        }
        passInFlight = true
        rerunRequested = false
        let token = generation
        let entries = latestQueryEntries
        let listingComplete = queryGathered
        let deviceID = engine.state.own.deviceID
        let mirror = engine.mirror
        ioQueue.async {
            let gathered = mirror.gather(ownDeviceID: deviceID, queryEntries: entries, remoteListingComplete: listingComplete)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.reconcileAndApply(gathered, engine: engine, token: token) }
            }
        }
    }

    @MainActor
    private func reconcileAndApply(_ gathered: CloudGatherResult, engine: CloudSyncEngine, token: Int) {
        // A stale pass from before a re-activation; tearDown already reset
        // the in-flight flag for the new generation.
        guard token == generation, self.engine === engine else { return }
        let store = DataManager.shared
        guard let snapshot = store.cloudSnapshot() else {
            passInFlight = false
            schedulePass(after: 5)
            return
        }
        let now = Date()
        let allowDestructive = allowDestructiveOnce || UIApplication.shared.applicationState != .active
        allowDestructiveOnce = false
        let plan = engine.reconcile(gathered, snapshot: snapshot, now: now, allowDestructive: allowDestructive,
                                    protectedSongIDs: store.cloudProtectedSongIDs)
        var removed = Set<String>()
        var applyErrors: [String] = []
        if !plan.isEmpty {
            isApplying = true
            let applied = store.applyCloudPlan(plan) { id in
                let moved = engine.mirror.moveLocalFolderToHolding(id, now: now)
                if moved { removed.insert(CloudSyncFiles.folderKey(id)) }
                return moved
            }
            isApplying = false
            if !applied { applyErrors.append("Could not save iCloud library changes. Retry sync after checking device storage.") }
        }
        let post = store.cloudSnapshot() ?? snapshot
        let output = engine.finishApply(postSnapshot: post, gathered: gathered, removedLocalFolders: removed, now: now)
        publishStatus(output.mirrorPlan, errors: applyErrors)

        let mirror = engine.mirror
        let deviceID = engine.state.own.deviceID
        let passErrors = applyErrors
        ioQueue.async {
            var published: Data?
            var writeError: String?
            if let own = output.ownFile {
                do {
                    try mirror.writeOwnLibraryFile(own.data, deviceID: deviceID)
                    published = own.digest
                } catch {
                    writeError = Self.describe(error)
                }
            }
            let result = mirror.execute(output.mirrorPlan)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.finishPass(result, plan: output.mirrorPlan, published: published, writeError: writeError,
                                    engine: engine, token: token, applyErrors: passErrors)
                }
            }
        }
    }

    @MainActor
    private func finishPass(_ result: MirrorExecutionResult, plan: MirrorPlan, published: Data?, writeError: String?,
                            engine: CloudSyncEngine, token: Int, applyErrors: [String]) {
        guard token == generation, self.engine === engine else { return }
        passInFlight = false
        engine.complete(result, plan: plan, publishedDigest: published, now: Date())

        let arrived = result.importedFolders + result.updatedFolders
        if !arrived.isEmpty {
            isApplying = true
            for name in arrived {
                DataManager.shared.indexCloudFolder(name)
                Song.invalidateSubtitleCache(forFolder: engine.mirror.localSongs.appendingPathComponent(name, isDirectory: true))
            }
            isApplying = false
            MusicPlayerManager.shared.refreshLibrarySongs(DataManager.shared.toSongs(DataManager.shared.fetchAllSongs()))
            NotificationCenter.default.post(name: .init("SongsFolderChanged"), object: nil)
        }
        persistState()

        for error in result.errors { print("[DEBUG] CloudSync: \(error)") }
        publishStatus(plan, errors: applyErrors + (writeError.map { [$0] } ?? []), mirrorResult: result)

        // New songs need a merge for their likes and playlist slots.
        if rerunRequested || result.moreWork || !arrived.isEmpty {
            schedulePass(after: 1)
        } else if scheduledPass == nil {
            endBackgroundTask()
        }
    }

    /// Encodes and writes on the I/O queue (in order with other file work),
    /// skipping the write when nothing changed.
    @MainActor
    private func persistState() {
        guard let engine else { return }
        let state = engine.state
        let url = engine.stateURL
        ioQueue.async {
            guard let data = CloudSyncEngine.encode(state), data != self.lastSavedState else { return }
            self.lastSavedState = data
            CloudSyncEngine.write(data, to: url)
        }
    }

    @MainActor
    func publishStatus(_ plan: MirrorPlan, errors: [String], mirrorResult: MirrorExecutionResult = .init()) {
        cloudSongCount = plan.songsInCloud
        cloudBytes = plan.bytesInCloud
        if let error = (errors + mirrorResult.errors).first {
            status = .failed(error)
        } else if !queryGathered {
            status = .checking
        } else if plan.uploadingCount > 0 || plan.downloadingCount > 0 {
            status = .syncing(uploading: plan.uploadingCount, downloading: plan.downloadingCount)
        } else {
            status = .upToDate
        }
    }

    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain,
           ns.code == NSFileWriteOutOfSpaceError || ns.code == NSUbiquitousFileUbiquityServerNotAvailable {
            return ns.code == NSFileWriteOutOfSpaceError ? "iCloud storage is full" : "iCloud is unavailable right now"
        }
        return "iCloud sync error: \(ns.localizedDescription)"
    }
}
