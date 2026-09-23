// App Group hand-off from the share extension (writer) to the app (reader).
// Compiled into the app, the share extension and the widget: Foundation only.
//
// Layout under the group container:
//   Inbox/links.json                          queued link requests (personal builds)
//   Inbox/Audio/<uuid>/<original file name>   shared audio files, one per folder
//   Inbox/Audio/.incoming-<uuid>/             a copy still in progress (ignored)
//
// links.json is only changed inside an NSFileCoordinator write block
// (read-modify-write, then an atomic replace), so the extension and the app
// can append/remove at the same time without losing entries. Audio folders
// appear with a single directory rename once the copy is complete.

import Foundation

struct SharedInbox {
    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    /// The real inbox in the App Group container (nil if the group is missing).
    static var shared: SharedInbox? {
        AppGroup.containerURL.map { SharedInbox(directory: $0.appendingPathComponent("Inbox", isDirectory: true)) }
    }

    var audioDirectory: URL { directory.appendingPathComponent("Audio", isDirectory: true) }

    private static let incomingPrefix = ".incoming-"

    // MARK: - Audio files

    /// Copies `source` into its own inbox folder, keeping the original file
    /// name (the app names the song folder after it). `suggestedName` (from
    /// the share sheet) wins over a temporary file name.
    @discardableResult
    func addAudio(copying source: URL, suggestedName: String? = nil) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let staging = audioDirectory.appendingPathComponent(Self.incomingPrefix + id, isDirectory: true)
        let final = audioDirectory.appendingPathComponent(id, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let name = Self.fileName(for: source, suggestedName: suggestedName)
        do {
            try fm.copyItem(at: source, to: staging.appendingPathComponent(name))
            try fm.moveItem(at: staging, to: final)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        return final.appendingPathComponent(name)
    }

    /// Complete shared audio files, oldest first.
    func pendingAudioFiles() -> [URL] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.creationDateKey, .isDirectoryKey]
        guard let folders = try? fm.contentsOfDirectory(at: audioDirectory, includingPropertiesForKeys: keys) else { return [] }
        let dated: [(URL, Date)] = folders.compactMap { folder in
            let name = folder.lastPathComponent
            guard !name.hasPrefix("."),
                  (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let file = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
                      .first(where: { !$0.lastPathComponent.hasPrefix(".") }) else { return nil }
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            return (file, created)
        }
        return dated.sorted { $0.1 < $1.1 }.map(\.0)
    }

    /// Removes a file returned by `pendingAudioFiles()` together with its folder.
    func removeAudio(_ file: URL) {
        let folder = file.deletingLastPathComponent()
        guard folder.deletingLastPathComponent().standardizedFileURL.path == audioDirectory.standardizedFileURL.path else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// Copies abandoned by a killed extension, older than `age`.
    func sweepAbandonedCopies(olderThan age: TimeInterval = 3600, now: Date = Date()) {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: audioDirectory, includingPropertiesForKeys: [.creationDateKey],
                                                        options: []) else { return }
        for folder in folders where folder.lastPathComponent.hasPrefix(Self.incomingPrefix) {
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if now.timeIntervalSince(created) > age { try? fm.removeItem(at: folder) }
        }
    }

    static func fileName(for source: URL, suggestedName: String?) -> String {
        let ext = source.pathExtension
        var base = (suggestedName ?? "")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !ext.isEmpty, base.lowercased().hasSuffix("." + ext.lowercased()) {
            base = String(base.dropLast(ext.count + 1))
        }
        if base.hasPrefix(".") { base = String(base.drop(while: { $0 == "." })) }
        if base.count > 120 { base = String(base.prefix(120)) }
        guard !base.isEmpty else { return source.lastPathComponent }
        return ext.isEmpty ? base : base + "." + ext
    }

    #if !APP_STORE
    // MARK: - Link requests (personal builds)

    struct LinkRequest: Codable, Equatable, Identifiable {
        enum Choice: String, Codable {
            /// Just the shared song, even if the link names a playlist.
            case song
            /// The whole playlist the song was shared from.
            case playlist
        }

        let id: UUID
        let link: String
        let choice: Choice?
        let createdAt: Date
    }

    private struct LinkFile: Codable {
        var version = 1
        var requests: [LinkRequest]
    }

    static let maxLinks = 50

    var linksFileURL: URL { directory.appendingPathComponent("links.json") }

    /// Appends a request. Sharing the same link (and choice) again while it
    /// is still queued returns the queued request instead of adding a copy.
    @discardableResult
    func enqueue(link: String, choice: LinkRequest.Choice?, now: Date = Date()) throws -> LinkRequest {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        var result: LinkRequest?
        try mutateLinks { requests in
            if let existing = requests.first(where: { $0.link == trimmed && $0.choice == choice }) {
                result = existing
                return
            }
            let request = LinkRequest(id: UUID(), link: trimmed, choice: choice, createdAt: now)
            requests.append(request)
            if requests.count > Self.maxLinks {
                requests.removeFirst(requests.count - Self.maxLinks)
            }
            result = request
        }
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        return result
    }

    /// Queued requests, oldest first.
    func pendingLinks() -> [LinkRequest] {
        guard FileManager.default.fileExists(atPath: linksFileURL.path) else { return [] }
        var requests: [LinkRequest] = []
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: linksFileURL, options: [], error: &coordinationError) { url in
            requests = Self.decodeLinks(try? Data(contentsOf: url))
        }
        return requests
    }

    func removeLinks(ids: Set<UUID>) {
        guard !ids.isEmpty, FileManager.default.fileExists(atPath: linksFileURL.path) else { return }
        try? mutateLinks { requests in
            requests.removeAll { ids.contains($0.id) }
        }
    }

    static func decodeLinks(_ data: Data?) -> [LinkRequest] {
        guard let data, !data.isEmpty else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(LinkFile.self, from: data))?.requests ?? []
    }

    static func encodeLinks(_ requests: [LinkRequest]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(LinkFile(requests: requests))
    }

    /// Coordinated read-modify-write with an atomic replace. A corrupt file
    /// reads as empty and is overwritten.
    private func mutateLinks(_ change: (inout [LinkRequest]) -> Void) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: linksFileURL, options: .forMerging,
                                                         error: &coordinationError) { url in
            var requests = Self.decodeLinks(try? Data(contentsOf: url))
            change(&requests)
            do {
                try Self.encodeLinks(requests).write(to: url, options: .atomic)
            } catch {
                writeError = error
            }
        }
        if let error = coordinationError ?? writeError { throw error }
    }
    #endif
}
