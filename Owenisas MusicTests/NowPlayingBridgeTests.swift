import Foundation
import ImageIO
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import Owenisas_Music

// MARK: - Widget reload throttling
// A song change fires several publishers back to back; the widget should see
// one write, and writes should never come faster than the minimum interval.

struct NowPlayingReloadSchedulerTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func firstChangeFiresAfterDebounce() {
        var scheduler = NowPlayingReloadScheduler(debounce: 0.3, minimumInterval: 1)
        #expect(scheduler.noteChange(at: t0) == t0.addingTimeInterval(0.3))
        #expect(scheduler.pendingFireDate == t0.addingTimeInterval(0.3))
    }

    @Test func changesWhilePendingAreCoalesced() {
        var scheduler = NowPlayingReloadScheduler(debounce: 0.3, minimumInterval: 1)
        #expect(scheduler.noteChange(at: t0) != nil)
        #expect(scheduler.noteChange(at: t0.addingTimeInterval(0.05)) == nil)
        #expect(scheduler.noteChange(at: t0.addingTimeInterval(0.2)) == nil)
    }

    @Test func reloadsAreSpacedByMinimumInterval() {
        var scheduler = NowPlayingReloadScheduler(debounce: 0.3, minimumInterval: 1)
        _ = scheduler.noteChange(at: t0)
        scheduler.didReload(at: t0.addingTimeInterval(0.3))
        // A change right after the reload waits for the interval, not just the debounce.
        #expect(scheduler.noteChange(at: t0.addingTimeInterval(0.4)) == t0.addingTimeInterval(1.3))
        scheduler.didReload(at: t0.addingTimeInterval(1.3))
        // Long after, only the debounce applies.
        #expect(scheduler.noteChange(at: t0.addingTimeInterval(10)) == t0.addingTimeInterval(10.3))
    }

    @Test func noOpFlushDoesNotCountAsReload() {
        var scheduler = NowPlayingReloadScheduler(debounce: 0.3, minimumInterval: 1)
        _ = scheduler.noteChange(at: t0)
        scheduler.cancelPending()
        #expect(scheduler.lastReload == nil)
        #expect(scheduler.noteChange(at: t0.addingTimeInterval(0.5)) == t0.addingTimeInterval(0.8))
    }

    @Test func burstOfPlayerEventsProducesOneReloadPerWindow() {
        // Simulate a skip storm: an event every 50 ms for 3 s, flushing
        // whenever a pending fire date is reached.
        var scheduler = NowPlayingReloadScheduler(debounce: 0.3, minimumInterval: 1)
        var reloads: [Date] = []
        var pending: Date?
        for step in 0...60 {
            let now = t0.addingTimeInterval(Double(step) * 0.05)
            if let fire = pending, fire <= now {
                scheduler.didReload(at: fire)
                reloads.append(fire)
                pending = nil
            }
            if let fire = scheduler.noteChange(at: now) {
                pending = fire
            }
        }
        #expect(reloads.count == 3, "3 s of events at a 1 s minimum interval, got \(reloads.count)")
        for (a, b) in zip(reloads, reloads.dropFirst()) {
            #expect(b.timeIntervalSince(a) >= 1 - 0.0001)
        }
    }
}

// MARK: - Artwork thumbnails

struct NowPlayingArtworkTests {
    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NowPlayingArtworkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeCover(size: CGSize, to url: URL) throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor.systemOrange.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: size.width * 0.2, y: size.height * 0.2, width: size.width * 0.6, height: size.height * 0.6))
        }
        try #require(image.pngData()).write(to: url)
    }

    private func pixelSize(of url: URL) -> (width: Int, height: Int, type: String)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              let type = CGImageSourceGetType(source) as String? else { return nil }
        return (width, height, type)
    }

    @Test func writesDownsampledJPEG() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cover = dir.appendingPathComponent("cover.png")
        try writeCover(size: CGSize(width: 1200, height: 800), to: cover)
        let art = dir.appendingPathComponent("Artwork/art-1.jpg")

        #expect(NowPlayingArtwork.ensureThumbnail(from: cover, at: art))
        let info = try #require(pixelSize(of: art))
        #expect(info.type == UTType.jpeg.identifier)
        #expect(max(info.width, info.height) == NowPlayingArtwork.maxPixelSize)
        #expect(info.width == 300 && info.height == 200)
    }

    @Test func smallCoversAreNotUpscaled() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cover = dir.appendingPathComponent("cover.png")
        try writeCover(size: CGSize(width: 120, height: 120), to: cover)
        let art = dir.appendingPathComponent("art.jpg")
        #expect(NowPlayingArtwork.ensureThumbnail(from: cover, at: art))
        let info = try #require(pixelSize(of: art))
        #expect(info.width <= 120)
    }

    @Test func freshThumbnailIsReusedAndStaleOneRegenerated() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let cover = dir.appendingPathComponent("cover.png")
        try writeCover(size: CGSize(width: 600, height: 600), to: cover)
        let art = dir.appendingPathComponent("art.jpg")
        #expect(NowPlayingArtwork.ensureThumbnail(from: cover, at: art))

        // Replace the thumbnail with a marker; a fresh one must be left alone.
        let marker = Data("marker".utf8)
        try marker.write(to: art)
        try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: art.path)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: cover.path)
        #expect(NowPlayingArtwork.ensureThumbnail(from: cover, at: art))
        #expect(try Data(contentsOf: art) == marker)

        // Cover edited after the thumbnail was made: regenerate.
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-120)], ofItemAtPath: art.path)
        try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: cover.path)
        #expect(NowPlayingArtwork.ensureThumbnail(from: cover, at: art))
        #expect(try Data(contentsOf: art) != marker)
        #expect(pixelSize(of: art)?.width == 300)
    }

    @Test func unreadableCoverFails() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = dir.appendingPathComponent("nope.jpg")
        #expect(!NowPlayingArtwork.ensureThumbnail(from: missing, at: dir.appendingPathComponent("a.jpg")))

        let garbage = dir.appendingPathComponent("garbage.jpg")
        try Data("definitely not an image".utf8).write(to: garbage)
        #expect(!NowPlayingArtwork.ensureThumbnail(from: garbage, at: dir.appendingPathComponent("b.jpg")))
    }

    @Test func pruneKeepsCurrentAndMostRecent() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let now = Date()
        // art-0 is the oldest; art-7 the newest.
        for index in 0..<8 {
            let url = dir.appendingPathComponent("art-\(index).jpg")
            try Data([UInt8(index)]).write(to: url)
            try fm.setAttributes([.modificationDate: now.addingTimeInterval(Double(index - 10) * 60)], ofItemAtPath: url.path)
        }
        // The current song's file is the oldest one and must survive anyway.
        NowPlayingArtwork.prune(directory: dir, keeping: "art-0.jpg", keepRecent: 2)
        let left = try fm.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(left == ["art-0.jpg", "art-6.jpg", "art-7.jpg"])
    }
}
