import XCTest
@testable import smoll

final class FinalizeTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("smoll-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { [dir] in try? FileManager.default.removeItem(at: dir!) }
    }

    private func makeFile(_ name: String, bytes: Int) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(count: bytes).write(to: url)
        return url
    }

    func testKeepOriginalSavesSmallerCopyNextToIt() throws {
        let original = try makeFile("photo.jpg", bytes: 1000)
        let produced = try makeFile("produced.jpg", bytes: 400)

        let (dest, newSize, preserved) = try Compressor.finalize(original: original, produced: produced,
                                                                 keepOriginal: true)

        XCTAssertEqual(dest.lastPathComponent, "photo smoll.jpg")
        XCTAssertEqual(newSize, 400)
        XCTAssertEqual(preserved, original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }

    func testKeepOriginalNumbersTheCopyWhenNameIsTaken() throws {
        let original = try makeFile("photo.jpg", bytes: 1000)
        _ = try makeFile("photo smoll.jpg", bytes: 1)
        let produced = try makeFile("produced.jpg", bytes: 400)

        let (dest, _, _) = try Compressor.finalize(original: original, produced: produced, keepOriginal: true)

        XCTAssertEqual(dest.lastPathComponent, "photo smoll 2.jpg")
    }

    func testKeepOriginalMakesNoCopyWhenResultIsNotSmaller() throws {
        let original = try makeFile("photo.jpg", bytes: 1000)
        let produced = try makeFile("produced.jpg", bytes: 1000)

        let (dest, _, preserved) = try Compressor.finalize(original: original, produced: produced,
                                                           keepOriginal: true)

        XCTAssertEqual(dest, original)
        XCTAssertNil(preserved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("photo smoll.jpg").path))
    }

    func testMissingResultLeavesOriginalInPlace() throws {
        let original = try makeFile("photo.jpg", bytes: 1000)
        let missing = dir.appendingPathComponent("never-produced.jpg")

        XCTAssertThrowsError(try Compressor.finalize(original: original, produced: missing, force: true))

        XCTAssertEqual(Compressor.fileSize(original), 1000)
    }

    func testDefaultStillReplacesOriginalAndTrashesIt() throws {
        let original = try makeFile("photo.jpg", bytes: 1000)
        let produced = try makeFile("produced.jpg", bytes: 400)

        let (dest, _, trashed) = try Compressor.finalize(original: original, produced: produced)
        let inTrash = try XCTUnwrap(trashed)
        addTeardownBlock { try? FileManager.default.removeItem(at: inTrash) }

        XCTAssertEqual(dest, original)
        XCTAssertEqual(Compressor.fileSize(original), 400)
        XCTAssertEqual(Compressor.fileSize(inTrash), 1000)
    }

    // parallel jobs converting "x.jpg", "x.png"… to HEIF all want "x smoll.heic"
    func testParallelJobsNeverClaimTheSameName() throws {
        let originals = try (0..<8).map { try makeFile("x.\(["jpg", "png", "jpeg", "tif", "gif", "bmp", "psd", "tga"][$0])", bytes: 1000) }
        let produced = try (0..<8).map { try makeFile("produced\($0).heic", bytes: 400) }
        var failures = 0
        let lock = NSLock()

        DispatchQueue.concurrentPerform(iterations: 8) { i in
            do {
                _ = try Compressor.finalize(original: originals[i], produced: produced[i], keepOriginal: true)
            } catch {
                lock.withLock { failures += 1 }
            }
        }

        let results = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".heic") }
        XCTAssertEqual(failures, 0)
        XCTAssertEqual(Set(results).count, 8)
        XCTAssertTrue(results.allSatisfy { $0.hasPrefix("x smoll") })
    }
}
