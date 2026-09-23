import Foundation

/// The library side of sync: SwiftData in the app (DataManager), an
/// in-memory model in tests.
@MainActor
protocol CloudLibraryStore: AnyObject {
    /// Nil when the library isn't ready; the pass is skipped rather than
    /// mistaking "not loaded" for "empty".
    func cloudSnapshot() -> LibrarySnapshot?
    /// Applies a merge. `removeSongFolder` sets a deleted song's folder
    /// aside; its row is only removed when that succeeded.
    @discardableResult
    func applyCloudPlan(_ plan: LibraryApplyPlan, removeSongFolder: (String) -> Bool) -> Bool
    /// Index a folder that just arrived from iCloud.
    func indexCloudFolder(_ folderName: String)
    /// Songs that must not be removed right now (the one playing).
    var cloudProtectedSongIDs: Set<String> { get }
}

/// Where sync keeps its own files on this device.
struct CloudSyncLocalPaths {
    var stateURL: URL
    var stagingDirectory: URL
    var holdingDirectory: URL

    static func standard() -> CloudSyncLocalPaths {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return rooted(at: support.appendingPathComponent("CloudSync", isDirectory: true))
    }

    static func rooted(at root: URL) -> CloudSyncLocalPaths {
        CloudSyncLocalPaths(
            stateURL: root.appendingPathComponent("state.json"),
            stagingDirectory: root.appendingPathComponent("Staging", isDirectory: true),
            holdingDirectory: root.appendingPathComponent("Removed", isDirectory: true)
        )
    }
}

/// Output of the main-actor half of a pass, for the I/O half.
struct CloudPassOutput {
    var mirrorPlan: MirrorPlan
    /// Own library file to write, when it changed or is missing in iCloud.
    var ownFile: (data: Data, digest: Data)?
}

/// One device's sync state plus the steps of a pass. State is only touched
/// on the main actor; `CloudFileMirror` does the disk work in between.
@MainActor
final class CloudSyncEngine {
    let mirror: CloudFileMirror
    let stateURL: URL
    private(set) var state: CloudSyncLocalState
    /// Explicit edits since the last capture.
    var pendingChanges = LibraryLocalChanges()
    /// Whether a saved state was loaded (vs. starting fresh).
    let resumedExistingState: Bool

    /// `loadedState` must already be checked against the signed-in account
    /// (see `LibraryCloudSync.isSameAccount`); pass nil to start fresh.
    init(mirror: CloudFileMirror, stateURL: URL, loadedState: CloudSyncLocalState?,
         deviceID: String, deviceName: String?, accountFingerprint: Data?) {
        self.mirror = mirror
        self.stateURL = stateURL
        if var loaded = loadedState, loaded.own.deviceID == deviceID {
            loaded.accountFingerprint = accountFingerprint ?? loaded.accountFingerprint
            loaded.own.deviceName = deviceName
            state = loaded
            resumedExistingState = true
        } else {
            // First run, or a different iCloud account: nothing from before
            // (tombstones, what was mirrored) may leak into this account.
            state = CloudSyncLocalState(deviceID: deviceID, deviceName: deviceName, accountFingerprint: accountFingerprint)
            resumedExistingState = false
        }
    }

    nonisolated static func loadState(from url: URL) -> CloudSyncLocalState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? CloudSyncCoding.decoder().decode(CloudSyncLocalState.self, from: data)
    }

    nonisolated static func encode(_ state: CloudSyncLocalState) -> Data? {
        try? CloudSyncCoding.encoder().encode(state)
    }

    nonisolated static func write(_ data: Data, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            print("[DEBUG] CloudSync: couldn't save state: \(error.localizedDescription)")
        }
    }

    /// Synchronous save, for explicit deletions that must survive a crash.
    func saveStateNow() {
        if let data = Self.encode(state) { Self.write(data, to: stateURL) }
    }

    // MARK: - Explicit events

    func recordSongDeletions(_ ids: [String], at date: Date) {
        LibraryMergeEngine.recordSongDeletions(ids, at: date, state: &state)
    }

    func recordPlaylistDeletion(id: String, title: String?, at date: Date) {
        LibraryMergeEngine.recordPlaylistDeletion(id: id, title: title, at: date, state: &state)
    }

    func recordFavorite(songID: String, value: Bool, at date: Date) {
        pendingChanges.favorites[songID] = .init(value: value, at: date)
    }

    func recordPosition(songID: String, value: Double, at date: Date) {
        guard value.isFinite else { return }
        pendingChanges.positions[songID] = .init(value: max(0, value), at: date)
    }

    func treatNextDiffsAsExplicit() {
        pendingChanges.treatDiffsAsExplicit = true
    }

    // MARK: - Pass steps

    /// Fold in other devices' files, capture local edits, and merge.
    func reconcile(_ gathered: CloudGatherResult, snapshot: LibrarySnapshot, now: Date,
                   allowDestructive: Bool, protectedSongIDs: Set<String>) -> LibraryApplyPlan {
        for file in gathered.libraries where file.deviceID != state.own.deviceID {
            if let cached = state.remoteFiles[file.deviceID], cached.updatedAt > file.updatedAt { continue }
            state.remoteFiles[file.deviceID] = file
        }
        LibraryMergeEngine.capture(snapshot, changes: pendingChanges, state: &state, now: now)
        pendingChanges = LibraryLocalChanges()
        return LibraryMergeEngine.merge(
            snapshot,
            others: Array(state.remoteFiles.values),
            state: &state,
            now: now,
            allowDestructive: allowDestructive,
            protectedSongIDs: protectedSongIDs
        )
    }

    /// After the library applied the merge: remember the new local shape,
    /// plan the file mirror, and prepare the own file if it changed.
    func finishApply(postSnapshot: LibrarySnapshot, gathered: CloudGatherResult,
                     removedLocalFolders: Set<String>, now: Date) -> CloudPassOutput {
        LibraryMergeEngine.refreshMarks(from: postSnapshot, state: &state)

        var local = gathered.localFolders
        for key in removedLocalFolders { local[key] = nil }
        let indexed = Dictionary(postSnapshot.songs.map { ($0.id, $0.dateAdded) }, uniquingKeysWith: { first, _ in first })
        for (key, folder) in local {
            var updated = folder
            if let entry = indexed[key] {
                updated.isIndexed = true
                updated.addedAt = entry ?? folder.fileDate
            }
            local[key] = updated
        }

        let tombstones = LibraryMergeEngine.effectiveSongTombstones(own: state.own, others: Array(state.remoteFiles.values))
        let plan = CloudMirrorPlanner.plan(MirrorPlanInput(
            local: local,
            remote: gathered.remoteFolders,
            tombstones: tombstones,
            mirrored: state.mirroredFolders,
            pendingRemoteDeletes: state.pendingRemoteDeletes,
            remoteListingComplete: gathered.remoteListingComplete
        ))
        for key in plan.markMirrored { state.mirroredFolders[key] = now }

        var ownFile: (Data, Data)?
        if let digest = state.own.contentDigest(), digest != state.publishedDigest || !gathered.ownFileExists {
            var file = state.own
            file.updatedAt = now
            if let data = try? CloudSyncCoding.encoder().encode(file) {
                ownFile = (data, digest)
            }
        }
        return CloudPassOutput(mirrorPlan: plan, ownFile: ownFile)
    }

    /// Record what the I/O half achieved.
    func complete(_ result: MirrorExecutionResult, plan: MirrorPlan, publishedDigest: Data?, now: Date) {
        for key in result.uploadedFolders { state.mirroredFolders[key] = now }
        for name in result.importedFolders + result.updatedFolders {
            state.mirroredFolders[CloudSyncFiles.folderKey(name)] = now
        }
        for key in result.removedRemote + plan.dropPendingDeletes { state.pendingRemoteDeletes[key] = nil }
        if let publishedDigest { state.publishedDigest = publishedDigest }
    }

    // MARK: - Whole pass (tests; the app runs the same steps across queues)

    @discardableResult
    func runPass(store: CloudLibraryStore, queryEntries: [RemoteFileEntry] = [], remoteListingComplete: Bool = true,
                 now: Date = Date(), allowDestructive: Bool = true) -> (plan: LibraryApplyPlan, mirror: MirrorPlan, result: MirrorExecutionResult)? {
        let gathered = mirror.gather(ownDeviceID: state.own.deviceID, queryEntries: queryEntries,
                                     remoteListingComplete: remoteListingComplete)
        guard let snapshot = store.cloudSnapshot() else { return nil }
        let plan = reconcile(gathered, snapshot: snapshot, now: now, allowDestructive: allowDestructive,
                             protectedSongIDs: store.cloudProtectedSongIDs)
        var removed = Set<String>()
        if !plan.isEmpty {
            store.applyCloudPlan(plan) { id in
                let moved = mirror.moveLocalFolderToHolding(id, now: now)
                if moved { removed.insert(CloudSyncFiles.folderKey(id)) }
                return moved
            }
        }
        let post = store.cloudSnapshot() ?? snapshot
        let output = finishApply(postSnapshot: post, gathered: gathered, removedLocalFolders: removed, now: now)
        var published: Data?
        if let own = output.ownFile {
            do {
                try mirror.writeOwnLibraryFile(own.data, deviceID: state.own.deviceID)
                published = own.digest
            } catch {
                print("[DEBUG] CloudSync: couldn't write library file: \(error.localizedDescription)")
            }
        }
        let result = mirror.execute(output.mirrorPlan)
        complete(result, plan: output.mirrorPlan, publishedDigest: published, now: now)
        for name in result.importedFolders + result.updatedFolders { store.indexCloudFolder(name) }
        saveStateNow()
        return (plan, output.mirrorPlan, result)
    }
}
