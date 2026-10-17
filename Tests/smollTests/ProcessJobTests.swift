import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import smoll

final class ProcessJobTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("smoll-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { [dir] in try? FileManager.default.removeItem(at: dir!) }
    }

    func testCancelledJobLeavesTheFileUntouched() async throws {
        let photo = try TestImages.jpeg(in: dir, name: "photo.jpg")
        let before = try Data(contentsOf: photo)
        let ctx = try JobContext(near: photo)
        defer { ctx.cleanup() }
        ctx.cancel()

        do {
            _ = try await Compressor.process(photo, from: photo, kind: .jpeg, settings: Settings(),
                                             keepOriginal: false, rerun: false, ctx: ctx)
            XCTFail("expected cancellation")
        } catch is CancellationError {}

        XCTAssertEqual(try Data(contentsOf: photo), before)
    }
}
