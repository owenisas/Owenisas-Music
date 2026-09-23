import Foundation
import SwiftUI
import Testing
import UIKit
import WidgetKit
@testable import Owenisas_Music

// MARK: - Widget rendering
// Renders every widget family/state with ImageRenderer at iPhone 17 sizes.
// Timer-driven progress and the accessory backdrop are drawn as plain shapes
// (ImageRenderer can't draw the WidgetKit versions); layout is otherwise real.
// Set TEST_RUNNER_NOWPLAYING_RENDER_DIR=<dir> on `xcodebuild test` to keep
// the PNGs for visual review; otherwise they go to the temporary directory.

@MainActor
struct NowPlayingWidgetRenderTests {
    enum State: String, CaseIterable {
        case playing, paused, empty, noArtwork
    }

    struct Case: CustomTestStringConvertible {
        let family: WidgetFamily
        let state: State
        var testDescription: String { "\(family)-\(state.rawValue)" }
    }

    static let cases: [Case] = {
        let families: [WidgetFamily] = [.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular, .accessoryInline]
        return families.flatMap { family in State.allCases.map { Case(family: family, state: $0) } }
    }()

    /// iPhone 17 (402 pt wide) widget sizes, points.
    private static func size(for family: WidgetFamily) -> CGSize {
        switch family {
        case .systemSmall: return CGSize(width: 170, height: 170)
        case .systemMedium: return CGSize(width: 364, height: 170)
        case .accessoryRectangular: return CGSize(width: 172, height: 76)
        case .accessoryCircular: return CGSize(width: 76, height: 76)
        case .accessoryInline: return CGSize(width: 257, height: 26)
        default: return CGSize(width: 170, height: 170)
        }
    }

    private static let artwork: UIImage = {
        let size = CGSize(width: 300, height: 300)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            UIColor(red: 0.93, green: 0.42, blue: 0.20, alpha: 1).setFill()
            cg.fill(CGRect(origin: .zero, size: size))
            UIColor(red: 0.98, green: 0.80, blue: 0.30, alpha: 1).setFill()
            cg.fillEllipse(in: CGRect(x: 90, y: 60, width: 120, height: 120))
            UIColor(red: 0.20, green: 0.10, blue: 0.25, alpha: 1).setFill()
            cg.fill(CGRect(x: 0, y: 190, width: 300, height: 110))
        }
    }()

    private static func entry(_ state: State) -> NowPlayingEntry {
        let now = Date()
        switch state {
        case .playing:
            return NowPlayingEntry(date: now, snapshot: .preview(isPlaying: true, isFavorited: true, at: now), artwork: artwork)
        case .paused:
            return NowPlayingEntry(date: now, snapshot: .preview(isPlaying: false, isFavorited: false, at: now), artwork: artwork)
        case .empty:
            return NowPlayingEntry(date: now, snapshot: .notPlaying(at: now), artwork: nil)
        case .noArtwork:
            var snapshot = NowPlayingSnapshot.preview(isPlaying: true, isFavorited: false, at: now)
            snapshot.title = "A Much Longer Song Title That Has To Truncate"
            snapshot.artist = "Somebody With A Long Name"
            return NowPlayingEntry(date: now, snapshot: snapshot, artwork: nil)
        }
    }

    /// Approximates the system chrome: content margins + container background
    /// for Home Screen widgets, a wallpaper-ish backdrop for the Lock Screen.
    @ViewBuilder
    private static func frame(_ family: WidgetFamily, _ entry: NowPlayingEntry) -> some View {
        let size = size(for: family)
        switch family {
        case .systemSmall, .systemMedium:
            NowPlayingWidgetView(entry: entry, family: family)
                .environment(\.colorScheme, .dark)
                .environment(\.nowPlayingStaticRendering, true)
                .padding(16)
                .frame(width: size.width, height: size.height)
                .background(NowPlayingBackground(artwork: entry.snapshot.hasSong ? entry.artwork : nil))
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .padding(12)
                .background(Color(white: 0.55))
        default:
            NowPlayingWidgetView(entry: entry, family: family)
                .environment(\.colorScheme, .dark)
                .environment(\.nowPlayingStaticRendering, true)
                .foregroundStyle(.white)
                .frame(width: size.width, height: size.height)
                .padding(12)
                .background(Color(red: 0.12, green: 0.16, blue: 0.24))
        }
    }

    private static var outputDirectory: URL {
        if let custom = ProcessInfo.processInfo.environment["NOWPLAYING_RENDER_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("NowPlayingRenders", isDirectory: true)
    }

    @Test(arguments: cases)
    func rendersFamily(_ testCase: Case) throws {
        let renderer = ImageRenderer(content: Self.frame(testCase.family, Self.entry(testCase.state)))
        renderer.scale = 3
        let image = try #require(renderer.uiImage, "renderer produced no image")
        let expected = Self.size(for: testCase.family)
        #expect(image.size.width >= expected.width && image.size.height >= expected.height)

        let data = try #require(image.pngData())
        let directory = Self.outputDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(testCase.testDescription).png")
        try data.write(to: file)
        print("NOWPLAYING_RENDER \(file.path)")
    }
}
