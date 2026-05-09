import XCTest

// MARK: - Playback Flow UI Tests
// Structural smoke tests to verify the app launches, all tabs render,
// and the core views are reachable. Exercises the patched code paths
// where download / library / queue views are constructed.

final class PlaybackFlowTests: XCTestCase {

    var app: XCUIApplication!

    private let singleTrackSmokeLinks = [
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        "https://www.youtube.com/watch?v=kJQP7kiw5Fk",
        "https://www.youtube.com/watch?v=fJ9rUzIMcZQ"
    ]
    private let playlistSmokeLink = "https://www.youtube.com/playlist?list=PLwZcI0zn-JheRhv7jIV5Dl6IJQTuHR5e-"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments.append("UI_TEST_RESET_LIBRARY")
        app.launch()
    }

    // MARK: - Tab Navigation

    @MainActor
    func testHomeTabIsVisibleOnLaunch() {
        let homeTab = app.tabBars.buttons["Home"]
        XCTAssertTrue(homeTab.exists, "Home tab should be visible")
        XCTAssertTrue(homeTab.isSelected, "Home tab should be selected on launch")
    }

    @MainActor
    func testLibraryTabShowsSongsLibrary() {
        app.tabBars.buttons["Library"].tap()

        // SongsLibraryView should render; look for common structural elements
        let navBar = app.navigationBars.firstMatch
        XCTAssertTrue(navBar.waitForExistence(timeout: 3), "Library nav bar should appear")
    }

    @MainActor
    func testDownloadTabShowsDownloadView() {
        app.tabBars.buttons["Download"].tap()

        // DownloadView has a TextField for the YouTube link
        let textField = app.textFields.firstMatch
        XCTAssertTrue(textField.waitForExistence(timeout: 3), "Download URL text field should appear")
    }

    @MainActor
    func testAllTabsReachable() {
        // Cycle through all tabs to verify none crash
        let tabs = ["Home", "Library", "Download"]
        for tab in tabs {
            let button = app.tabBars.buttons[tab]
            XCTAssertTrue(button.exists, "\(tab) tab should exist")
            button.tap()
            // Give the view a moment to render
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
    }

    // MARK: - Download View Interaction

    @MainActor
    func testDownloadFieldAcceptsInput() {
        app.tabBars.buttons["Download"].tap()

        let field = app.textFields.firstMatch
        guard field.waitForExistence(timeout: 3) else {
            XCTFail("Text field not found")
            return
        }

        field.tap()
        field.typeText("https://www.youtube.com/watch?v=test123")

        // Verify the text was entered (value contains the typed URL)
        let value = field.value as? String ?? ""
        XCTAssertTrue(value.contains("test123"), "Typed URL should appear in the text field")
    }

    @MainActor
    func testYouTubeDownloadSmokePass_ThreeSinglesAndPlaylist_AndPlayback() {
        app.tabBars.buttons["Library"].tap()

        for link in singleTrackSmokeLinks {
            runSingleTrackDownloadSmoke(url: link)
        }

        runPlaylistDownloadSmoke(url: playlistSmokeLink)
        verifyPlaybackFromNewTrack()
    }

    /// Fast smoke: download a single track and verify playback. Used to verify the
    /// playback path without paying the cost of the full playlist run.
    @MainActor
    func testSingleDownloadAndPlayback() {
        app.tabBars.buttons["Library"].tap()
        runSingleTrackDownloadSmoke(url: singleTrackSmokeLinks[0])
        verifyPlaybackFromNewTrack()
    }

    @MainActor
    private func runSingleTrackDownloadSmoke(url: String) {
        let initialTrackCount = currentLibraryTrackCount()
        app.tabBars.buttons["Download"].tap()

        let field = app.textFields["downloadUrlField"]
        XCTAssertTrue(field.waitForExistence(timeout: 8), "Download URL field should exist")
        clearField(field)
        field.tap()
        field.typeText(url)

        let downloadButton = app.buttons["downloadButton"]
        XCTAssertTrue(downloadButton.exists, "Download button should exist")
        downloadButton.tap()

        let status = app.staticTexts["downloadStatus"]
        _ = status.waitForExistence(timeout: 2)
        if app.alerts.firstMatch.waitForExistence(timeout: 45) {
            let alertLabel = app.alerts.firstMatch.label
            let messages = app.alerts.firstMatch.staticTexts.allElementsBoundByIndex.map { $0.label }.joined(separator: " | ")
            // Dismiss alert so we can read the on-screen debug log
            app.alerts.firstMatch.buttons.firstMatch.tap()
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            let allLabels = app.staticTexts.allElementsBoundByIndex.map { $0.label }
            let debugLogs = allLabels.filter { $0.contains("[") || $0.contains("Innertube") || $0.contains("metadata") || $0.contains("INNERTUBE") || $0.contains("playable") || $0.contains("audio") }.joined(separator: "\n")
            XCTFail("Download ended with an alert for URL: \(url) | alert: \(alertLabel) | messages: \(messages) | recentLogs:\n\(debugLogs)")
            return
        }

        waitForDownloadComplete(downloadButton: downloadButton, field: field, timeout: 900)
        verifyDownloadOutcome(initialCount: initialTrackCount, allowExisting: true, trackDeltaRequired: 1)
    }

    @MainActor
    private func runPlaylistDownloadSmoke(url: String) {
        let initialTrackCount = currentLibraryTrackCount()
        app.tabBars.buttons["Download"].tap()

        let field = app.textFields["downloadUrlField"]
        XCTAssertTrue(field.waitForExistence(timeout: 8), "Download URL field should exist")
        clearField(field)
        field.tap()
        field.typeText(url)

        let downloadButton = app.buttons["downloadButton"]
        XCTAssertTrue(downloadButton.exists, "Download button should exist")
        downloadButton.tap()

        let status = app.staticTexts["downloadStatus"]
        _ = status.waitForExistence(timeout: 2)
        if app.alerts.firstMatch.waitForExistence(timeout: 45) {
            let alertLabel = app.alerts.firstMatch.label
            let messages = app.alerts.firstMatch.staticTexts.allElementsBoundByIndex.map { $0.label }.joined(separator: " | ")
            app.alerts.firstMatch.buttons.firstMatch.tap()
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            let allLabels = app.staticTexts.allElementsBoundByIndex.map { $0.label }
            let debugLogs = allLabels.filter { $0.contains("[") || $0.contains("Innertube") || $0.contains("metadata") || $0.contains("INNERTUBE") || $0.contains("playable") || $0.contains("audio") || $0.contains("Playlist") || $0.contains("playlist") }.joined(separator: "\n")
            XCTFail("Playlist download ended with an alert: \(url) | alert: \(alertLabel) | messages: \(messages) | recentLogs:\n\(debugLogs)")
            return
        }

        // Exit early once at least trackDeltaRequired tracks landed in the library — playlists can be huge.
        let earlyDeadline = Date().addingTimeInterval(300)
        while Date() < earlyDeadline {
            if app.alerts.firstMatch.exists { break }
            let count = currentLibraryTrackCount()
            if count >= initialTrackCount + 1 {
                return
            }
            app.tabBars.buttons["Download"].tap()
            RunLoop.current.run(until: Date().addingTimeInterval(2))
        }
        waitForDownloadComplete(downloadButton: downloadButton, field: field, timeout: 600)
        verifyDownloadOutcome(initialCount: initialTrackCount, allowExisting: true, trackDeltaRequired: 1)
    }

    @MainActor
    private func verifyDownloadOutcome(initialCount: Int, allowExisting: Bool, trackDeltaRequired: Int) {
        let status = app.staticTexts["downloadStatus"]
        let statusText = status.exists ? status.label : ""
        if statusText.localizedCaseInsensitiveContains("error") || statusText.localizedCaseInsensitiveContains("failed") {
            XCTFail("Download ended with error status: \(statusText)")
        }
        if app.alerts.firstMatch.exists {
            XCTFail("Download ended with an alert: \(app.alerts.firstMatch.label)")
        }
        app.tabBars.buttons["Library"].tap()
        var finalTrackCount = currentLibraryTrackCount()

        if !statusText.localizedCaseInsensitiveContains("already exists") {
            let deadline = Date().addingTimeInterval(45)
            while finalTrackCount < initialCount + trackDeltaRequired && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
                finalTrackCount = currentLibraryTrackCount()
            }
        }

        if statusText.localizedCaseInsensitiveContains("already exists") {
            XCTAssertTrue(allowExisting)
            return
        }

        XCTAssertGreaterThanOrEqual(
            finalTrackCount,
            initialCount + trackDeltaRequired,
            "Library did not register a new track for download."
        )
    }

    @MainActor
    private func verifyPlaybackFromNewTrack() {
        app.tabBars.buttons["Library"].tap()
        // SongRow lives inside a SwiftUI List; XCUITest projects List rows as .cells.
        // Try otherElements first, fall back to cells.
        let otherRows = app.otherElements.matching(identifier: "songRow")
        let cellRows = app.cells.matching(identifier: "songRow")
        let row: XCUIElement
        if otherRows.element(boundBy: 0).waitForExistence(timeout: 4) {
            row = otherRows.element(boundBy: 0)
        } else if cellRows.element(boundBy: 0).waitForExistence(timeout: 8) {
            row = cellRows.element(boundBy: 0)
        } else if app.cells.element(boundBy: 0).waitForExistence(timeout: 6) {
            row = app.cells.element(boundBy: 0)
        } else {
            XCTFail("A song row should exist after downloads (no songRow / cell found)")
            return
        }
        row.tap()

        let miniPlay = app.buttons["miniPlayerPlayPause"]
        XCTAssertTrue(miniPlay.waitForExistence(timeout: 12), "Mini player should appear after selecting a song")
        // Poll up to 8 seconds for the button to flip to the playing state — AVAudioPlayer init is async.
        let deadline = Date().addingTimeInterval(8)
        var label = miniPlay.label
        while Date() < deadline && label != "Pause" {
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            label = miniPlay.label
        }
        XCTAssertEqual(label, "Pause", "Mini player should start in playing state after selecting a song row.")
    }

    @MainActor
    private func waitForDownloadComplete(downloadButton: XCUIElement, field: XCUIElement, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        let started = Date()
        let doneMarkers = ["downloaded", "already exists", "error", "failed"]
        var finalStatus = ""

        while Date() < deadline {
            let buttonEnabled = downloadButton.isEnabled
            let buttonTitle = downloadButton.label
            let statusElement = app.staticTexts["downloadStatus"]
            let statusText = statusElement.exists ? statusElement.label.lowercased() : ""
            let fieldValue = (field.value as? String ?? "")
            let normalizedFieldValue = fieldValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let fieldLooksCleared = normalizedFieldValue.isEmpty || normalizedFieldValue == "YouTube link or playlist URL"

            finalStatus = statusText
            if fieldLooksCleared && buttonEnabled && Date().timeIntervalSince(started) > 1.5 {
                return
            }

            if Date().timeIntervalSince(started) > 1.5 && buttonEnabled && buttonTitle == "Download" {
                return
            }

            if doneMarkers.contains(where: { statusText.contains($0) }) {
                return
            }

            if app.alerts.firstMatch.exists {
                return
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }

        XCTFail("Asynchronous wait failed: Exceeded timeout of \(Int(timeout)) seconds waiting for download completion. Last status: \(finalStatus)")
    }

    @MainActor
    private func clearField(_ field: XCUIElement) {
        guard let current = field.value as? String else { return }
        let count = current.filter { $0 != " " }.count
        if count == 0 { return }
        if current.contains("https://") {
            field.tap()
            let deleteCount = String(repeating: "\u{8}", count: count)
            field.typeText(deleteCount)
        }
    }

    @MainActor
    private func currentLibraryTrackCount() -> Int {
        app.tabBars.buttons["Library"].tap()
        let songCountLabels = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", " Songs"))
        if songCountLabels.count > 0,
           let countText = songCountLabels.element(boundBy: 0).label.split(separator: " ").first,
           let count = Int(countText) {
            return count
        }
        let tableCount = app.tables.cells.count
        if tableCount > 0 { return tableCount }
        let cellCount = app.cells.count
        if cellCount > 0 { return cellCount }
        return app.otherElements.matching(identifier: "songRow").count
    }

    // MARK: - Library View Structure

    @MainActor
    func testLibraryRendersWithoutCrash() {
        app.tabBars.buttons["Library"].tap()

        // Wait for the library to fully render
        let exists = app.navigationBars.firstMatch.waitForExistence(timeout: 5)
        XCTAssertTrue(exists, "Library should render without crash")

        // Scroll the list if present
        let scrollView = app.scrollViews.firstMatch
        if scrollView.exists {
            scrollView.swipeUp()
            scrollView.swipeDown()
        }
    }
}
