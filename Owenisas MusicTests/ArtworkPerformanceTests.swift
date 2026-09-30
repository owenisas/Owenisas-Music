import XCTest
import UIKit
@testable import Owenisas_Music

final class ArtworkPerformanceTests: XCTestCase {
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("artwork-perf-\(UUID().uuidString).jpg")
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4096, height: 3072), format: format).image { context in
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4096, height: 3072))
            UIColor.systemMint.setFill()
            context.fill(CGRect(x: 2048, y: 0, width: 2048, height: 3072))
        }
        try XCTUnwrap(image.jpegData(compressionQuality: 0.9)).write(to: url)
        return url
    }

    func testLargeArtworkDecodeIsBoundedAndPreservesAspectRatio() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = ImageCache()
        let image = try XCTUnwrap(cache.image(for: url.path))
        let cg = try XCTUnwrap(image.cgImage)
        XCTAssertLessThanOrEqual(max(cg.width, cg.height), 2048)
        XCTAssertEqual(Double(cg.width) / Double(cg.height), 4.0 / 3.0, accuracy: 0.01)
        XCTAssertTrue(cache.cachedImage(for: url.path) === image)
    }

    func testThumbnailRemainsSmallAndCached() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = ImageCache()
        let image = try XCTUnwrap(cache.thumbnail(for: url.path, pointSize: 48))
        XCTAssertLessThanOrEqual(try XCTUnwrap(image.cgImage).width, 192)
        XCTAssertTrue(cache.cachedThumbnail(for: url.path, pointSize: 48) === image)
        cache.clear()
        XCTAssertNil(cache.cachedThumbnail(for: url.path, pointSize: 48))
    }

    func testColdArtworkDecodeBenchmark() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = ImageCache()
        var milliseconds: [Double] = []
        var bytes = 0
        for _ in 0..<10 {
            cache.clear()
            let start = ProcessInfo.processInfo.systemUptime
            let image = try XCTUnwrap(cache.image(for: url.path))
            milliseconds.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            let cg = try XCTUnwrap(image.cgImage)
            bytes = cg.bytesPerRow * cg.height
        }
        milliseconds.sort()
        print("ARTWORK_BENCHMARK median_ms=\(milliseconds[5]) decoded_bytes=\(bytes) runs=10 source=4096x3072")
    }
}
