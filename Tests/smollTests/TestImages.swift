import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum TestImages {
    /// A noisy picture saved at maximum quality, so any real compression shrinks it.
    static func cgImage(width: Int = 256, height: Int = 192,
                        space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: space,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        var rng = SystemRandomNumberGenerator()
        for y in stride(from: 0, to: height, by: 4) {
            for x in stride(from: 0, to: width, by: 4) {
                ctx.setFillColor(red: .random(in: 0...1, using: &rng), green: .random(in: 0...1, using: &rng),
                                 blue: .random(in: 0...1, using: &rng), alpha: 1)
                ctx.fill(CGRect(x: x, y: y, width: 4, height: 4))
            }
        }
        return ctx.makeImage()!
    }

    @discardableResult
    static func jpeg(in dir: URL, name: String, image: CGImage = cgImage(),
                     properties: [CFString: Any] = [:]) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        var props = properties
        props[kCGImageDestinationLossyCompressionQuality] = 1.0
        CGImageDestinationAddImage(dst, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }
}
