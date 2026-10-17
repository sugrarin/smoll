import XCTest
import CoreGraphics
@testable import smoll

final class PPMTests: XCTestCase {
    private func solid(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat,
                       alpha: CGFloat = 1) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: red, green: green, blue: blue, alpha: alpha)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    private func ppm(_ img: CGImage) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("smoll-\(UUID().uuidString).ppm")
        defer { try? FileManager.default.removeItem(at: url) }
        try Compressor.writePPM(img, to: url)
        return try Data(contentsOf: url)
    }

    func testHeaderAndSize() throws {
        let data = try ppm(solid(width: 4, height: 2, red: 1, green: 0, blue: 0))
        let header = Data("P6\n4 2\n255\n".utf8)

        XCTAssertEqual(data.prefix(header.count), header)
        XCTAssertEqual(data.count, header.count + 4 * 2 * 3)
    }

    func testPixelsAreRGB() throws {
        let data = try ppm(solid(width: 3, height: 3, red: 1, green: 0, blue: 0))

        XCTAssertEqual(Array(data.suffix(3)), [255, 0, 0])
    }

    func testTransparencyIsFlattenedToWhite() throws {
        let data = try ppm(solid(width: 2, height: 2, red: 0, green: 0, blue: 0, alpha: 0))

        XCTAssertEqual(Array(data.suffix(3)), [255, 255, 255])
    }
}
