import Foundation
import Testing
@testable import Owenisas_Music

// App Group inbox (share extension -> app), owenisas:// URL parsing, and the
// share-text link extraction.

private func makeInbox() -> SharedInbox {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("inbox-tests-\(UUID().uuidString)", isDirectory: true)
    return SharedInbox(directory: dir)
}

private func writeTempFile(named name: String, bytes: Int = 64) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("inbox-src-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try Data(repeating: 7, count: bytes).write(to: url)
    return url
}

struct SharedInboxAudioTests {
    @Test("Shared audio keeps its file name, one folder per file, oldest first")
    func addAndList() throws {
        let inbox = makeInbox()
        defer { try? FileManager.default.removeItem(at: inbox.directory) }
        let first = try writeTempFile(named: "tmp-1.m4a")
        let second = try writeTempFile(named: "Song.mp3")

        let savedFirst = try inbox.addAudio(copying: first, suggestedName: "Artist - Title")
        let savedSecond = try inbox.addAudio(copying: second, suggestedName: nil)

        #expect(savedFirst.lastPathComponent == "Artist - Title.m4a")
        #expect(savedSecond.lastPathComponent == "Song.mp3")
        #expect(savedFirst.deletingLastPathComponent() != savedSecond.deletingLastPathComponent())
        #expect(inbox.pendingAudioFiles().map(\.lastPathComponent) == ["Artist - Title.m4a", "Song.mp3"])
        #expect(FileManager.default.fileExists(atPath: first.path), "the source is copied, not moved")
    }

    @Test("Same name twice does not collide; removing drops the whole folder")
    func duplicatesAndRemove() throws {
        let inbox = makeInbox()
        defer { try? FileManager.default.removeItem(at: inbox.directory) }
        let source = try writeTempFile(named: "Track.m4a")
        let a = try inbox.addAudio(copying: source)
        let b = try inbox.addAudio(copying: source)
        #expect(inbox.pendingAudioFiles().count == 2)

        inbox.removeAudio(a)
        #expect(!FileManager.default.fileExists(atPath: a.deletingLastPathComponent().path))
        let remaining = inbox.pendingAudioFiles()
        #expect(remaining.count == 1)
        #expect(remaining.first?.deletingLastPathComponent().lastPathComponent == b.deletingLastPathComponent().lastPathComponent)
    }

    @Test("Copies still in progress are ignored and abandoned ones are swept")
    func incomingIgnored() throws {
        let inbox = makeInbox()
        defer { try? FileManager.default.removeItem(at: inbox.directory) }
        let staging = inbox.audioDirectory.appendingPathComponent(".incoming-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 10).write(to: staging.appendingPathComponent("half.m4a"))

        #expect(inbox.pendingAudioFiles().isEmpty)
        inbox.sweepAbandonedCopies(olderThan: 60, now: Date())
        #expect(FileManager.default.fileExists(atPath: staging.path), "a fresh copy may still be running")
        inbox.sweepAbandonedCopies(olderThan: 60, now: Date().addingTimeInterval(3600))
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }

    @Test("File names from the share sheet are made safe")
    func fileNames() {
        let source = URL(fileURLWithPath: "/tmp/abc123.m4a")
        #expect(SharedInbox.fileName(for: source, suggestedName: "AC/DC: Live") == "AC-DC- Live.m4a")
        #expect(SharedInbox.fileName(for: source, suggestedName: "Song.M4A") == "Song.m4a")
        #expect(SharedInbox.fileName(for: source, suggestedName: "  ") == "abc123.m4a")
        #expect(SharedInbox.fileName(for: source, suggestedName: "..hidden") == "hidden.m4a")
        #expect(SharedInbox.fileName(for: source, suggestedName: nil) == "abc123.m4a")
    }

    @Test("Nothing shared yet reads as empty")
    func emptyInbox() {
        let inbox = makeInbox()
        #expect(inbox.pendingAudioFiles().isEmpty)
    }
}

#if !APP_STORE
struct SharedInboxLinkTests {
    private let link = "https://www.youtube.com/watch?v=jNQXAC9IVRw"

    @Test("Links queue in order and survive a reload from disk")
    func queueOrder() throws {
        let inbox = makeInbox()
        defer { try? FileManager.default.removeItem(at: inbox.directory) }
        let a = try inbox.enqueue(link: link, choice: nil, now: Date(timeIntervalSince1970: 1))
        let b = try inbox.enqueue(link: "https://youtu.be/dQw4w9WgXcQ?list=PLx", choice: .playlist, now: Date(timeIntervalSince1970: 2))

        let reloaded = SharedInbox(directory: inbox.directory).pendingLinks()
        #expect(reloaded.map(\.id) == [a.id, b.id])
        #expect(reloaded[1].choice == .playlist)
        #expect(reloaded[0].createdAt == Date(timeIntervalSince1970: 1))
    }

    @Test("Sharing the same link twice while queued does not add a copy")
    func dedupe() throws {
        let inbox = makeInbox()
        defer { try? FileManager.default.removeItem(at: inbox.directory) }
        let first = try inbox.enqueue(link: link, choice: .song)
        let again = try inbox.enqueue(link: "  \(link)\n", choice: .song)
        let otherChoice = try inbox.enqueue(link: link, choice: .playlist)
        #expect(first.id == again.id)
        #expect(otherChoice.id != first.id)
        #expect(inbox.pendingLinks().count == 2)
    }

    @Test("Removing by id leaves the others")
    func remove() throws {
        let inbox = makeInbox()
        defer { try? FileManager.default.removeItem(at: inbox.directory) }
        let a = try inbox.enqueue(link: link, choice: nil)
        let b = try inbox.enqueue(link: link + "&t=1", choice: nil)
        inbox.removeLinks(ids: [a.id])
        #expect(inbox.pendingLinks().map(\.id) == [b.id])
    }

    @Test("A corrupt queue file reads as empty and is replaced on the next write")
    func corruptFile() throws {
        let inbox = makeInbox()
        defer { try? FileManager.default.removeItem(at: inbox.directory) }
        try FileManager.default.createDirectory(at: inbox.directory, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: inbox.linksFileURL)
        #expect(inbox.pendingLinks().isEmpty)
        _ = try inbox.enqueue(link: link, choice: nil)
        #expect(inbox.pendingLinks().count == 1)
    }

    @Test("The queue is capped, dropping the oldest")
    func cap() throws {
        let inbox = makeInbox()
        defer { try? FileManager.default.removeItem(at: inbox.directory) }
        for index in 0..<(SharedInbox.maxLinks + 3) {
            _ = try inbox.enqueue(link: link + "&n=\(index)", choice: nil)
        }
        let pending = inbox.pendingLinks()
        #expect(pending.count == SharedInbox.maxLinks)
        #expect(pending.first?.link == link + "&n=3")
    }

    @Test("Concurrent writers (extension + app) lose nothing")
    func concurrentWriters() async throws {
        let inbox = makeInbox()
        defer { try? FileManager.default.removeItem(at: inbox.directory) }
        let base = link
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    _ = try? SharedInbox(directory: inbox.directory).enqueue(link: base + "&n=\(index)", choice: nil)
                }
            }
        }
        #expect(inbox.pendingLinks().count == 20)
    }

    @Test("The file format is versioned JSON with ISO dates")
    func format() throws {
        let request = SharedInbox.LinkRequest(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                                              link: link, choice: .song, createdAt: Date(timeIntervalSince1970: 0))
        let data = try SharedInbox.encodeLinks([request])
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"version\":1"))
        #expect(json.contains("1970-01-01T00:00:00Z"))
        #expect(SharedInbox.decodeLinks(data) == [request])
    }
}

struct DownloadRequestCenterTests {
    @Test("Requests run one at a time, in order; repeated drains add nothing")
    @MainActor
    func ordering() throws {
        let inbox = makeInbox()
        defer { try? FileManager.default.removeItem(at: inbox.directory) }
        let a = try inbox.enqueue(link: "https://youtu.be/jNQXAC9IVRw", choice: nil)
        let b = try inbox.enqueue(link: "https://youtu.be/dQw4w9WgXcQ", choice: .song)
        let center = DownloadRequestCenter(inbox: inbox)

        #expect(center.accept(inbox.pendingLinks()) == 2)
        #expect(center.takeNext()?.id == a.id)
        #expect(center.takeNext() == nil, "one at a time")
        #expect(center.accept(inbox.pendingLinks()) == 0, "the running and queued ones are known")

        center.finish(a.id)
        #expect(inbox.pendingLinks().map(\.id) == [b.id], "a finished request leaves the inbox")
        #expect(center.takeNext()?.id == b.id)
        center.finish(b.id)
        #expect(!center.hasPending)
        #expect(inbox.pendingLinks().isEmpty)
    }

    @Test("An unfinished request is picked up again after a relaunch")
    @MainActor
    func resumeAfterRelaunch() throws {
        let inbox = makeInbox()
        defer { try? FileManager.default.removeItem(at: inbox.directory) }
        let a = try inbox.enqueue(link: "https://youtu.be/jNQXAC9IVRw", choice: nil)
        let before = DownloadRequestCenter(inbox: inbox)
        before.accept(inbox.pendingLinks())
        _ = before.takeNext()   // app killed mid-download

        let after = DownloadRequestCenter(inbox: inbox)
        #expect(after.accept(inbox.pendingLinks()) == 1)
        #expect(after.takeNext()?.id == a.id)
    }
}

struct IncomingShareURLTests {
    private let encoded = "https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3DjNQXAC9IVRw"

    @Test("owenisas://download drains; other routes and schemes are ignored")
    func routes() {
        #expect(IncomingShareURL.action(for: URL(string: "owenisas://download")!) == .drain)
        #expect(IncomingShareURL.action(for: URL(string: "owenisas://import")!) == .drain)
        #expect(IncomingShareURL.action(for: URL(string: "OWENISAS://Download/")!) == .drain)
        #expect(IncomingShareURL.action(for: URL(string: "owenisas:download")!) == .drain)
        #expect(IncomingShareURL.action(for: URL(string: "owenisas://player")!) == .ignore)
        #expect(IncomingShareURL.action(for: URL(string: "https://download")!) == .ignore)
    }

    @Test("A percent-encoded url= parameter becomes a download")
    func encodedLink() {
        let url = URL(string: "owenisas://download?url=\(encoded)")!
        #expect(IncomingShareURL.action(for: url) == .download(link: "https://www.youtube.com/watch?v=jNQXAC9IVRw", choice: nil))
    }

    @Test("An unencoded link keeps its own list= parameter; choice is read")
    func unencodedLinkAndChoice() {
        let url = URL(string: "owenisas://download?url=https://www.youtube.com/watch?v=jNQXAC9IVRw&list=PLabc&choice=playlist")!
        #expect(IncomingShareURL.action(for: url)
                == .download(link: "https://www.youtube.com/watch?v=jNQXAC9IVRw&list=PLabc", choice: .playlist))
        let first = URL(string: "owenisas://download?choice=song&url=\(encoded)")!
        #expect(IncomingShareURL.action(for: first) == .download(link: "https://www.youtube.com/watch?v=jNQXAC9IVRw", choice: .song))
    }

    @Test("An empty or missing url= just drains")
    func emptyLink() {
        #expect(IncomingShareURL.action(for: URL(string: "owenisas://download?url=")!) == .drain)
        #expect(IncomingShareURL.action(for: URL(string: "owenisas://download?foo=bar")!) == .drain)
        #expect(IncomingShareURL.action(for: URL(string: "owenisas://import?url=\(encoded)")!) == .drain)
    }
}

struct ShareTextLinkTests {
    @Test("Finds the link in share-sheet text")
    func findsLink() {
        #expect(YouTubeLinkClassifier.firstLink(in: "https://youtu.be/jNQXAC9IVRw?si=abc") == "https://youtu.be/jNQXAC9IVRw?si=abc")
        #expect(YouTubeLinkClassifier.firstLink(in: "Listen to this! https://music.youtube.com/watch?v=jNQXAC9IVRw&list=OLAK5uy_x.")
                == "https://music.youtube.com/watch?v=jNQXAC9IVRw&list=OLAK5uy_x")
        #expect(YouTubeLinkClassifier.firstLink(in: "(https://www.youtube.com/shorts/jNQXAC9IVRw)") == "https://www.youtube.com/shorts/jNQXAC9IVRw")
        #expect(YouTubeLinkClassifier.firstLink(in: "Me at the zoo\nhttps://www.youtube.com/watch?v=jNQXAC9IVRw") == "https://www.youtube.com/watch?v=jNQXAC9IVRw")
    }

    @Test("No YouTube link means nil")
    func noLink() {
        #expect(YouTubeLinkClassifier.firstLink(in: "https://example.com/watch?v=jNQXAC9IVRw") == nil)
        #expect(YouTubeLinkClassifier.firstLink(in: "youtube is great") == nil)
        #expect(YouTubeLinkClassifier.firstLink(in: "") == nil)
    }

    @Test("Only real playlists offer the song-or-playlist choice")
    func playlistChoice() {
        #expect(YouTubeLinkClassifier.classify("https://www.youtube.com/watch?v=jNQXAC9IVRw&list=PLabc").offersPlaylistChoice)
        #expect(!YouTubeLinkClassifier.classify("https://www.youtube.com/watch?v=jNQXAC9IVRw&list=RDjNQXAC9IVRw").offersPlaylistChoice)
        #expect(!YouTubeLinkClassifier.classify("https://www.youtube.com/watch?v=jNQXAC9IVRw").offersPlaylistChoice)
        #expect(!YouTubeLinkClassifier.classify("https://www.youtube.com/playlist?list=PLabc").offersPlaylistChoice)
    }
}
#endif
