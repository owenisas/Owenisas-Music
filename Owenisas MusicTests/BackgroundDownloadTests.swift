#if !APP_STORE
import Foundation
import Testing
@testable import Owenisas_Music

// Pure pieces of background downloading: BGContinuedProcessingTask
// identifiers, progress units across queued jobs, and the user-facing text.

struct BackgroundDownloadIdentifierTests {
    @Test("Identifiers are unique and fit the Info.plist wildcard")
    func identifiers() {
        let a = BackgroundDownloadIdentifier.make()
        let b = BackgroundDownloadIdentifier.make()
        #expect(a != b, "each identifier may be registered only once per process")
        #expect(BackgroundDownloadIdentifier.matches(a, pattern: BackgroundDownloadIdentifier.permittedPattern))
        #expect(a.hasPrefix("com.Owenisas-Music.download."))
    }

    @Test("Wildcard matching needs the prefix and a non-empty suffix")
    func wildcard() {
        let pattern = "com.Owenisas-Music.download.*"
        #expect(BackgroundDownloadIdentifier.matches("com.Owenisas-Music.download.X1", pattern: pattern))
        #expect(!BackgroundDownloadIdentifier.matches("com.Owenisas-Music.download.", pattern: pattern))
        #expect(!BackgroundDownloadIdentifier.matches("com.Owenisas-Music.export.X1", pattern: pattern))
        #expect(BackgroundDownloadIdentifier.matches("com.example.static", pattern: "com.example.static"))
    }

    @Test("The app's Info.plist permits the identifiers, prefixed with the bundle id")
    func infoPlist() {
        let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
        let identifier = BackgroundDownloadIdentifier.make()
        #expect(permitted.contains { BackgroundDownloadIdentifier.matches(identifier, pattern: $0) }, "\(permitted)")
        if let bundleID = Bundle.main.bundleIdentifier {
            #expect(identifier.hasPrefix(bundleID + "."))
        }
    }
}

struct BackgroundDownloadProgressTests {
    @Test("One job maps its fraction onto 1000 units and never goes backwards")
    func singleJob() {
        var progress = BackgroundDownloadProgress()
        #expect(progress.totalUnits == 1000 && progress.completedUnits == 0)
        progress.update(fraction: 0.5)
        #expect(progress.completedUnits == 500)
        progress.update(fraction: 0.2)
        #expect(progress.completedUnits == 500)
        progress.update(fraction: 7)
        #expect(progress.completedUnits == 1000)
        progress.update(fraction: .nan)
        #expect(progress.completedUnits == 1000)
    }

    @Test("Queued jobs extend the total instead of resetting the bar")
    func queuedJobs() {
        var progress = BackgroundDownloadProgress()
        progress.update(fraction: 1)
        progress.startNextRequest()
        #expect(progress.totalUnits == 2000)
        #expect(progress.completedUnits == 1000)
        progress.update(fraction: 0.25)
        #expect(progress.completedUnits == 1250)
        progress.startNextRequest()
        #expect(progress.totalUnits == 3000 && progress.completedUnits == 2000)
    }
}

struct BackgroundDownloadTextTests {
    @Test("Titles name the playlist, else the song")
    func titles() {
        #expect(BackgroundDownloadText.title(playlistName: "Chill", trackTitle: "Song") == "Downloading \u{201C}Chill\u{201D}")
        #expect(BackgroundDownloadText.title(playlistName: " ", trackTitle: "Song") == "Downloading \u{201C}Song\u{201D}")
        #expect(BackgroundDownloadText.title(playlistName: nil, trackTitle: nil) == "Downloading music")
    }

    @Test("Subtitles count tracks as they complete")
    func subtitles() {
        #expect(BackgroundDownloadText.subtitle(processed: 3, total: 25, failed: 0) == "3 of 25 songs")
        #expect(BackgroundDownloadText.subtitle(processed: 19, total: 25, failed: 2) == "19 of 25 songs, 2 failed")
        #expect(BackgroundDownloadText.subtitle(processed: 30, total: 25, failed: 0) == "25 of 25 songs")
        #expect(BackgroundDownloadText.subtitle(processed: 0, total: 0, failed: 0) == "Getting the song…")
    }

    @Test("Completion notification: Downloaded N songs")
    func completion() {
        #expect(BackgroundDownloadText.completionBody(downloaded: 12, alreadyInLibrary: 0, failed: 0) == "Downloaded 12 songs.")
        #expect(BackgroundDownloadText.completionBody(downloaded: 1, alreadyInLibrary: 0, failed: 0) == "Downloaded 1 song.")
        #expect(BackgroundDownloadText.completionBody(downloaded: 1, alreadyInLibrary: 0, failed: 0, singleTitle: "Me at the zoo")
                == "Downloaded 1 song: \u{201C}Me at the zoo\u{201D}.")
        #expect(BackgroundDownloadText.completionBody(downloaded: 10, alreadyInLibrary: 2, failed: 1)
                == "Downloaded 10 songs, 2 already in your library, 1 failed.")
        #expect(BackgroundDownloadText.completionBody(downloaded: 0, alreadyInLibrary: 3, failed: 0)
                == "All 3 songs were already in your library.")
    }
}
#endif
