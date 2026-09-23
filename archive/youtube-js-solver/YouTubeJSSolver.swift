// YouTubeJSSolver.swift
// Bridges Apple's JavaScriptCore (JSContext) to yt-dlp-ejs's JS solver
// so the iOS app can solve YouTube's "n" challenge without a backend.
//
// Compiled only into the TestFlight build (NOT the App Store build) via
// the #if !APP_STORE guard below. The solver JS files are bundled as
// resources at Owenisas Music/Resources/youtube-solver.js.
//
// Why this exists:
//   YouTube added a per-video JavaScript challenge to its innertube API.
//   Without a valid "n" token, most videos return "This video is unavailable".
//   The open-source yt-dlp project solves this with yt-dlp-ejs, a JS solver
//   that runs YouTube's obfuscated player.js through meriyah (JS parser) and
//   astring (JS codegen) to extract and execute the n-challenge function.
//
//   This file embeds that solver into the iOS app via JavaScriptCore.
//   No Deno, no Node, no network service — all standalone on-device.

#if !APP_STORE
import Foundation
import JavaScriptCore
import OSLog

private let log = Logger(subsystem: "com.Owenisas-Music", category: "YouTubeJSSolver")

/// Result of one YouTube "n" challenge solution.
struct JSSolverResult {
    /// Maps each challenge string the caller passed in to the solved `n` token.
    /// The caller then sends the `n` token back to YouTube in the next
    /// innertube POST via the `serviceIntegrityDimensions.poToken` field.
    let solutions: [String: String]
    /// When non-nil, the solver preprocessed the player JS and the caller
    /// can cache this for subsequent calls (saves ~400ms on each subsequent
    /// video by skipping the AST parsing).
    let preprocessedPlayer: String?
    /// Wall-clock time the solve took.
    let durationSeconds: Double
}

/// Bridges the yt-dlp-ejs JS solver into Swift via JavaScriptCore.
final class YouTubeJSSolver {
    static let shared = YouTubeJSSolver()

    /// The loaded solver script (one-time init).
    private let ctx: JSContext
    private let jscFn: JSValue
    private let isReady: Bool

    private init() {
        // JavaScriptCore's default JSVirtualMachine memory limit is too small
        // for the 2.5MB YouTube player.js + 150KB solver. Use a dedicated VM
        // so the solver's allocations don't fight the main app.
        let pool = JSVirtualMachine()
        let context = JSContext(virtualMachine: pool)!

        // The yt-dlp-ejs solver ships as two files:
        //   youtube-solver-lib.js   (152KB) — sets up meriyah (JS parser) +
        //                             astring (JS codegen) as a single object
        //                             on globalThis.lib
        //   youtube-solver-core.js  (7KB)   — defines `jsc(input)` that
        //                             consumes the player.js and challenge
        //                             strings and returns solved tokens
        // We need to:
        //   1) eval lib file (populates globalThis.lib)
        //   2) copy lib's keys (astring, meriyah) onto globalThis so they're
        //      resolvable as bare identifiers in the next file
        //   3) eval core file (defines globalThis.jsc)
        guard let libURL = Bundle.main.url(forResource: "youtube-solver-lib", withExtension: "js"),
              let libScript = try? String(contentsOf: libURL, encoding: .utf8),
              let coreURL = Bundle.main.url(forResource: "youtube-solver-core", withExtension: "js"),
              let coreScript = try? String(contentsOf: coreURL, encoding: .utf8) else {
            log.error("YouTubeJSSolver: youtube-solver-lib.js or youtube-solver-core.js missing from app bundle")
            self.ctx = context
            self.jscFn = JSValue(undefinedIn: context)
            self.isReady = false
            return
        }

        // Capture JS errors so we surface them instead of swallowing.
        context.exceptionHandler = { (ctx, exc) in
            if let exc = exc {
                let msg = String(describing: exc)
                NSLog("OWENISAS_SOLVER: JS exception: %@", msg)
                log.error("YouTubeJSSolver JS exception: \(msg, privacy: .public)")
            }
        }

        // Step 1: load lib. After this, globalThis.lib is {astring, meriyah}.
        let loadLibResult = context.evaluateScript(libScript)
        NSLog("OWENISAS_SOLVER: lib load returned: %@", String(describing: loadLibResult?.toString() ?? "nil"))
        NSLog("OWENISAS_SOLVER: globalThis.lib after lib load: %@", String(describing: context.objectForKeyedSubscript("lib")?.toString() ?? "nil"))
        // Step 2: surface lib's keys as globals so core.js can find them as
        // bare identifiers. We do this with a tiny inline script that copies
        // each enumerable property onto globalThis.
        let assignResult = context.evaluateScript("for (var k in lib) { globalThis[k] = lib[k]; }")
        NSLog("OWENISAS_SOLVER: assign result: %@", String(describing: assignResult?.toString() ?? "nil"))
        NSLog("OWENISAS_SOLVER: globalThis.astring after assign: %@", String(describing: context.objectForKeyedSubscript("astring")?.toString() ?? "nil"))
        NSLog("OWENISAS_SOLVER: globalThis.meriyah after assign: %@", String(describing: context.objectForKeyedSubscript("meriyah")?.toString() ?? "nil"))
        // Step 3: load core, which defines globalThis.jsc.
        let loadCoreResult = context.evaluateScript(coreScript)
        NSLog("OWENISAS_SOLVER: core load returned: %@", String(describing: loadCoreResult?.toString() ?? "nil"))
        NSLog("OWENISAS_SOLVER: globalThis.jsc after core load: %@", String(describing: context.objectForKeyedSubscript("jsc")?.toString() ?? "nil"))

        guard let jsc = context.objectForKeyedSubscript("jsc"),
              jsc.isObject else {
            NSLog("OWENISAS_SOLVER: jsc NOT exposed by solver script — init failed")
            log.error("YouTubeJSSolver: jsc function not exposed by solver script")
            self.ctx = context
            self.jscFn = JSValue(undefinedIn: context)
            self.isReady = false
            return
        }

        self.ctx = context
        self.jscFn = jsc
        self.isReady = true
        log.info("YouTubeJSSolver: loaded successfully")
    }

    /// Solve a set of "n" challenges against a YouTube player.js string.
    /// - Parameter playerJs: the raw contents of YouTube's player.js
    ///   (~2.5MB; the caller fetched it from
    ///   `https://www.youtube.com/s/player/{hash}/player_es6.vflset/en_US/base.js`)
    /// - Parameter challenges: array of challenge strings YouTube asked
    ///   the client to sign
    /// - Returns: a JSSolverResult with one solved `n` token per challenge
    func solveN(playerJs: String, challenges: [String]) -> JSSolverResult? {
        guard isReady, !challenges.isEmpty else { return nil }

        let start = Date()
        let input: [String: Any] = [
            "type": "player",
            "player": playerJs,
            "requests": [["type": "n", "challenges": challenges]],
            "output_preprocessed": true,
        ]
        // Pass the Swift dict directly. JavaScriptCore marshals it into a
        // JS object; passing a JSON string causes e.requests to be undefined.
        let result = jscFn.call(withArguments: [input])
        let elapsed = Date().timeIntervalSince(start)

        guard let resultDict = result?.toDictionary() as? [String: Any] else {
            log.error("YouTubeJSSolver: solver returned non-dict or null")
            return nil
        }

        // Result shape:
        //   { type: "result", responses: [{ type: "result", data: {challenge: solvedN, ...} }, ...],
        //     preprocessed_player?: "..." }
        if let responses = resultDict["responses"] as? [[String: Any]],
           let first = responses.first,
           first["type"] as? String == "result",
           let data = first["data"] as? [String: String] {
            let preprocessed = resultDict["preprocessed_player"] as? String
            log.info("YouTubeJSSolver: solved \(data.count) challenge(s) in \(String(format: "%.2f", elapsed))s")
            return JSSolverResult(
                solutions: data,
                preprocessedPlayer: preprocessed,
                durationSeconds: elapsed
            )
        }

        if let responses = resultDict["responses"] as? [[String: Any]],
           let first = responses.first,
           let error = first["error"] as? String {
            log.error("YouTubeJSSolver: solver error: \(error, privacy: .public)")
        }
        return nil
    }
}
#endif
