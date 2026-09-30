import AppKit
import ImageIO
import SwiftUI

/// Small, orientation-correct previews (HEIC included) decoded off the main thread.
actor ThumbnailCache {
    static let shared = ThumbnailCache()
    private var cache: [String: CGImageBox] = [:]

    struct CGImageBox: @unchecked Sendable { let image: CGImage }

    func thumbnail(for url: URL, maxPixelSize: Int) -> CGImageBox? {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let key = "\(url.path)|\(maxPixelSize)|\(modified.timeIntervalSince1970)"
        if let hit = cache[key] { return hit }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let box = CGImageBox(image: image)
        cache[key] = box
        return box
    }
}

/// Last decoded image per photo and size, so a view that is recreated (e.g. a kanban card
/// moving to another column) shows its thumbnail on the first frame.
@MainActor
private enum RecentThumbnails {
    static var images: [String: CGImage] = [:]
}

struct Thumbnail: View {
    let url: URL
    var size: CGFloat

    @State private var image: CGImage?

    init(url: URL, size: CGFloat) {
        self.url = url
        self.size = size
        _image = State(initialValue: RecentThumbnails.images[Self.key(url, size)])
    }

    private static func key(_ url: URL, _ size: CGFloat) -> String { "\(url.path)|\(Int(size))" }

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 2).resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: url) {
            let decoded = await ThumbnailCache.shared.thumbnail(for: url, maxPixelSize: Int(size * 2))?.image
            if let decoded { RecentThumbnails.images[Self.key(url, size)] = decoded }
            image = decoded
        }
    }
}

/// A photo that fills whatever frame it gets (cropped to fill), e.g. a card or the item page hero.
struct Photo: View {
    let url: URL
    /// Longest side to decode, in points.
    var maxSize: CGFloat = 320

    @State private var image: CGImage?

    init(url: URL, maxSize: CGFloat = 320) {
        self.url = url
        self.maxSize = maxSize
        _image = State(initialValue: RecentThumbnails.images["\(url.path)|fill|\(Int(maxSize))"])
    }

    var body: some View {
        Rectangle().fill(.quaternary)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 2).resizable().scaledToFill()
                }
            }
            .clipped()
            .task(id: url) {
                let decoded = await ThumbnailCache.shared.thumbnail(for: url, maxPixelSize: Int(maxSize * 2))?.image
                if let decoded { RecentThumbnails.images["\(url.path)|fill|\(Int(maxSize))"] = decoded }
                image = decoded
            }
    }
}
