import SwiftUI
import UIKit

// MARK: - Pfp caching

/// A shared in-memory image cache (NSCache) + a view that reads it.
///
/// AsyncImage has no persistent cache of its own: in a lazy list each
/// row is rebuilt as it scrolls back into view, and the picture
/// re-fetches and flashes. This keeps decoded images in memory, so a
/// pfp loads from the network once per session and from the cache
/// after that. NSCache evicts under memory pressure, so there is no
/// manual bookkeeping; the disk URLCache still applies underneath.
final class ImageCache {
    /// Same Swift 6 rule as StickerStore.shared: a static shared
    /// instance of a non-Sendable class needs nonisolated(unsafe).
    /// NSCache itself is thread-safe, and the view loads on the main
    /// actor.
    nonisolated(unsafe) static let shared = ImageCache()

    private let cache = NSCache<NSURL, UIImage>()

    private init() {
        cache.totalCostLimit = 50 * 1024 * 1024
    }

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func set(_ image: UIImage, for url: URL) {
        let pixels = image.size.width * image.size.height * image.scale * image.scale
        cache.setObject(image, forKey: url as NSURL, cost: Int(pixels))
    }
}

/// A picture that loads once and then comes from the cache: the image
/// when it is ready, a soft panel colour while loading, nothing on
/// failure (the caller shows its own placeholder). Drop-in for the
/// pfp AsyncImage blocks in the scrolling lists.
struct CachedImage: View {
    let url: URL?

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.fwPanelSoft
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else { return }
        if let cached = ImageCache.shared.image(for: url) {
            image = cached
            return
        }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let decoded = UIImage(data: data) else { return }
        ImageCache.shared.set(decoded, for: url)
        image = decoded
    }
}
