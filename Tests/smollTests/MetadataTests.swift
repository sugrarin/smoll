import XCTest
import ImageIO
@testable import smoll

/// End-to-end through the real engine: whichever JPEG encoder is installed, the photo must keep
/// its date, place and colour profile.
final class MetadataTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("smoll-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { [dir] in try? FileManager.default.removeItem(at: dir!) }
    }

    private let date = "2024:05:01 10:00:00"

    private func photo(orientation: Int = 1) throws -> URL {
        try TestImages.jpeg(in: dir, name: "photo.jpg",
                            image: TestImages.cgImage(space: CGColorSpace(name: CGColorSpace.displayP3)!),
                            properties: [
                                kCGImagePropertyOrientation: orientation,
                                kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: date],
                                kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 59.43,
                                                                kCGImagePropertyGPSLatitudeRef: "N"],
                            ])
    }

    /// Compresses into the job folder (no finalize) and returns the result's properties.
    private func compressed(_ url: URL, settings: Settings = Settings()) async throws -> [CFString: Any] {
        let ctx = try JobContext(near: url)
        addTeardownBlock { ctx.cleanup() }
        let out = try await Compressor.compress(url, kind: .jpeg, settings: settings, ctx: ctx)
        let result = try XCTUnwrap(out)
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(result as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
    }

    private func assertKeepsMetadata(_ props: [CFString: Any], file: StaticString = #filePath, line: UInt = #line) {
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertEqual(exif?[kCGImagePropertyExifDateTimeOriginal] as? String, date, file: file, line: line)
        XCTAssertNotNil(props[kCGImagePropertyGPSDictionary], "GPS", file: file, line: line)
        XCTAssertEqual(props[kCGImagePropertyProfileName] as? String, "Display P3", file: file, line: line)
    }

    func testSameSizeJpegKeepsDateGpsAndProfile() async throws {
        assertKeepsMetadata(try await compressed(try photo()))
    }

    func testResizedJpegKeepsDateGpsAndProfile() async throws {
        let props = try await compressed(try photo(), settings: Settings(size: .maxWidth(100)))

        assertKeepsMetadata(props)
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 100)
    }

    // pixels get rotated upright, so the tag must stop asking viewers to rotate them again
    func testRotatedJpegIsUprightAndKeepsMetadata() async throws {
        let props = try await compressed(try photo(orientation: 6))

        assertKeepsMetadata(props)
        XCTAssertEqual(props[kCGImagePropertyOrientation] as? Int ?? 1, 1)
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 192)
        XCTAssertEqual(props[kCGImagePropertyPixelHeight] as? Int, 256)
    }

    func testHeifConversionKeepsDateGpsAndProfile() async throws {
        assertKeepsMetadata(try await compressed(try photo(), settings: Settings(format: .heif)))
    }
}
