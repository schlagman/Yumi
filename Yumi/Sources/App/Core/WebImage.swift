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
        // Design tools export opaque pictures with an alpha channel: only real transparency keeps a PNG.
        let transparent = properties[kCGImagePropertyHasAlpha] as? Bool == true && isTransparent(image)
        let type: UTType = transparent ? .png : .jpeg
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { return nil }
        // Only the image goes in: none of the source's properties, so no GPS and no camera.
        CGImageDestinationAddImage(destination, image, transparent ? nil : [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (output as Data, transparent ? "png" : "jpg")
    }

    /// True when ImageIO can read files of this name: the button is offered for those only
    /// (an SVG is an image, but ImageIO cannot open one).
    static func canConvert(fileNamed name: String) -> Bool {
        guard let type = UTType(filenameExtension: (name as NSString).pathExtension), type.conforms(to: .image) else { return false }
        return (CGImageSourceCopyTypeIdentifiers() as? [String] ?? []).contains(type.identifier)
    }

    /// True when at least one pixel is not fully opaque.
    private static func isTransparent(_ image: CGImage) -> Bool {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return true }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return true }
        let row = context.bytesPerRow
        for y in 0..<height {
            for x in 0..<width where pixels[y * row + x * 4 + 3] < 255 { return true }
        }
        return false
    }
}
