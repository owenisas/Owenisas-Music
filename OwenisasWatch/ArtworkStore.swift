import Foundation
import UIKit

/// Cover thumbnails fetched from the phone on demand and cached on the watch
/// (memory + Library/Caches), so lists and downloaded music keep their
/// artwork when the phone is away.
@MainActor
final class ArtworkStore {
    static let shared = ArtworkStore()

    private let memory = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    /// Songs the phone says have no cover (this launch only).
    private var missing = Set<String>()
    private var freeSlots = 3
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var writesSincePrune = 0

    private static let maxDiskFiles = 400

    private let directory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("Artwork", isDirectory: true)
    }()

    private init() {
        memory.countLimit = 120
    }

    private func key(_ songID: String, _ pixels: Int) -> String {
        "\(pixels)-" + WatchFileNaming.hash(songID)
    }

    func cachedImage(songID: String, maxPixel: Int = WatchArtworkSize.thumbnail) -> UIImage? {
        memory.object(forKey: key(songID, maxPixel) as NSString)
    }

    func image(songID: String, maxPixel: Int = WatchArtworkSize.thumbnail) async -> UIImage? {
        let pixels = WatchArtworkSize.clamped(maxPixel)
        let key = key(songID, pixels)
        if let image = memory.object(forKey: key as NSString) { return image }
        if missing.contains(key) { return nil }
        if let task = inFlight[key] { return await task.value }
        let task = Task { await self.load(key: key, songID: songID, pixels: pixels) }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        return image
    }

    /// Fetch thumbnails ahead of time (e.g. for songs being downloaded).
    func prefetch(_ songIDs: [String]) {
        Task(priority: .utility) {
            for id in songIDs { _ = await self.image(songID: id) }
        }
    }

    private func load(key: String, songID: String, pixels: Int) async -> UIImage? {
        let file = directory.appendingPathComponent(key + ".jpg")
        if let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
            memory.setObject(image, forKey: key as NSString)
            return image
        }
        await acquireSlot()
        defer { releaseSlot() }
        do {
            let artwork = try await PhoneLink.shared.artwork(songID: songID, maxPixel: pixels)
            guard let jpeg = artwork.jpeg, let image = UIImage(data: jpeg) else {
                missing.insert(key)
                return nil
            }
            memory.setObject(image, forKey: key as NSString)
            store(jpeg, at: file)
            return image
        } catch {
            // Transient (phone away): try again next time.
            return nil
        }
    }

    private func store(_ data: Data, at file: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        writesSincePrune += 1
        guard writesSincePrune >= 50 else { return }
        writesSincePrune = 0
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        guard files.count > Self.maxDiskFiles else { return }
        let oldestFirst = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return a < b
        }
        for url in oldestFirst.prefix(files.count - Self.maxDiskFiles) {
            try? fm.removeItem(at: url)
        }
    }

    private func acquireSlot() async {
        if freeSlots > 0 {
            freeSlots -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func releaseSlot() {
        if waiters.isEmpty {
            freeSlots += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
