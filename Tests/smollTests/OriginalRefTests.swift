import XCTest
@testable import smoll

final class OriginalRefTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("smoll-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { [dir] in try? FileManager.default.removeItem(at: dir!) }
    }

    private func write(_ name: String, bytes: Int) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(count: bytes).write(to: url)
        return url
    }

    func testResolvesWhileTheFileIsUntouched() throws {
        let url = try write("photo.jpg", bytes: 100)

        XCTAssertEqual(OriginalRef(url).resolve(), url)
    }

    func testGoneFileDoesNotResolve() throws {
        let url = try write("photo.jpg", bytes: 100)
        let ref = OriginalRef(url)
        try FileManager.default.removeItem(at: url)

        XCTAssertNil(ref.resolve())
    }

    // the Trash was emptied and an unrelated file with the same name landed there
    func testAnotherFileUnderTheSameNameDoesNotResolve() throws {
        let url = try write("photo.jpg", bytes: 100)
        let ref = OriginalRef(url)
        try FileManager.default.removeItem(at: url)
        _ = try write("photo.jpg", bytes: 100)

        XCTAssertNil(ref.resolve())
    }
}
