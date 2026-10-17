import XCTest
@testable import smoll

@MainActor
final class JobStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("smoll-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { [dir] in try? FileManager.default.removeItem(at: dir!) }
    }

    private func file(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(count: 100).write(to: url)
        return url
    }

    private func store(work: @escaping JobStore.Work,
                       install: @escaping JobStore.Install = { _ in false }) -> JobStore {
        JobStore(work: work, install: install, primesFileAccess: false)
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private static let done: JobStore.Work = { job, _, _, _ in
        JobResult(url: job.url, newSize: 1, original: nil)
    }

    private static let sleeps: JobStore.Work = { job, _, _, ctx in
        _ = try await ctx.run("/bin/sleep", ["30"])
        return JobResult(url: job.url, newSize: 1, original: nil)
    }

    func testJobRunsToDone() async throws {
        let s = store(work: Self.done)

        s.add([try file("a.jpg")])
        await waitUntil { s.jobs.first?.state == .done(newSize: 1) }

        XCTAssertEqual(s.jobs.first?.state, .done(newSize: 1))
    }

    func testRemovingRunningJobCancelsItAndQueueMovesOn() async throws {
        let slow = try file("slow.mp4"), fast = try file("fast.jpg")
        let s = store(work: { job, settings, keep, ctx in
            job.url == slow ? try await Self.sleeps(job, settings, keep, ctx)
                            : try await Self.done(job, settings, keep, ctx)
        })
        s.add([slow, fast])
        await waitUntil { s.jobs.first?.state == .running }
        let started = Date()

        s.remove([s.jobs[0].id])
        await waitUntil { s.jobs.first?.state == .done(newSize: 1) }

        XCTAssertEqual(s.jobs.map(\.url), [fast])
        XCTAssertEqual(s.jobs.first?.state, .done(newSize: 1))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testCancelAllStopsRunningJobs() async throws {
        let stopped = expectation(description: "work stopped")
        let s = store(work: { job, _, _, ctx in
            do {
                _ = try await ctx.run("/bin/sleep", ["30"])
            } catch {
                stopped.fulfill()
                throw error
            }
            return JobResult(url: job.url, newSize: 1, original: nil)
        })
        s.add([try file("movie.mp4")])
        await waitUntil { s.jobs.first?.state == .running }

        s.cancelAll()

        await fulfillment(of: [stopped], timeout: 5)
    }

    func testFailedInstallIsNotRetriedInALoop() async throws {
        var calls = 0
        let s = store(work: { _, _, _, _ in throw CompressError.toolMissing("x") },
                      install: { _ in
                          await MainActor.run { calls += 1 }
                          return false
                      })
        s.add([try file("a.png")])
        await waitUntil { s.missingTools == ["x"] }

        s.installMissingTools()
        await waitUntil { s.failedInstall == "x" }
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(calls, 1)
        XCTAssertEqual(s.failedInstall, "x")
        XCTAssertNil(s.installingTool)
    }

    func testSuccessfulInstallResumesWaitingJobs() async throws {
        var installed = false
        let s = store(work: { job, _, _, _ in
                          guard await MainActor.run(body: { installed }) else { throw CompressError.toolMissing("x") }
                          return JobResult(url: job.url, newSize: 1, original: nil)
                      },
                      install: { _ in
                          await MainActor.run { installed = true }
                          return true
                      })
        s.add([try file("a.png")])
        await waitUntil { s.missingTools == ["x"] }

        s.installMissingTools()
        await waitUntil { s.jobs.first?.state == .done(newSize: 1) }

        XCTAssertEqual(s.jobs.first?.state, .done(newSize: 1))
        XCTAssertNil(s.failedInstall)
    }

    // MARK: - Parallel queue

    private func runningCount(_ s: JobStore) -> Int { s.jobs.filter { $0.state == .running }.count }

    func testLightJobsRunInParallelUpToTheLimit() async throws {
        let s = store(work: Self.sleeps)
        defer { s.cancelAll() }

        s.add(try (1...5).map { try file("p\($0).jpg") })
        await waitUntil { runningCount(s) == JobStore.maxParallel }
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(runningCount(s), JobStore.maxParallel)
    }

    // two hardware encodes would just fight over the same encoder
    func testOnlyOneVideoAtATime() async throws {
        let s = store(work: Self.sleeps)
        defer { s.cancelAll() }

        s.add([try file("a.mp4"), try file("b.mov"), try file("c.jpg")])
        await waitUntil { runningCount(s) == 2 }
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(s.jobs.map(\.state), [.running, .pending, .running])
    }
}
