import SwiftUI
import Testing
import UIKit
@testable import Owenisas_Music

@MainActor
struct SleepTimerActivityRenderTests {
    @Test(arguments: [false, true])
    func rendersActualActivityViews(compact: Bool) throws {
        let now = Date()
        let state = SleepTimerPresentation(title: "Midnight, softly", artist: "Owenisas Music", endDate: now.addingTimeInterval(1_182), endOfTrack: false, isPlaying: true)
        let content = SleepTimerActivityView(state: state, startedAt: now.addingTimeInterval(-600), compact: compact, staticClock: true, snapshotDate: now)
            .padding(18)
            .frame(width: compact ? 350 : 390)
            .background(Color(red: 0.035, green: 0.045, blue: 0.065))
            .clipShape(RoundedRectangle(cornerRadius: compact ? 32 : 24))
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 3
        let image = try #require(renderer.uiImage)
        #expect(image.size.width == (compact ? 350 : 390))
        let data = try #require(image.pngData())
        let directory = ProcessInfo.processInfo.environment["ISLAND_RENDER_DIR"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory.appendingPathComponent("IslandRenders")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(compact ? "sleep-timer-compact.png" : "sleep-timer-lock-screen.png")
        try data.write(to: path)
        print("ISLAND_RENDER \(path.path)")
        // ImageRenderer's unsupported UIKit progress fallback is bright yellow
        // with a red prohibited mark. Inspect the actual saved render pixels.
        let cgImage = try #require(image.cgImage)
        var pixels = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        let context = try #require(CGContext(data: &pixels, width: cgImage.width, height: cgImage.height,
                                            bitsPerComponent: 8, bytesPerRow: cgImage.width * 4,
                                            space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        let yellowPixels = stride(from: 0, to: pixels.count, by: 4).filter {
            pixels[$0] > 200 && pixels[$0 + 1] > 180 && pixels[$0 + 2] < 80
        }.count
        #expect(yellowPixels == 0, "Unsupported-render yellow placeholder must not appear in native shared view")
    }
}
