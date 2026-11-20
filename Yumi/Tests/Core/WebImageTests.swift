import Testing
import Foundation
import ImageIO
import UniformTypeIdentifiers

// An image dropped on Yumi, made ready for a website: smaller, compressed, without its metadata.

private func picture(width: Int, height: Int, transparent: Bool = false, opaqueAlphaChannel: Bool = false,
                     type: UTType = .png, properties: [CFString: Any] = [:]) -> Data {
    let info = transparent || opaqueAlphaChannel ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info.rawValue)!
    context.setFillColor(red: 0.2, green: 0.6, blue: 0.9, alpha: transparent ? 0.5 : 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: opaqueAlphaChannel ? height : height / 2))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
    CGImageDestinationFinalize(destination)
    return data as Data
}

private func read(_ data: Data) -> (width: Int, height: Int, properties: [CFString: Any])? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
    return (width, height, properties)
}

@Suite struct WebImageTests {
    @Test func aLargeOpaqueImageBecomesASmallerJPEG() throws {
        let original = picture(width: 4000, height: 3000)
        let made = try #require(WebImage.make(from: original))
        let result = try #require(read(made.data))
        #expect(made.ext == "jpg")
        #expect(result.width == 2000 && result.height == 1500)
        #expect(made.data.count < original.count)
    }

    @Test func anOpaqueImageWithAnAlphaChannelBecomesAJPEG() throws {
        // What design tools export: an alpha channel, every pixel opaque
        let made = try #require(WebImage.make(from: picture(width: 4000, height: 3000, opaqueAlphaChannel: true)))
        #expect(made.ext == "jpg")
    }

    @Test func theButtonIsOfferedOnlyForWhatCanBeConverted() {
        #expect(WebImage.canConvert(fileNamed: "photo.PNG"))
        #expect(WebImage.canConvert(fileNamed: "photo.heic"))
        #expect(!WebImage.canConvert(fileNamed: "logo.svg"))
        #expect(!WebImage.canConvert(fileNamed: "devis.pdf"))
        #expect(!WebImage.canConvert(fileNamed: "notes"))
    }

    @Test func aTransparentImageStaysAPNGWithItsTransparency() throws {
        let made = try #require(WebImage.make(from: picture(width: 3000, height: 3000, transparent: true)))
        let result = try #require(read(made.data))
        #expect(made.ext == "png")
        #expect(result.width == 2000)
        #expect(result.properties[kCGImagePropertyHasAlpha] as? Bool == true)
    }

    @Test func aSmallImageIsNotEnlarged() throws {
        let made = try #require(WebImage.make(from: picture(width: 800, height: 600)))
        #expect(read(made.data)?.width == 800)
    }

    @Test func aTurnedPhotoComesOutUprightWithoutWhereItWasTaken() throws {
        let photo = picture(width: 400, height: 300, type: .jpeg, properties: [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 48.85, kCGImagePropertyGPSLongitude: 2.35],
        ])
        let made = try #require(WebImage.make(from: photo))
        let result = try #require(read(made.data))
        #expect(result.width == 300 && result.height == 400)
        #expect(result.properties[kCGImagePropertyGPSDictionary] == nil)
        #expect((result.properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
    }

    @Test func somethingElseIsNil() {
        #expect(WebImage.make(from: Data("%PDF-1.7 pas une image".utf8)) == nil)
    }
}
