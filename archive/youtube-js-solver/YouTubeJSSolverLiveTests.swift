// YouTubeJSSolverLiveTests.swift
// End-to-end test of the JS solver: downloads real YouTube player.js,
// runs the solver on a test challenge, verifies a valid n token comes back.

import XCTest
@testable import Owenisas_Music

#if !APP_STORE
final class YouTubeJSSolverLiveTests: XCTestCase {

    /// Player.js URL. The path includes a "player hash" that changes
    /// periodically; using the current one is what yt-dlp does.
    /// In production, the iOS app fetches this from a YouTube watch page's
    /// player_config first to get the current hash.
    private let playerURL = "https://www.youtube.com/s/player/06ab6907/player_es6_tcc.vflset/en_US/base.js"

    func testSolverLoadsAndRuns_ProducesValidNToken() async throws {
        // 1) Confirm both solver scripts are bundled
        for name in ["youtube-solver-lib", "youtube-solver-core"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "js") else {
                XCTFail("\(name).js not in app bundle")
                return
            }
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
            XCTAssertGreaterThan(size, 5_000, "\(name).js seems too small (\(size) bytes)")
            print("\(name).js: \(size) bytes")
        }

        // 2) Trigger static init via a probe call (force lazy load)
        let probeResult = YouTubeJSSolver.shared.solveN(playerJs: "console.log('probe');", challenges: ["ignored"])
        XCTAssertNotNil(probeResult, "solver static init failed — check NSLog for YouTubeJSSolver error messages")
    }

    func testSolverSolvesChallenge_AgainstRealPlayerJS() async throws {
        // Fetch the real YouTube player.js (cached in /tmp for the run)
        let cachedPlayerPath = "/tmp/owen_player.js"
        let playerJs: String
        if let cached = try? String(contentsOfFile: cachedPlayerPath) {
            playerJs = cached
            print("Using cached player.js (\(cached.count) bytes)")
        } else {
            print("Fetching real player.js from YouTube...")
            let url = URL(string: playerURL)!
            let (data, _) = try await URLSession.shared.data(from: url)
            playerJs = String(data: data, encoding: .utf8) ?? ""
            XCTAssertGreaterThan(playerJs.count, 1_000_000, "player.js too small")
            try? playerJs.write(toFile: cachedPlayerPath, atomically: true, encoding: .utf8)
        }
        print("player.js size: \(playerJs.count) bytes")

        // Run the solver
        let challenge = "EuqO80dMpLlE9gIqKuF2Rv9DTGjjw9A9sU"
        let result = YouTubeJSSolver.shared.solveN(playerJs: playerJs, challenges: [challenge])
        XCTAssertNotNil(result, "solver returned nil")
        let solvedN = result?.solutions[challenge]
        XCTAssertNotNil(solvedN, "solver didn't return a token for the challenge")
        XCTAssertGreaterThan(solvedN?.count ?? 0, 10, "n token looks too short")
        XCTAssertNotEqual(solvedN, challenge, "solver returned the input unchanged")
        print("solved n token: \(solvedN!)")
        print("took \(result?.durationSeconds ?? 0)s")
    }
}
#endif
