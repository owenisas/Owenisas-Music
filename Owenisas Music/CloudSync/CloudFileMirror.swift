import Foundation

/// The two iCloud calls that have no meaning for plain directories, so
/// tests can stand in for the ubiquity daemon.
protocol UbiquityFileOperations {
    func startDownloading(_ url: URL) throws
    func evict(_ url: URL) throws
}

struct SystemUbiquityOperations: UbiquityFileOperations {
    func startDownloading(_ url: URL) throws {
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    func evict(_ url: URL) throws {
        try FileManager.default.evictUbiquitousItem(at: url)
    }
}

/// Everything one pass reads from disk before touching the library.
struct CloudGatherResult {
    /// Other devices' library files that changed since they were last read.
    var libraries: [CloudLibraryFile] = []
    var ownFileExists = false
    var localFolders: [String: LocalSongFolder] = [:]
    var remoteFolders: [String: RemoteSongFolder] = [:]
    var remoteListingComplete = false
}

struct MirrorExecutionResult: Equatable {
    /// Folder keys now in iCloud (uploaded this pass).
    var uploadedFolders: [String] = []
    /// Local folder names created from iCloud this pass.
    var importedFolders: [String] = []
    /// Local folder names that received new files from iCloud.
    var updatedFolders: [String] = []
    /// Folder keys removed from iCloud.
    var removedRemote: [String] = []
    var errors: [String] = []
    /// The folder budget ran out; another pass should follow.
    var moreWork = false
}

/// File work between local `Documents/Songs` and the iCloud container.
/// Container reads and writes go through NSFileCoordinator. Runs on the
/// sync I/O queue except `moveLocalFolderToHolding`, a same-volume rename.
/// (`@unchecked Sendable`: the only mutable state, `libraryReadDates`, is
/// touched solely by `readLibraryFiles` on the serial I/O queue.)
final class CloudFileMirror: @unchecked Sendable {
    let localSongs: URL
    let containerDocuments: URL
    let stagingDirectory: URL
    let holdingDirectory: URL
    let ops: UbiquityFileOperations

    var remoteSongs: URL { containerDocuments.appendingPathComponent(CloudSyncConstants.songsFolderName, isDirectory: true) }
    var libraryDirectory: URL { containerDocuments.appendingPathComponent(CloudSyncConstants.libraryFolderName, isDirectory: true) }

    private let fm = FileManager.default
    /// Library file name → modification date when last read (I/O queue only).
    private var libraryReadDates: [String: Date] = [:]

    init(localSongs: URL, containerDocuments: URL, stagingDirectory: URL, holdingDirectory: URL,
         ops: UbiquityFileOperations = SystemUbiquityOperations()) {
        self.localSongs = localSongs
        self.containerDocuments = containerDocuments
        self.stagingDirectory = stagingDirectory
        self.holdingDirectory = holdingDirectory
        self.ops = ops
    }

    func libraryFileURL(deviceID: String) -> URL {
        libraryDirectory.appendingPathComponent("\(deviceID).json")
    }

    // MARK: - Gather

    func gather(ownDeviceID: String, queryEntries: [RemoteFileEntry], remoteListingComplete: Bool) -> CloudGatherResult {
        var result = CloudGatherResult()
        let libraries = readLibraryFiles(ownDeviceID: ownDeviceID)
        result.libraries = libraries.files
        result.ownFileExists = libraries.ownFileExists
        result.localFolders = scanLocalFolders()
        result.remoteFolders = remoteFolders(queryEntries: queryEntries)
        result.remoteListingComplete = remoteListingComplete
        return result
    }

    func scanLocalFolders() -> [String: LocalSongFolder] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey]
        guard let folders = try? fm.contentsOfDirectory(at: localSongs, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return [:]
        }
        var result: [String: LocalSongFolder] = [:]
        for folder in folders {
            let values = try? folder.resourceValues(forKeys: Set(keys))
            guard values?.isDirectory == true, CloudSyncFiles.isSongFolderName(folder.lastPathComponent) else { continue }
            var files: [String: Int64] = [:]
            var dates = [values?.creationDate, values?.contentModificationDate].compactMap { $0 }
            let contents = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [])) ?? []
            for file in contents where CloudSyncFiles.isSyncable(file.lastPathComponent) {
                guard let fileValues = try? file.resourceValues(forKeys: Set(keys)), fileValues.isRegularFile == true else { continue }
                files[file.lastPathComponent] = Int64(fileValues.fileSize ?? 0)
                dates.append(contentsOf: [fileValues.creationDate, fileValues.contentModificationDate].compactMap { $0 })
            }
            let fileDate = dates.min() ?? Date()
            let key = CloudSyncFiles.folderKey(folder.lastPathComponent)
            result[key] = LocalSongFolder(name: folder.lastPathComponent, files: files, fileDate: fileDate,
                                          addedAt: fileDate, isIndexed: false)
        }
        return result
    }

    /// Container song folders from the metadata query, refreshed by a direct
    /// listing (which also sees `.name.icloud` placeholders).
    func remoteFolders(queryEntries: [RemoteFileEntry]) -> [String: RemoteSongFolder] {
        var folders: [String: RemoteSongFolder] = [:]
        func insert(_ entry: RemoteFileEntry) {
            guard CloudSyncFiles.isSongFolderName(entry.folder), CloudSyncFiles.isSyncable(entry.name) else { return }
            let key = CloudSyncFiles.folderKey(entry.folder)
            var folder = folders[key] ?? RemoteSongFolder(name: entry.folder, files: [:])
            var merged = entry
            if let known = folder.files[entry.name] {
                // A placeholder carries no creation date; keep the query's.
                merged.createdAt = entry.createdAt ?? known.createdAt
                merged.size = entry.size ?? known.size
            }
            folder.files[entry.name] = merged
            folders[key] = folder
        }
        queryEntries.forEach(insert)
        let scan = scanRemoteDirectory()
        scan.entries.forEach(insert)
        for (key, date) in scan.folderDates {
            folders[key]?.folderCreatedAt = date
        }
        return folders
    }

    func scanRemoteDirectory() -> (entries: [RemoteFileEntry], folderDates: [String: Date]) {
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isRegularFileKey, .fileSizeKey, .creationDateKey, .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey,
            .ubiquitousItemIsDownloadingKey,
        ]
        let folderKeys: Set<URLResourceKey> = [.isDirectoryKey, .creationDateKey]
        guard let folders = try? fm.contentsOfDirectory(at: remoteSongs, includingPropertiesForKeys: Array(folderKeys), options: []) else {
            return ([], [:])
        }
        var entries: [RemoteFileEntry] = []
        var folderDates: [String: Date] = [:]
        for folder in folders where CloudSyncFiles.isSongFolderName(folder.lastPathComponent) {
            guard let folderValues = try? folder.resourceValues(forKeys: folderKeys), folderValues.isDirectory == true else { continue }
            if let created = folderValues.creationDate {
                folderDates[CloudSyncFiles.folderKey(folder.lastPathComponent)] = created
            }
            let contents = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [])) ?? []
            for file in contents {
                let name = file.lastPathComponent
                if let target = CloudSyncFiles.placeholderTarget(name) {
                    entries.append(RemoteFileEntry(
                        folder: folder.lastPathComponent, name: target, size: Self.placeholderSize(file),
                        isDownloaded: false, isUploaded: true, isUploading: false, isDownloading: false,
                        createdAt: nil
                    ))
                    continue
                }
                guard CloudSyncFiles.isSyncable(name), let entry = Self.entry(for: file, folder: folder.lastPathComponent, keys: keys) else { continue }
                entries.append(entry)
            }
        }
        return (entries, folderDates)
    }

    private static func entry(for file: URL, folder: String, keys: [URLResourceKey]) -> RemoteFileEntry? {
        guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return nil }
        let ubiquitous = values.isUbiquitousItem == true
        let downloaded: Bool
        if ubiquitous, let status = values.ubiquitousItemDownloadingStatus {
            downloaded = status == .current || status == .downloaded
        } else {
            downloaded = true
        }
        return RemoteFileEntry(
            folder: folder,
            name: file.lastPathComponent,
            size: values.fileSize.map { Int64($0) },
            isDownloaded: downloaded,
            isUploaded: ubiquitous ? (values.ubiquitousItemIsUploaded ?? false) : true,
            isUploading: ubiquitous ? (values.ubiquitousItemIsUploading ?? false) : false,
            isDownloading: ubiquitous ? (values.ubiquitousItemIsDownloading ?? false) : false,
            createdAt: values.creationDate
        )
    }

    /// Legacy placeholders are small plists that carry the real file size.
    private static func placeholderSize(_ url: URL) -> Int64? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let size = plist["NSURLFileSizeKey"] as? NSNumber else { return nil }
        return size.int64Value
    }

    /// Converts metadata-query results to entries for song files.
    static func entries(fromQueryResults items: [NSMetadataItem], documentsPath: String) -> [RemoteFileEntry] {
        let root = canonicalPath(documentsPath)
        return items.compactMap { item -> RemoteFileEntry? in
            guard let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL else { return nil }
            let path = canonicalPath(url.path)
            guard path.hasPrefix(root + "/") else { return nil }
            let parts = path.dropFirst(root.count + 1).split(separator: "/").map(String.init)
            guard parts.count == 3, parts[0] == CloudSyncConstants.songsFolderName else { return nil }
            let name = CloudSyncFiles.placeholderTarget(parts[2]) ?? parts[2]
            let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
            let downloaded = status == NSMetadataUbiquitousItemDownloadingStatusCurrent
                || status == NSMetadataUbiquitousItemDownloadingStatusDownloaded
            func flag(_ key: String) -> Bool { (item.value(forAttribute: key) as? NSNumber)?.boolValue ?? false }
            return RemoteFileEntry(
                folder: parts[1],
                name: name,
                size: (item.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.int64Value,
                isDownloaded: downloaded,
                isUploaded: flag(NSMetadataUbiquitousItemIsUploadedKey),
                isUploading: flag(NSMetadataUbiquitousItemIsUploadingKey),
                isDownloading: flag(NSMetadataUbiquitousItemIsDownloadingKey),
                createdAt: item.value(forAttribute: NSMetadataItemFSCreationDateKey) as? Date
            )
        }
    }

    /// `/private/var/...` and `/var/...` name the same place on iOS.
    static func canonicalPath(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        return standardized.hasPrefix("/private/") ? String(standardized.dropFirst("/private".count)) : standardized
    }

    // MARK: - Library files

    struct LibraryReadResult {
        var files: [CloudLibraryFile] = []
        var ownFileExists = false
    }

    /// Reads other devices' files that changed since the last read. Files
    /// not on this device yet are asked to download and read next time.
    func readLibraryFiles(ownDeviceID: String) -> LibraryReadResult {
        var result = LibraryReadResult()
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        guard let entries = try? fm.contentsOfDirectory(at: libraryDirectory, includingPropertiesForKeys: keys, options: []) else {
            return result
        }
        for url in entries {
            let name = url.lastPathComponent
            if let target = CloudSyncFiles.placeholderTarget(name) {
                guard target.hasSuffix(".json") else { continue }
                if target == "\(ownDeviceID).json" {
                    result.ownFileExists = true
                } else {
                    try? ops.startDownloading(libraryDirectory.appendingPathComponent(target))
                }
                continue
            }
            guard name.hasSuffix(".json"), !name.hasPrefix(".") else { continue }
            let deviceID = String(name.dropLast(".json".count))
            if deviceID == ownDeviceID {
                result.ownFileExists = true
                continue
            }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            if values?.isUbiquitousItem == true, let status = values?.ubiquitousItemDownloadingStatus, status != .current {
                try? ops.startDownloading(url)
                if status == .notDownloaded { continue }
            }
            let modified = values?.contentModificationDate
            if let modified, libraryReadDates[name] == modified { continue }
            guard let data = coordinatedRead(url),
                  let file = try? CloudSyncCoding.decoder().decode(CloudLibraryFile.self, from: data),
                  file.deviceID == deviceID else { continue }
            if let modified { libraryReadDates[name] = modified }
            result.files.append(file)
        }
        return result
    }

    func writeOwnLibraryFile(_ data: Data, deviceID: String) throws {
        try fm.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
        let url = libraryFileURL(deviceID: deviceID)
        try coordinatedWrite(url, options: .forReplacing) { target in
            try data.write(to: target, options: .atomic)
        }
        // Only this device writes this file; its version always wins.
        if let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url), !conflicts.isEmpty {
            for version in conflicts { version.isResolved = true }
            try? NSFileVersion.removeOtherVersionsOfItem(at: url)
        }
    }

    // MARK: - Execute a plan

    func execute(_ plan: MirrorPlan, folderBudget: Int = CloudSyncConstants.folderOperationsPerPass) -> MirrorExecutionResult {
        var result = MirrorExecutionResult()
        var budget = folderBudget

        for name in plan.remoteDeletes {
            do {
                try removeRemoteFolder(name)
                result.removedRemote.append(CloudSyncFiles.folderKey(name))
            } catch {
                result.errors.append("Remove \(name) from iCloud: \(error.localizedDescription)")
            }
        }

        for name in plan.importFolders {
            guard budget > 0 else { result.moreWork = true; break }
            budget -= 1
            do {
                let outcome = try importFolder(name)
                switch outcome {
                case .created(let localName): result.importedFolders.append(localName)
                case .merged(let localName): result.updatedFolders.append(localName)
                case .unchanged: break
                }
                evict(folder: name, files: nil)
            } catch {
                result.errors.append("Download \(name): \(error.localizedDescription)")
            }
        }

        for transfer in plan.importFiles {
            do {
                if try importFiles(transfer) > 0 { result.updatedFolders.append(transfer.local) }
                evict(folder: transfer.remote, files: transfer.files)
            } catch {
                result.errors.append("Download files for \(transfer.local): \(error.localizedDescription)")
            }
        }

        for name in plan.uploadFolders {
            guard budget > 0 else { result.moreWork = true; break }
            budget -= 1
            do {
                try uploadFolder(name)
                result.uploadedFolders.append(CloudSyncFiles.folderKey(name))
            } catch {
                result.errors.append("Upload \(name): \(error.localizedDescription)")
            }
        }

        for transfer in plan.uploadFiles {
            do {
                try upload(files: transfer.files, from: transfer.local, to: transfer.remote)
            } catch {
                result.errors.append("Upload files for \(transfer.local): \(error.localizedDescription)")
            }
        }

        for folder in plan.startDownloads.keys.sorted() {
            for file in plan.startDownloads[folder] ?? [] {
                let url = remoteSongs.appendingPathComponent(folder, isDirectory: true).appendingPathComponent(file)
                do {
                    try ops.startDownloading(url)
                } catch {
                    result.errors.append("Start download \(folder)/\(file): \(error.localizedDescription)")
                }
            }
        }

        for folder in plan.evictions.keys.sorted() {
            evict(folder: folder, files: plan.evictions[folder])
        }

        return result
    }

    // MARK: Upload

    func uploadFolder(_ localName: String) throws {
        try upload(files: nil, from: localName, to: localName)
    }

    /// Copies files into the container folder, never overwriting what is
    /// already there (a remote file wins; it may be newer). Audio last.
    func upload(files: [String]?, from localName: String, to remoteName: String) throws {
        let source = localSongs.appendingPathComponent(localName, isDirectory: true)
        let names = try files ?? syncableFiles(in: source)
        guard !names.isEmpty else { return }
        try fm.createDirectory(at: remoteSongs, withIntermediateDirectories: true)
        let destination = remoteSongs.appendingPathComponent(remoteName, isDirectory: true)
        try coordinatedWrite(destination, options: []) { target in
            try self.fm.createDirectory(at: target, withIntermediateDirectories: true)
            for name in CloudSyncFiles.uploadOrder(names) {
                let from = source.appendingPathComponent(name)
                let to = target.appendingPathComponent(name)
                let placeholder = target.appendingPathComponent(".\(name).icloud")
                guard self.fm.fileExists(atPath: from.path),
                      !self.fm.fileExists(atPath: to.path),
                      !self.fm.fileExists(atPath: placeholder.path) else { continue }
                try self.fm.copyItem(at: from, to: to)
            }
        }
    }

    // MARK: Import

    enum ImportOutcome: Equatable {
        case created(String)
        case merged(String)
        case unchanged
    }

    /// Copies a fully downloaded container folder into `Documents/Songs`.
    /// It is staged first and moved in with one rename, so the library never
    /// sees half a song. An existing local folder only gains missing files.
    func importFolder(_ remoteName: String) throws -> ImportOutcome {
        let source = remoteSongs.appendingPathComponent(remoteName, isDirectory: true)
        let localName = CloudSyncFiles.folderKey(remoteName)
        let stageRoot = stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stage = stageRoot.appendingPathComponent(localName, isDirectory: true)
        defer { try? fm.removeItem(at: stageRoot) }

        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        try coordinatedRead(source) { readable in
            for name in try self.syncableFiles(in: readable) {
                try self.fm.copyItem(at: readable.appendingPathComponent(name), to: stage.appendingPathComponent(name))
            }
        }
        let staged = try syncableFiles(in: stage)
        guard staged.contains(where: CloudSyncFiles.isAudio) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "No audio in the iCloud copy yet"])
        }

        try fm.createDirectory(at: localSongs, withIntermediateDirectories: true)
        let destination = localSongs.appendingPathComponent(localName, isDirectory: true)
        if !fm.fileExists(atPath: destination.path) {
            try fm.moveItem(at: stage, to: destination)
            return .created(localName)
        }
        var added = 0
        for name in staged where !fm.fileExists(atPath: destination.appendingPathComponent(name).path) {
            try placeFile(from: stage.appendingPathComponent(name), into: destination, named: name)
            added += 1
        }
        return added > 0 ? .merged(localName) : .unchanged
    }

    /// Adds files another device added to a folder this device already has.
    @discardableResult
    func importFiles(_ transfer: MirrorPlan.FolderFiles) throws -> Int {
        let source = remoteSongs.appendingPathComponent(transfer.remote, isDirectory: true)
        let destination = localSongs.appendingPathComponent(transfer.local, isDirectory: true)
        guard fm.fileExists(atPath: destination.path) else { return 0 }
        var added = 0
        for name in transfer.files where CloudSyncFiles.isSyncable(name) {
            guard !fm.fileExists(atPath: destination.appendingPathComponent(name).path) else { continue }
            let temp = destination.appendingPathComponent(".\(name).cloudtmp")
            try? fm.removeItem(at: temp)
            try coordinatedRead(source.appendingPathComponent(name)) { readable in
                try self.fm.copyItem(at: readable, to: temp)
            }
            do {
                try fm.moveItem(at: temp, to: destination.appendingPathComponent(name))
                added += 1
            } catch {
                try? fm.removeItem(at: temp)
                if !fm.fileExists(atPath: destination.appendingPathComponent(name).path) { throw error }
            }
        }
        return added
    }

    /// Moves a staged file in under a hidden temp name, then renames it,
    /// so a reader never sees a partial file.
    private func placeFile(from source: URL, into folder: URL, named name: String) throws {
        let temp = folder.appendingPathComponent(".\(name).cloudtmp")
        try? fm.removeItem(at: temp)
        try fm.moveItem(at: source, to: temp)
        do {
            try fm.moveItem(at: temp, to: folder.appendingPathComponent(name))
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    // MARK: Evict / delete

    /// Frees the container copy's local storage; iCloud keeps the file.
    func evict(folder remoteName: String, files: [String]?) {
        let folder = remoteSongs.appendingPathComponent(remoteName, isDirectory: true)
        let names = files ?? ((try? syncableFiles(in: folder)) ?? [])
        for name in names {
            try? ops.evict(folder.appendingPathComponent(name))
        }
    }

    /// Removes a song folder from iCloud. Only called for this device's own
    /// explicit user deletes.
    func removeRemoteFolder(_ remoteName: String) throws {
        let folder = remoteSongs.appendingPathComponent(remoteName, isDirectory: true)
        guard fm.fileExists(atPath: folder.path) else { return }
        try coordinatedWrite(folder, options: .forDeleting) { target in
            try self.fm.removeItem(at: target)
        }
    }

    /// A song deleted on another device is moved aside, not deleted, and
    /// purged after the holding period. Returns false if it couldn't move.
    func moveLocalFolderToHolding(_ folderName: String, now: Date = Date()) -> Bool {
        let source = localSongs.appendingPathComponent(folderName, isDirectory: true)
        guard fm.fileExists(atPath: source.path) else { return true }
        do {
            try fm.createDirectory(at: holdingDirectory, withIntermediateDirectories: true)
            let stamp = Int(now.timeIntervalSince1970)
            var destination = holdingDirectory.appendingPathComponent("\(stamp)--\(folderName)", isDirectory: true)
            if fm.fileExists(atPath: destination.path) {
                destination = holdingDirectory.appendingPathComponent("\(stamp)-\(UUID().uuidString.prefix(8))--\(folderName)", isDirectory: true)
            }
            try fm.moveItem(at: source, to: destination)
            return true
        } catch {
            print("[DEBUG] CloudSync: couldn't set aside \(folderName): \(error.localizedDescription)")
            return false
        }
    }

    func purgeHolding(now: Date = Date()) {
        guard let entries = try? fm.contentsOfDirectory(at: holdingDirectory, includingPropertiesForKeys: nil, options: []) else { return }
        for entry in entries {
            let name = entry.lastPathComponent
            guard let stampText = name.split(separator: "-", maxSplits: 1).first,
                  let stamp = TimeInterval(stampText) else { continue }
            if now.timeIntervalSince1970 - stamp > CloudSyncConstants.holdingPeriod {
                try? fm.removeItem(at: entry)
            }
        }
    }

    // MARK: - Helpers

    private func syncableFiles(in folder: URL) throws -> [String] {
        try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [])
            .filter { CloudSyncFiles.isSyncable($0.lastPathComponent) }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
            .map(\.lastPathComponent)
            .sorted()
    }

    private func coordinatedRead(_ url: URL) -> Data? {
        var data: Data?
        try? coordinatedRead(url) { readable in
            data = try Data(contentsOf: readable)
        }
        return data
    }

    private func coordinatedRead(_ url: URL, _ body: (URL) throws -> Void) throws {
        var coordinationError: NSError?
        var bodyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
            do { try body(readable) } catch { bodyError = error }
        }
        if let error = coordinationError ?? bodyError { throw error }
    }

    private func coordinatedWrite(_ url: URL, options: NSFileCoordinator.WritingOptions, _ body: (URL) throws -> Void) throws {
        var coordinationError: NSError?
        var bodyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: options, error: &coordinationError) { writable in
            do { try body(writable) } catch { bodyError = error }
        }
        if let error = coordinationError ?? bodyError { throw error }
    }
}
