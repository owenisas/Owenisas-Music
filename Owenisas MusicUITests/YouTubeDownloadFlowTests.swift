import XCTest
@testable import Owenisas_Music

/// Direct verification of the YouTube download flow in the iOS app.
/// Types a known-good URL, taps Download, waits for the track to land in the
/// library (track count goes up by 1) or for an error alert. Reports the
/// on-screen status text either way so failures are diagnosable.
final class YouTubeDownloadFlowTests: XCTestCase {

    private let testURL = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

    override func setUpWithError() throws {
        // Real network download — opt in with TEST_RUNNER_OWENISAS_LIVE_TESTS=1.
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OWENISAS_LIVE_TESTS"] == "1",
                          "Live YouTube download; set TEST_RUNNER_OWENISAS_LIVE_TESTS=1 to run")
        continueAfterFailure = false
    }

    func testDownloadSingleTrack_TappableFlow_AddsToLibrary() throws {
        let app = XCUIApplication()
        app.launchArguments.append("UI_TEST_RESET_LIBRARY")
        app.launch()

        // Step 1: go to Download tab
        let downloadTab = app.tabBars.buttons["Download"]
        XCTAssertTrue(downloadTab.waitForExistence(timeout: 8),
                      "Download tab should be visible in tab bar")
        downloadTab.tap()

        // Step 2: type the URL into the field
        let field = app.textFields["downloadUrlField"]
        XCTAssertTrue(field.waitForExistence(timeout: 8),
                      "Download URL field should appear after tapping Download tab")
        field.tap()
        field.typeText(testURL)

        // Step 3: read initial library track count for delta check
        let initialCount = libraryTrackCount(app: app)
        print("[TEST] initial library track count: \(initialCount)")

        // Step 4: tap Download
        let button = app.buttons["downloadButton"]
        XCTAssertTrue(button.exists, "Download button should exist")
        button.tap()

        // Step 5: wait for the alert (error) or for the track count to go up
        let alert = app.alerts.firstMatch
        let downloadTimeout: TimeInterval = 300
        let pollInterval: TimeInterval = 2
        let deadline = Date().addingTimeInterval(downloadTimeout)
        var lastStatusText = ""
        var sawError = false
        var alertTitle = ""
        var alertMessage = ""
        while Date() < deadline {
            if alert.exists {
                sawError = true
                alertTitle = alert.label
                alertMessage = alert.staticTexts.allElementsBoundByIndex.map { $0.label }.joined(separator: " | ")
                let buttons = alert.buttons.allElementsBoundByIndex.map { $0.label }
                print("[TEST] ALERT title=\(alertTitle)")
                print("[TEST] ALERT messages=\(alertMessage)")
                print("[TEST] ALERT buttons=\(buttons)")
                if let dismissButton = alert.buttons.firstMatch as XCUIElement? {
                    dismissButton.tap()
                }
                break
            }
            let status = app.staticTexts["downloadStatus"]
            if status.exists { lastStatusText = status.label }
            // Check library count
            app.tabBars.buttons["Library"].tap()
            let currentCount = libraryTrackCount(app: app)
            app.tabBars.buttons["Download"].tap()
            if currentCount > initialCount {
                print("[TEST] SUCCESS: library went \(initialCount) -> \(currentCount)")
                print("[TEST] last status: \(lastStatusText)")
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
        }
        XCTFail("""
        Download did not complete in \(Int(downloadTimeout))s.
        sawError=\(sawError)
        alertTitle=\(alertTitle)
        alertMessage=\(alertMessage)
        lastStatus=\(lastStatusText)
        testURL=\(testURL)
        iOS app debug log (Documents/download-debug.log):
        \(appDebugLog)
        """)
    }

    private func libraryTrackCount(app: XCUIApplication) -> Int {
        // The Library tab shows song rows via the SwiftUI List — count them
        // by collection view cells. If the library is empty, the empty-state
        // text "Your library is empty" is shown.
        let emptyText = app.staticTexts["Your library is empty"]
        if emptyText.waitForExistence(timeout: 1) {
            return 0
        }
        // Count by accessibility label matching the song row template
        // (set in the SongRow SwiftUI view).
        let rows = app.collectionViews.cells
        return rows.count
    }

    /// Read the iOS app's debug log file from its sandbox Documents dir.
    /// The XCUITest runner has a different sandbox than the host app, so we
    /// just list every app container looking for the log file.
    private var appDebugLog: String {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        // In simulator, the host's CoreSimulator path is the same as the
        // simulator's view; the app sandbox is mounted under the
        // simulator's data dir.
        let candidates = [
            "\(home)/Library/Developer/CoreSimulator/Devices",
            "/Users/user/Library/Developer/CoreSimulator/Devices"
        ].filter { fm.fileExists(atPath: $0) }
        for base in candidates {
            do {
                let devices = try fm.contentsOfDirectory(atPath: base)
                for dev in devices {
                    let appBase = "\(base)/\(dev)/data/Containers/Data/Application"
                    if let appDirs = try? fm.contentsOfDirectory(atPath: appBase) {
                        for d in appDirs {
                            let logURL = URL(fileURLWithPath: "\(appBase)/\(d)/Documents/download-debug.log")
                            if let data = try? Data(contentsOf: logURL),
                               let text = String(data: data, encoding: .utf8), !text.isEmpty {
                                return "from \(d):\n" + text.components(separatedBy: "\n").suffix(60).joined(separator: "\n")
                            }
                        }
                    }
                }
            } catch {
                continue
            }
        }
        return "(no debug log found in any simulator container)"
    }
}
