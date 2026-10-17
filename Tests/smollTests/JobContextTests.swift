import XCTest
@testable import smoll

final class JobContextTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("smoll-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { [dir] in try? FileManager.default.removeItem(at: dir!) }
    }

    private func makeFile(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(count: 10).write(to: url)
        return url
    }

    private func volume(_ url: URL) throws -> NSObject? {
        try url.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
    }

    func testWorkDirIsOnTheSameVolumeAsTheFile() throws {
        let file = try makeFile("a.jpg")
        let ctx = try JobContext(near: file)
        defer { ctx.cleanup() }

        XCTAssertEqual(try volume(ctx.dir), try volume(file))
    }

    func testFilesAreUniqueAndInsideWorkDir() throws {
        let ctx = try JobContext(near: try makeFile("a.jpg"))
        defer { ctx.cleanup() }

        let a = ctx.file(ext: "jpg"), b = ctx.file(ext: "jpg")

        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.deletingLastPathComponent().standardizedFileURL, ctx.dir.standardizedFileURL)
        XCTAssertEqual(a.pathExtension, "jpg")
    }

    func testCleanupRemovesEverythingTheJobLeft() throws {
        let ctx = try JobContext(near: try makeFile("a.mp4"))
        try Data(count: 100).write(to: ctx.file(ext: "mp4"))

        ctx.cleanup()

        XCTAssertFalse(FileManager.default.fileExists(atPath: ctx.dir.path))
    }

    // MARK: - Processes

    func testRunReturnsExitStatus() async throws {
        let ctx = try JobContext(near: try makeFile("a.jpg"))
        defer { ctx.cleanup() }

        let ok = try await ctx.run("/usr/bin/true", [])
        let bad = try await ctx.run("/usr/bin/false", [])

        XCTAssertEqual(ok, 0)
        XCTAssertEqual(bad, 1)
    }

    func testRunAfterCancelThrowsWithoutLaunching() async throws {
        let ctx = try JobContext(near: try makeFile("a.jpg"))
        defer { ctx.cleanup() }
        let marker = dir.appendingPathComponent("marker")
        ctx.cancel()

        do {
            _ = try await ctx.run("/usr/bin/touch", [marker.path])
            XCTFail("expected cancellation")
        } catch is CancellationError {}

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testCancelStopsTheRunningProcess() async throws {
        let ctx = try JobContext(near: try makeFile("a.mp4"))
        defer { ctx.cleanup() }
        let started = Date()
        let task = Task { try await ctx.run("/bin/sleep", ["30"]) }
        try await Task.sleep(nanoseconds: 300_000_000)

        ctx.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testCancelLeavesOtherJobsAlone() async throws {
        let a = try JobContext(near: try makeFile("a.mp4"))
        let b = try JobContext(near: try makeFile("b.mp4"))
        defer { a.cleanup(); b.cleanup() }
        let other = Task { try await b.run("/bin/sleep", ["1"]) }
        let victim = Task { try await a.run("/bin/sleep", ["30"]) }
        try await Task.sleep(nanoseconds: 300_000_000)

        a.cancel()

        let status = try await other.value
        XCTAssertEqual(status, 0)
        _ = try? await victim.value
    }

    func testPipeFeedsFirstProcessIntoSecond() async throws {
        let ctx = try JobContext(near: try makeFile("a.jpg"))
        defer { ctx.cleanup() }
        let out = ctx.file(ext: "txt")

        let (s1, s2) = try await ctx.runPipe(("/bin/echo", ["hello"]),
                                             into: ("/bin/sh", ["-c", "cat > '\(out.path)'"]))

        XCTAssertEqual(s1, 0)
        XCTAssertEqual(s2, 0)
        XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), "hello\n")
    }
}
