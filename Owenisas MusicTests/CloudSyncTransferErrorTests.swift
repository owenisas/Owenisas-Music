import Foundation
import Testing
@testable import Owenisas_Music

struct CloudSyncTransferErrorTests {
    @Test("iCloud quota failure tells the user how to resume without removing local songs")
    func quotaMessage() {
        let message = CloudSyncFailure.message(for: NSError(domain: NSCocoaErrorDomain, code: NSUbiquitousFileNotUploadedDueToQuotaError))
        #expect(message.contains("iCloud storage is full"))
        #expect(message.contains("local songs"))
    }

    @Test("Device storage exhaustion is not mislabeled as iCloud quota")
    func localStorageMessage() {
        let message = CloudSyncFailure.message(for: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError))
        #expect(message.contains("device storage is full"))
        #expect(!message.contains("iCloud storage is full"))
    }

    @Test("Wrapped quota errors keep the actionable cause")
    func wrappedQuota() {
        let cause = NSError(domain: NSCocoaErrorDomain, code: NSUbiquitousFileNotUploadedDueToQuotaError)
        let wrapper = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [NSUnderlyingErrorKey: cause])
        #expect(CloudSyncFailure.message(for: wrapper) == CloudSyncFailure.message(for: cause))
    }

    @Test("Connectivity and unavailable-service failures have distinct recovery messages")
    func connectivityMessages() {
        #expect(CloudSyncFailure.message(for: URLError(.notConnectedToInternet)).contains("internet connection"))
        #expect(CloudSyncFailure.message(for: URLError(.timedOut)).contains("timed out"))
        #expect(CloudSyncFailure.message(for: NSError(domain: NSCocoaErrorDomain, code: NSUbiquitousFileUbiquityServerNotAvailable)).contains("unavailable"))
    }

    @Test("Unrecognized errors remain visible rather than becoming Uploading")
    func unknownFailure() {
        let error = NSError(domain: "test", code: 7, userInfo: [NSLocalizedDescriptionKey: "Permission denied"])
        #expect(CloudSyncFailure.message(for: error).contains("Permission denied"))
    }

    @Test("A pending remote transfer carries its error through the mirror plan")
    func transferFailurePlan() {
        let message = "iCloud storage is full"
        let local = LocalSongFolder(name: "song", files: ["a.mp3": 50_000], fileDate: .distantPast, addedAt: .distantPast, isIndexed: true)
        let entry = RemoteFileEntry(folder: "song", name: "a.mp3", size: 50_000, isDownloaded: true,
                                    isUploaded: false, isUploading: false, isDownloading: false,
                                    createdAt: nil, transferError: message)
        let remote = RemoteSongFolder(name: "song", files: ["a.mp3": entry])
        let plan = CloudMirrorPlanner.plan(.init(local: ["song": local], remote: ["song": remote],
                                               tombstones: [:], mirrored: [:], pendingRemoteDeletes: [:], remoteListingComplete: true))
        #expect(plan.transferErrors == [message])
        #expect(plan.uploadingCount == 1)
        #expect(plan.remoteDeletes.isEmpty)
        #expect(plan.evictions.isEmpty)
    }

    @Test("A recovered transfer no longer reports its previous error")
    func recoveredTransfer() {
        let entry = RemoteFileEntry(folder: "song", name: "a.mp3", size: 50_000, isDownloaded: true,
                                    isUploaded: true, isUploading: false, isDownloading: false, createdAt: nil)
        let plan = CloudMirrorPlanner.plan(.init(local: [:], remote: ["song": .init(name: "song", files: ["a.mp3": entry])],
                                               tombstones: [:], mirrored: [:], pendingRemoteDeletes: [:], remoteListingComplete: true))
        #expect(plan.transferErrors.isEmpty)
    }

    @Test("Directory refresh does not discard an error supplied by Apple's metadata query")
    func queryErrorSurvivesDirectoryScan() throws {
        let root = CloudFixtures.tempDirectory("transfer-errors")
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = root.appendingPathComponent("Cloud")
        let folder = documents.appendingPathComponent("Songs/song")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 50_000).write(to: folder.appendingPathComponent("a.mp3"))
        let mirror = CloudFileMirror(localSongs: root.appendingPathComponent("Local"), containerDocuments: documents,
                                     stagingDirectory: root.appendingPathComponent("Staging"), holdingDirectory: root.appendingPathComponent("Holding"))
        let entry = RemoteFileEntry(folder: "song", name: "a.mp3", size: 50_000, isDownloaded: true,
                                    isUploaded: false, isUploading: false, isDownloading: false,
                                    createdAt: nil, transferError: "iCloud storage is full")
        #expect(mirror.remoteFolders(queryEntries: [entry])["song"]?.files["a.mp3"]?.transferError == "iCloud storage is full")
    }

    @MainActor
    @Test("Transfer errors take priority over progress in the actual user-facing status")
    func transferFailureStatus() {
        let sync = LibraryCloudSync.shared
        sync.publishStatus(MirrorPlan(uploadingCount: 91, transferErrors: ["iCloud storage is full"]), errors: [])
        #expect(sync.status == .failed("iCloud storage is full"))
        sync.refreshAvailability()
    }
}
