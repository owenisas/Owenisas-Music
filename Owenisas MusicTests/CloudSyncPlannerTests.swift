import Foundation
import Testing
@testable import Owenisas_Music

// MARK: - Upload / download planning (pure)
// Given the local folder set and the container's metadata, what gets
// copied, downloaded, evicted or removed — and what never does.

struct CloudSyncPlannerTests {
    private let t0 = CloudFixtures.t0

    private func local(_ name: String, files: [String] = ["a.mp3", "cover.jpg", "meta.json"],
                       added: Date = CloudFixtures.t0, indexed: Bool = true) -> LocalSongFolder {
        LocalSongFolder(name: name, files: Dictionary(uniqueKeysWithValues: files.map { ($0, Int64(50_000)) }),
                        fileDate: added, addedAt: added, isIndexed: indexed)
    }

    private func remote(_ name: String, files: [String] = ["a.mp3", "cover.jpg", "meta.json"],
                        downloaded: Bool = true, uploaded: Bool = true, uploading: Bool = false,
                        downloading: Bool = false, created: Date? = CloudFixtures.t0,
                        size: Int64 = 50_000) -> RemoteSongFolder {
        var entries: [String: RemoteFileEntry] = [:]
        for file in files {
            entries[file] = RemoteFileEntry(folder: name, name: file, size: size, isDownloaded: downloaded,
                                            isUploaded: uploaded, isUploading: uploading,
                                            isDownloading: downloading, createdAt: created)
        }
        return RemoteSongFolder(name: name, files: entries)
    }

    private func plan(local: [LocalSongFolder] = [], remote: [RemoteSongFolder] = [],
                      tombstones: [String: Date] = [:], mirrored: [String: Date] = [:],
                      pending: [String: Date] = [:], complete: Bool = true) -> MirrorPlan {
        CloudMirrorPlanner.plan(MirrorPlanInput(
            local: Dictionary(uniqueKeysWithValues: local.map { (CloudSyncFiles.folderKey($0.name), $0) }),
            remote: Dictionary(uniqueKeysWithValues: remote.map { (CloudSyncFiles.folderKey($0.name), $0) }),
            tombstones: tombstones, mirrored: mirrored, pendingRemoteDeletes: pending,
            remoteListingComplete: complete
        ))
    }

    @Test("A new indexed local song uploads; an unindexed (in-progress) folder doesn't")
    func uploadsIndexedOnly() {
        let result = plan(local: [local("dQw4w9WgXcQ"), local("half-downloaded", indexed: false)])
        #expect(result.uploadFolders == ["dQw4w9WgXcQ"])
        #expect(result.uploadingCount == 1)
    }

    @Test("A song only in iCloud downloads, then imports once every file is local")
    func downloadThenImport() {
        let pending = plan(remote: [remote("vid1", downloaded: false)])
        #expect(pending.startDownloads["vid1"] == ["a.mp3", "cover.jpg", "meta.json"])
        #expect(pending.importFolders.isEmpty)
        #expect(pending.downloadingCount == 1)

        let inFlight = plan(remote: [remote("vid1", downloaded: false, downloading: true)])
        #expect(inFlight.startDownloads.isEmpty)
        #expect(inFlight.downloadingCount == 1)

        let ready = plan(remote: [remote("vid1")])
        #expect(ready.importFolders == ["vid1"])
        #expect(ready.startDownloads.isEmpty)
    }

    @Test("Container copies are evicted only once uploaded, and only when the song is local")
    func evictionRules() {
        let uploading = plan(local: [local("s")], remote: [remote("s", uploaded: false, uploading: true)])
        #expect(uploading.evictions.isEmpty)
        #expect(uploading.uploadingCount == 1)

        let uploaded = plan(local: [local("s")], remote: [remote("s")], mirrored: ["s": t0])
        #expect(uploaded.evictions["s"] == ["a.mp3", "cover.jpg", "meta.json"])
        #expect(uploaded.uploadingCount == 0)
        #expect(uploaded.markMirrored.isEmpty)

        let alreadyEvicted = plan(local: [local("s")], remote: [remote("s", downloaded: false)])
        #expect(alreadyEvicted.evictions.isEmpty)
        #expect(alreadyEvicted.startDownloads.isEmpty)
        #expect(alreadyEvicted.markMirrored == ["s"])
    }

    @Test("A deleted song isn't downloaded unless its iCloud copy is newer than the delete")
    func tombstonesBlockDownloads() {
        let deleted = plan(remote: [remote("s", created: t0)], tombstones: ["s": CloudFixtures.at(100)])
        #expect(deleted.importFolders.isEmpty)
        #expect(deleted.downloadingCount == 0)

        let unknownDate = plan(remote: [remote("s", created: nil)], tombstones: ["s": CloudFixtures.at(100)])
        #expect(unknownDate.importFolders.isEmpty)

        let reAdded = plan(remote: [remote("s", created: CloudFixtures.at(200))], tombstones: ["s": CloudFixtures.at(100)])
        #expect(reAdded.importFolders == ["s"])
    }

    @Test("A deleted local song is neither uploaded nor refreshed")
    func deadLocalFolderIgnored() {
        let result = plan(local: [local("s", files: ["a.mp3", "new.vtt"])], remote: [remote("s")],
                          tombstones: ["s": CloudFixtures.at(100)])
        #expect(result == MirrorPlan(songsInCloud: 1, bytesInCloud: 150_000))
    }

    @Test("Own deletes remove the iCloud copy only when it's provably older")
    func pendingRemoteDeletes() {
        let deletedAt = CloudFixtures.at(100)
        let older = plan(remote: [remote("s", created: t0)], pending: ["s": deletedAt])
        #expect(older.remoteDeletes == ["s"])

        let newer = plan(remote: [remote("s", created: CloudFixtures.at(500))], pending: ["s": deletedAt])
        #expect(newer.remoteDeletes.isEmpty)
        #expect(newer.dropPendingDeletes == ["s"])

        let unknown = plan(remote: [remote("s", created: nil)], pending: ["s": deletedAt])
        #expect(unknown.remoteDeletes.isEmpty)
        #expect(unknown.dropPendingDeletes.isEmpty)

        let gone = plan(pending: ["s": deletedAt])
        #expect(gone.dropPendingDeletes == ["s"])

        let reAddedHere = plan(local: [local("s", added: CloudFixtures.at(300))], remote: [remote("s")],
                               pending: ["s": deletedAt])
        #expect(reAddedHere.remoteDeletes.isEmpty)
        #expect(reAddedHere.dropPendingDeletes == ["s"])
    }

    @Test("Nothing is uploaded or removed before the iCloud listing is complete")
    func waitsForCompleteListing() {
        let result = plan(local: [local("new"), local("both", files: ["a.mp3", "x.vtt"])],
                          remote: [remote("both", files: ["a.mp3"]), remote("old", created: t0)],
                          pending: ["old": CloudFixtures.at(100)], complete: false)
        #expect(result.uploadFolders.isEmpty)
        #expect(result.uploadFiles.isEmpty)
        #expect(result.remoteDeletes.isEmpty)
        #expect(result.dropPendingDeletes.isEmpty)
        #expect(result.uploadingCount == 2)
    }

    @Test("A mirrored song that disappeared from iCloud isn't re-uploaded; a later re-add is")
    func removedRemotelyNotReuploaded() {
        let seen = CloudFixtures.at(50)
        let removed = plan(local: [local("s", added: t0)], mirrored: ["s": seen])
        #expect(removed.uploadFolders.isEmpty)
        #expect(removed.uploadingCount == 0)

        let reAdded = plan(local: [local("s", added: CloudFixtures.at(60))], mirrored: ["s": seen])
        #expect(reAdded.uploadFolders == ["s"])
    }

    @Test("Files added later (lyrics) flow both ways, audio uploaded last")
    func perFileAdditions() {
        let result = plan(local: [local("s", files: ["s.mp3", "s.en.vtt", "cover.jpg"])],
                          remote: [remote("s", files: ["s.mp3", "s.lyrics.vtt"])])
        #expect(result.uploadFiles == [.init(local: "s", remote: "s", files: ["cover.jpg", "s.en.vtt"])])
        #expect(result.importFiles == [.init(local: "s", remote: "s", files: ["s.lyrics.vtt"])])

        let audioLast = CloudSyncFiles.uploadOrder(["z.m4a", "a.vtt", "meta.json", "cover.jpg"])
        #expect(audioLast == ["a.vtt", "cover.jpg", "meta.json", "z.m4a"])
    }

    @Test("Debug logs, temp, partial and hidden files never sync")
    func excludedFiles() {
        for name in ["download-debug.log", "download-debug.1.log", "song.m4a.part", "x.tmp", ".DS_Store",
                     ".a.mp3.icloud", "a.partial", "b.download", "c.nosync", ".x.cloudtmp"] {
            #expect(!CloudSyncFiles.isSyncable(name), "\(name) should not sync")
        }
        for name in ["a.m4a", "cover.jpg", "meta.json", "x.lyrics.vtt", "Artist - Title.mp3"] {
            #expect(CloudSyncFiles.isSyncable(name), "\(name) should sync")
        }
        #expect(CloudSyncFiles.placeholderTarget(".song.m4a.icloud") == "song.m4a")
        #expect(CloudSyncFiles.placeholderTarget("song.m4a") == nil)
    }

    @Test("A remote folder without audio yet (upload in progress) waits")
    func incompleteRemoteWaits() {
        let result = plan(remote: [remote("s", files: ["meta.json", "cover.jpg"])])
        #expect(result.importFolders.isEmpty)
        #expect(result.startDownloads.isEmpty)
        #expect(result.songsInCloud == 0)
    }

    @Test("Tiny images (purged locally as failed downloads) aren't pulled back")
    func tinyImagesSkipped() {
        let result = plan(local: [local("s", files: ["a.mp3"])],
                          remote: [remote("s", files: ["a.mp3", "cover.jpg"], size: 1_000)])
        #expect(result.importFiles.isEmpty)
    }

    @Test("iCloud song count and size cover songs with audio")
    func cloudTotals() {
        let result = plan(remote: [remote("a"), remote("b", files: ["b.m4a"], size: 10), remote("c", files: ["meta.json"])])
        #expect(result.songsInCloud == 2)
        #expect(result.bytesInCloud == 150_010)
    }

    @Test("Folder identity survives Unicode normalization differences")
    func normalizedFolderKeys() {
        let nfd = "Beyonce\u{0301} - Halo"
        let nfc = "Beyoncé - Halo"
        let result = plan(local: [local(nfc)], remote: [remote(nfd)], mirrored: [CloudSyncFiles.folderKey(nfc): t0])
        #expect(result.uploadFolders.isEmpty)
        #expect(result.importFolders.isEmpty)
        #expect(result.evictions[nfd] != nil)
    }
}
