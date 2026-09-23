import Foundation

/// Music downloaded to the watch: files in Documents/Offline plus a JSON
/// index (`WatchOfflineIndex`, shared with the phone for tests).
@MainActor
final class OfflineLibrary: ObservableObject {
    static let shared = OfflineLibrary()

    @Published private(set) var index: WatchOfflineIndex
    @Published private(set) var freeBytes: Int64?
    @Published var capBytes: Int64 {
        didSet {
            guard !isPreview else { return }
            UserDefaults.standard.set(capBytes, forKey: Self.capKey)
        }
    }

    private let isPreview: Bool
    private static let capKey = "watchOfflineCapBytes"

    nonisolated static var directory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Offline", isDirectory: true)
    }

    private static var indexURL: URL { directory.appendingPathComponent("index.json") }

    private init() {
        isPreview = false
        let stored = UserDefaults.standard.object(forKey: Self.capKey) as? NSNumber
        capBytes = WatchStorage.normalizedCap(stored?.int64Value ?? WatchStorage.defaultCap)
        index = Self.loadIndex()
        refreshFreeSpace()
        sweepStrayFiles()
    }

    private init(preview index: WatchOfflineIndex) {
        isPreview = true
        capBytes = WatchStorage.defaultCap
        self.index = index
        freeBytes = 12 * WatchStorage.gigabyte
    }

    static func preview(_ index: WatchOfflineIndex = PreviewFixtures.offlineIndex) -> OfflineLibrary {
        OfflineLibrary(preview: index)
    }

    // MARK: - Queries

    var budgetBytes: Int64 {
        WatchStorage.budget(capBytes: capBytes, committedBytes: index.committedBytes, freeBytes: freeBytes)
    }

    var storageLevel: WatchStorage.Level {
        WatchStorage.level(committedBytes: index.committedBytes, capBytes: capBytes, freeBytes: freeBytes)
    }

    func state(for list: WatchListRef) -> WatchOfflineState {
        index.state(for: list)
    }

    func tracks(in list: WatchListRef) -> [WatchOfflineTrack] {
        index.tracks(in: list)
    }

    func fileURL(for track: WatchOfflineTrack) -> URL {
        Self.directory.appendingPathComponent(track.fileName)
    }

    func refreshFreeSpace() {
        guard !isPreview else { return }
        // The "important usage" capacity key doesn't exist on watchOS.
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if let available = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity {
            freeBytes = Int64(available)
        } else if let free = (try? FileManager.default.attributesOfFileSystem(forPath: url.path))?[.systemFreeSize] as? NSNumber {
            freeBytes = free.int64Value
        } else {
            freeBytes = nil
        }
    }

    // MARK: - Downloads

    func plan(for manifest: WatchDownloadManifest) -> WatchTransferPlan {
        refreshFreeSpace()
        return WatchTransferPlanner.plan(
            manifest: manifest.songs,
            onWatch: Set(index.tracks.keys),
            inFlight: index.pendingIDs,
            budgetBytes: budgetBytes
        )
    }

    /// Record the download and ask the phone to send the planned songs.
    func startDownload(_ manifest: WatchDownloadManifest, plan: WatchTransferPlan, phone: PhoneLink) async throws {
        let isNew = index.collection(manifest.list) == nil
        index.upsertCollection(
            list: manifest.list,
            title: manifest.title,
            manifestOrder: manifest.songs.map(\.id),
            requested: plan.toTransfer,
            present: plan.alreadyOnWatch + plan.inFlight
        )
        save()
        guard plan.hasWork else { return }
        do {
            let ack = try await phone.requestTransfers(manifest.list, songIDs: plan.toTransfer.map(\.id))
            for id in ack.unavailable { index.markFailed(id) }
            save()
        } catch {
            // Nothing was queued: don't leave songs "downloading" forever.
            if isNew && index.tracks(in: manifest.list).isEmpty {
                index.removeCollection(manifest.list)
            } else {
                for song in plan.toTransfer { index.markFailed(song.id) }
            }
            save()
            throw error
        }
    }

    /// Remove a download from the watch; shared songs stay for other lists.
    func remove(_ list: WatchListRef, phone: PhoneLink) {
        let result = index.removeCollection(list)
        for track in result.orphans {
            try? FileManager.default.removeItem(at: fileURL(for: track))
        }
        save()
        phone.cancelTransfers(result.cancelled)
        refreshFreeSpace()
    }

    func removeAll(phone: PhoneLink) {
        for collection in index.collections {
            remove(collection.list, phone: phone)
        }
        sweepStrayFiles()
    }

    // MARK: - Incoming files

    /// Move a received file into place. Runs on the WatchConnectivity queue,
    /// before the system deletes the temporary file.
    nonisolated static func ingest(fileAt url: URL, metadata: [String: Any]?) -> WatchOfflineTrack? {
        guard let metadata,
              let envelope = try? WatchEnvelope(metadata), envelope.kind == .file,
              let meta = try? envelope.decode(WatchFileMetadata.self) else {
            return nil
        }
        let fm = FileManager.default
        let name = WatchFileNaming.fileName(songID: meta.songID, fileExtension: meta.fileExtension)
        let destination = directory.appendingPathComponent(name)
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.moveItem(at: url, to: destination)
        } catch {
            NSLog("OWENISAS_WATCH: could not store %@: %@", meta.songID, "\(error)")
            return nil
        }
        let size = (try? fm.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? meta.bytes
        return WatchOfflineTrack(
            id: meta.songID,
            title: meta.title,
            artist: meta.artist,
            duration: meta.duration,
            bytes: size,
            fileName: name,
            addedAt: Date()
        )
    }

    func recordArrival(_ track: WatchOfflineTrack) {
        if !index.recordArrival(track) {
            // Removed while it was on its way.
            try? FileManager.default.removeItem(at: fileURL(for: track))
        }
        save()
        refreshFreeSpace()
    }

    func markFailed(_ failure: WatchTransferFailure) {
        index.markFailed(failure.songID)
        save()
    }

    // MARK: - Persistence

    private static func loadIndex() -> WatchOfflineIndex {
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? WatchCoding.decoder().decode(WatchOfflineIndex.self, from: data) else {
            return WatchOfflineIndex()
        }
        // Drop entries whose file vanished.
        var checked = index
        for (id, track) in index.tracks
        where !FileManager.default.fileExists(atPath: directory.appendingPathComponent(track.fileName).path) {
            checked.tracks[id] = nil
        }
        return checked
    }

    private func save() {
        guard !isPreview else { return }
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            let data = try WatchCoding.encoder().encode(index)
            try data.write(to: Self.indexURL, options: .atomic)
        } catch {
            NSLog("OWENISAS_WATCH: could not save offline index: %@", "\(error)")
        }
    }

    /// Delete audio files the index doesn't know (e.g. after a crash
    /// mid-remove). Recent files are skipped: one may have just been moved
    /// in and not yet recorded.
    private func sweepStrayFiles() {
        guard !isPreview else { return }
        let fm = FileManager.default
        let known = Set(index.tracks.values.map(\.fileName)).union(["index.json"])
        let cutoff = Date().addingTimeInterval(-600)
        let files = (try? fm.contentsOfDirectory(
            at: Self.directory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for url in files where !known.contains(url.lastPathComponent) {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified > cutoff { continue }
            try? fm.removeItem(at: url)
        }
    }
}
