import Foundation

/// A song folder in local `Documents/Songs`.
struct LocalSongFolder: Equatable {
    /// Name on disk.
    var name: String
    /// Syncable file name → size.
    var files: [String: Int64]
    /// Oldest creation/modification date of the folder and its files.
    var fileDate: Date
    /// When the song was added (SwiftData `dateAdded` when indexed).
    var addedAt: Date
    /// Indexed in the library, i.e. it has validated audio. Unindexed
    /// folders may be downloads in progress and are never uploaded.
    var isIndexed: Bool
}

/// One file of a song folder in the iCloud container, from the metadata
/// query or a directory scan.
struct RemoteFileEntry: Equatable {
    var folder: String
    var name: String
    var size: Int64?
    var isDownloaded: Bool
    var isUploaded: Bool
    var isUploading: Bool
    var isDownloading: Bool
    var createdAt: Date?
}

struct RemoteSongFolder: Equatable {
    var name: String
    var files: [String: RemoteFileEntry]
    /// Creation date of the container folder itself on this device, used
    /// when no file date is known (evicted files are dateless placeholders).
    var folderCreatedAt: Date? = nil

    var createdAt: Date? { files.values.compactMap(\.createdAt).min() ?? folderCreatedAt }
    var hasAudio: Bool { files.keys.contains(where: CloudSyncFiles.isAudio) }
    var totalBytes: Int64 { files.values.reduce(0) { $0 + max(0, $1.size ?? 0) } }
}

struct MirrorPlanInput {
    /// Keyed by `CloudSyncFiles.folderKey`.
    var local: [String: LocalSongFolder]
    var remote: [String: RemoteSongFolder]
    /// Song id (= folder key) → deletion time, already excluding deletes
    /// that a later add superseded.
    var tombstones: [String: Date]
    var mirrored: [String: Date]
    var pendingRemoteDeletes: [String: Date]
    /// False until the metadata query finished its first gather. Until then
    /// nothing is uploaded or removed (the container view may be partial).
    var remoteListingComplete: Bool
}

struct MirrorPlan: Equatable {
    struct FolderFiles: Equatable {
        var local: String
        var remote: String
        var files: [String]
    }

    /// Local folder names to copy into iCloud whole.
    var uploadFolders: [String] = []
    /// Files added locally to a folder iCloud already has.
    var uploadFiles: [FolderFiles] = []
    /// Remote folder names to copy into `Documents/Songs` (fully downloaded).
    var importFolders: [String] = []
    /// Files added remotely to a folder this device already has.
    var importFiles: [FolderFiles] = []
    /// Remote folder name → files to download.
    var startDownloads: [String: [String]] = [:]
    /// Remote folder name → container files to evict (the local copy is
    /// what plays; the container copy only has to exist in iCloud).
    var evictions: [String: [String]] = [:]
    /// Remote folder names to delete from iCloud (this device's user deletes).
    var remoteDeletes: [String] = []
    /// Folder keys whose pending remote delete is done or obsolete.
    var dropPendingDeletes: [String] = []
    /// Folder keys newly confirmed present in iCloud.
    var markMirrored: [String] = []

    var uploadingCount = 0
    var downloadingCount = 0
    var songsInCloud = 0
    var bytesInCloud: Int64 = 0

    var hasFileWork: Bool {
        !uploadFolders.isEmpty || !uploadFiles.isEmpty || !importFolders.isEmpty || !importFiles.isEmpty
            || !startDownloads.isEmpty || !evictions.isEmpty || !remoteDeletes.isEmpty
    }
}

/// Decides what to copy where. Pure: folder listings in, actions out.
/// It only ever adds files; deleting happens solely for this device's own
/// explicit user deletes (remote) and, via the library merge, tombstones.
enum CloudMirrorPlanner {

    static func plan(_ input: MirrorPlanInput) -> MirrorPlan {
        var plan = MirrorPlan()

        for remote in input.remote.values where remote.hasAudio {
            plan.songsInCloud += 1
            plan.bytesInCloud += remote.totalBytes
        }

        // Local → iCloud
        for key in input.local.keys.sorted() {
            guard let local = input.local[key], local.isIndexed else { continue }
            if let deletedAt = input.tombstones[key], deletedAt > local.addedAt { continue }

            guard let remote = input.remote[key] else {
                // Uploaded (or seen) before and gone from iCloud now: someone
                // removed it there. Don't put it back; don't delete it here.
                if let seen = input.mirrored[key], local.addedAt <= seen { continue }
                plan.uploadingCount += 1
                if input.remoteListingComplete { plan.uploadFolders.append(local.name) }
                continue
            }

            if input.mirrored[key] == nil { plan.markMirrored.append(key) }

            let missingRemote = CloudSyncFiles.uploadOrder(
                local.files.keys.filter { CloudSyncFiles.isSyncable($0) && remote.files[$0] == nil }
            )
            if !missingRemote.isEmpty, input.remoteListingComplete {
                plan.uploadFiles.append(.init(local: local.name, remote: remote.name, files: missingRemote))
            }

            let remoteOnly = remote.files.values
                .filter { local.files[$0.name] == nil && CloudSyncFiles.isSyncable($0.name) && !isTinyImage($0) }
                .sorted { $0.name < $1.name }
            let ready = remoteOnly.filter(\.isDownloaded).map(\.name)
            let waiting = remoteOnly.filter { !$0.isDownloaded && !$0.isDownloading }.map(\.name)
            if !ready.isEmpty {
                plan.importFiles.append(.init(local: local.name, remote: remote.name, files: ready))
            }
            if !waiting.isEmpty { plan.startDownloads[remote.name] = waiting }

            let shared = remote.files.values.filter { local.files[$0.name] != nil }
            let evictable = shared
                .filter { $0.isDownloaded && $0.isUploaded && !$0.isUploading }
                .map(\.name)
                .sorted()
            if !evictable.isEmpty { plan.evictions[remote.name] = evictable }

            if !missingRemote.isEmpty || shared.contains(where: { !$0.isUploaded }) { plan.uploadingCount += 1 }
            if !remoteOnly.isEmpty { plan.downloadingCount += 1 }
        }

        // iCloud → local
        for key in input.remote.keys.sorted() where input.local[key] == nil {
            guard let remote = input.remote[key], remote.hasAudio else { continue }
            if let deletedAt = input.tombstones[key] {
                // Deleted, and this copy isn't a newer re-add: leave it.
                guard let created = remote.createdAt, created > deletedAt else { continue }
            }
            let files = remote.files.values.filter { CloudSyncFiles.isSyncable($0.name) && !isTinyImage($0) }
            let pending = files.filter { !$0.isDownloaded }
            plan.downloadingCount += 1
            if pending.isEmpty {
                plan.importFolders.append(remote.name)
            } else {
                let toStart = pending.filter { !$0.isDownloading }.map(\.name).sorted()
                if !toStart.isEmpty { plan.startDownloads[remote.name] = toStart }
            }
        }

        // This device's user deletes → remove the iCloud copy.
        for key in input.pendingRemoteDeletes.keys.sorted() {
            guard let deletedAt = input.pendingRemoteDeletes[key] else { continue }
            if let local = input.local[key], local.addedAt > deletedAt {
                plan.dropPendingDeletes.append(key) // re-added here since
                continue
            }
            guard let remote = input.remote[key] else {
                if input.remoteListingComplete { plan.dropPendingDeletes.append(key) }
                continue
            }
            // Only remove a copy provably older than the delete; unknown
            // dates wait rather than risk removing a newer re-add.
            guard let created = remote.createdAt else { continue }
            if created > deletedAt.addingTimeInterval(1) {
                plan.dropPendingDeletes.append(key)
            } else if input.remoteListingComplete {
                plan.remoteDeletes.append(remote.name)
            }
        }

        return plan
    }

    static func isTinyImage(_ file: RemoteFileEntry) -> Bool {
        guard CloudSyncFiles.isImage(file.name), let size = file.size else { return false }
        return size < CloudSyncConstants.minimumImageBytes
    }
}
