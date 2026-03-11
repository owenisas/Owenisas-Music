import SwiftUI
import UIKit

// MARK: - Image Cache (prevents reloading from disk on every redraw)

final class ImageCache {
    static let shared = ImageCache()
    private var cache = NSCache<NSString, UIImage>()
    private var colorCache = NSCache<NSString, ColorCacheWrapper>()
    private var failedPaths = Set<String>() // avoid re-trying broken images

    init() {
        cache.countLimit = 50
        cache.totalCostLimit = 80 * 1024 * 1024 // 80MB
        colorCache.countLimit = 50
    }

    func cachedImage(for path: String) -> UIImage? {
        return cache.object(forKey: path as NSString)
    }

    func image(for path: String) -> UIImage? {
        let key = path as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        // Don't retry paths that already failed
        if failedPaths.contains(path) { return nil }

        // Try standard loading first, then Data-based (handles WebP/unknown formats)
        var image = UIImage(contentsOfFile: path)
        if image == nil, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
            image = UIImage(data: data)
        }
        guard let img = image else {
            failedPaths.insert(path)
            return nil
        }
        cache.setObject(img, forKey: key)
        return img
    }

    func colors(for path: String) -> UIImage.DominantColors? {
        return colorCache.object(forKey: path as NSString)?.colors
    }

    func setColors(_ colors: UIImage.DominantColors, for path: String) {
        colorCache.setObject(ColorCacheWrapper(colors: colors), forKey: path as NSString)
    }

    func clear() {
        cache.removeAllObjects()
        colorCache.removeAllObjects()
        failedPaths.removeAll()
    }
}

class ColorCacheWrapper {
    let colors: UIImage.DominantColors
    init(colors: UIImage.DominantColors) {
        self.colors = colors
    }
}

// MARK: - Cached Cover Image View (replaces inline UIImage loading)

struct CachedCoverImage: View {
    let path: String?
    let size: CGFloat
    let cornerRadius: CGFloat

    @State private var uiImage: UIImage?

    init(_ url: URL?, size: CGFloat = 48, cornerRadius: CGFloat = 8) {
        self.path = url?.path
        self.size = size
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        Group {
            if let uiImage = uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(UIColor.tertiarySystemFill))
                    .frame(width: size, height: size)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: size * 0.38))
                            .foregroundStyle(.secondary)
                    )
            }
        }
        .onAppear {
            loadImage()
        }
        .onChange(of: path) {
            loadImage()
        }
    }

    private func loadImage() {
        guard let path = path else {
            self.uiImage = nil
            return
        }
        if let cached = ImageCache.shared.cachedImage(for: path) {
            self.uiImage = cached
            return
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            guard let img = ImageCache.shared.image(for: path) else { return }
            DispatchQueue.main.async {
                self.uiImage = img
            }
        }
    }
}

// MARK: - Dominant Color Extraction (proper multi-color)

extension UIImage {
    struct DominantColors {
        var primary: UIColor
        var secondary: UIColor
        var accent: UIColor
    }

    func dominantColors(count: Int = 6) -> DominantColors {
        guard let cgImage = self.cgImage else {
            return DominantColors(primary: .darkGray, secondary: .gray, accent: .white)
        }

        // Very small sample size for speed
        let width = 20
        let height = 20
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var rawData = [UInt8](repeating: 0, count: width * height * 4)
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: &rawData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return DominantColors(primary: .darkGray, secondary: .gray, accent: .white)
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Collect pixel colors into simple buckets
        var buckets: [(r: CGFloat, g: CGFloat, b: CGFloat, count: Int)] = []
        for y in stride(from: 0, to: height, by: 2) {
            for x in stride(from: 0, to: width, by: 2) {
                let i = (y * width + x) * 4
                let r = CGFloat(rawData[i]) / 255.0
                let g = CGFloat(rawData[i + 1]) / 255.0
                let b = CGFloat(rawData[i + 2]) / 255.0

                let brightness = (r + g + b) / 3.0
                if brightness < 0.08 || brightness > 0.92 { continue }

                var found = false
                for idx in buckets.indices {
                    let dr = buckets[idx].r / CGFloat(buckets[idx].count) - r
                    let dg = buckets[idx].g / CGFloat(buckets[idx].count) - g
                    let db = buckets[idx].b / CGFloat(buckets[idx].count) - b
                    if (dr * dr + dg * dg + db * db) < 0.04 {
                        buckets[idx].r += r
                        buckets[idx].g += g
                        buckets[idx].b += b
                        buckets[idx].count += 1
                        found = true
                        break
                    }
                }
                if !found {
                    buckets.append((r: r, g: g, b: b, count: 1))
                }
            }
        }

        buckets.sort { $0.count > $1.count }

        func colorFromBucket(_ b: (r: CGFloat, g: CGFloat, b: CGFloat, count: Int)) -> UIColor {
            UIColor(red: b.r / CGFloat(b.count), green: b.g / CGFloat(b.count), blue: b.b / CGFloat(b.count), alpha: 1)
        }

        let primary = buckets.count > 0 ? colorFromBucket(buckets[0]) : .darkGray
        let secondary = buckets.count > 1 ? colorFromBucket(buckets[1]) : primary.withAlphaComponent(0.7)
        let accent = buckets.count > 2 ? colorFromBucket(buckets[2]) : .white

        return DominantColors(primary: primary, secondary: secondary, accent: accent)
    }
}

// MARK: - Animated Mesh Background (performance-optimized)

struct AnimatedNowPlayingBackground: View {
    let image: UIImage?
    var imagePath: String? = nil

    @State private var colors: [Color] = Array(repeating: Color(white: 0.08), count: 4)

    var body: some View {
        ZStack {
            Color.black

            // Static gradient blobs — NO TimelineView animation (huge perf win)
            // Instead, use slow implicit SwiftUI animations on blob positions
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height

                ForEach(0..<4, id: \.self) { i in
                    Circle()
                        .fill(colors[i].opacity(0.5))
                        .frame(width: w * 0.8, height: w * 0.8)
                        .blur(radius: 70)
                        .offset(
                            x: blobOffset(index: i, axis: .horizontal, width: w),
                            y: blobOffset(index: i, axis: .vertical, height: h)
                        )
                }
            }
            .drawingGroup()

            Color.black.opacity(0.35)
        }
        .ignoresSafeArea()
        .onAppear { extractColors() }
        .onChange(of: image) {
            withAnimation(.easeInOut(duration: 1.5)) {
                extractColors()
            }
        }
    }

    private enum Axis { case horizontal, vertical }

    private func blobOffset(index: Int, axis: Axis, width: CGFloat = 0, height: CGFloat = 0) -> CGFloat {
        let offsets: [[CGFloat]] = [
            [-0.2, -0.3],   // top-left
            [0.15, -0.1],   // top-right
            [-0.1, 0.2],    // bottom-left
            [0.2, 0.15]     // bottom-right
        ]
        let pair = offsets[index % offsets.count]
        switch axis {
        case .horizontal: return pair[0] * width
        case .vertical: return pair[1] * height
        }
    }

    private func extractColors() {
        guard let image = image else {
            colors = [
                Color(white: 0.15),
                Color(white: 0.10),
                Color(white: 0.12),
                Color(white: 0.08)
            ]
            return
        }

        if let path = imagePath, let cached = ImageCache.shared.colors(for: path) {
            let newColors = [
                Color(cached.primary),
                Color(cached.secondary),
                Color(cached.accent),
                Color(cached.primary).opacity(0.7)
            ]
            withAnimation(.easeInOut(duration: 1.0)) {
                colors = newColors
            }
            return
        }

        // Run extraction off main thread
        DispatchQueue.global(qos: .userInitiated).async {
            let extracted = image.dominantColors()
            if let path = self.imagePath {
                ImageCache.shared.setColors(extracted, for: path)
            }
            
            let newColors = [
                Color(extracted.primary),
                Color(extracted.secondary),
                Color(extracted.accent),
                Color(extracted.primary).opacity(0.7)
            ]
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 1.0)) {
                    colors = newColors
                }
            }
        }
    }
}
