import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An image made ready for a website: its longest side brought down to 2000 px (never enlarged),
/// turned upright, re-encoded without its metadata (place, camera), as a PNG when it has
/// transparency and as a JPEG otherwise. ImageIO only.
enum WebImage {
    static let longestSide = 2000
    static let quality = 0.82

    /// The new image and its extension ("jpg" or "png"), nil for what is not an image.
    static func make(from data: Data) -> (data: Data, ext: String)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Applies the EXIF orientation, so the pixels themselves are upright
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), longestSide),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let transparent = properties[kCGImagePropertyHasAlpha] as? Bool ?? false
        let type: UTType = transparent ? .png : .jpeg
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { return nil }
        // Only the image goes in: none of the source's properties, so no GPS and no camera.
        CGImageDestinationAddImage(destination, image, transparent ? nil : [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (output as Data, transparent ? "png" : "jpg")
    }
}
