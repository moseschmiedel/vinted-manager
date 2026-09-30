import Foundation
import ImageIO
import UniformTypeIdentifiers

// Decode with the orientation applied, then encode only pixels and JPEG quality.
// Never copy source properties: originals can contain GPS, EXIF and camera details.
do {
    let args = CommandLine.arguments
    guard (3...4).contains(args.count) else {
        throw NSError(domain: "PhotoConverter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Usage: VintedPhotoConverter SOURCE DESTINATION [MAX_PIXELS]"])
    }
    let sourceURL = URL(fileURLWithPath: args[1])
    let destinationURL = URL(fileURLWithPath: args[2])
    guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int else {
        throw NSError(domain: "PhotoConverter", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot decode photo: \(args[1])"])
    }
    let maximum = args.count == 4 ? Int(args[3]) ?? 0 : max(width, height)
    guard maximum > 0,
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maximum, max(width, height)),
          ] as CFDictionary),
          let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
        throw NSError(domain: "PhotoConverter", code: 3, userInfo: [NSLocalizedDescriptionKey: "Cannot convert photo: \(args[1])"])
    }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "PhotoConverter", code: 4, userInfo: [NSLocalizedDescriptionKey: "Cannot write JPEG: \(args[2])"])
    }
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
