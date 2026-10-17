import Foundation

/// Everything one job owns. The scratch folder sits on the same volume as the file, so putting
/// the result in place is an instant rename rather than a cross-volume copy that can fail halfway.
final class JobContext: @unchecked Sendable {
    let dir: URL

    init(near file: URL) throws {
        let fm = FileManager.default
        if let dir = try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                 appropriateFor: file, create: true) {
            self.dir = dir
        } else {
            dir = fm.temporaryDirectory.appendingPathComponent("smoll-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    func file(ext: String) -> URL {
        dir.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - External processes

    private let lock = NSLock()
    private var cancelled = false
    private var processes: [Process] = []

    var isCancelled: Bool { lock.withLock { cancelled } }

    func checkCancelled() throws {
        if isCancelled { throw CancellationError() }
    }

    /// Kills this job's processes; anything it tries to launch afterwards throws CancellationError.
    func cancel() {
        lock.withLock {
            cancelled = true
            processes.forEach { $0.terminate() }
        }
    }

    func run(_ path: String, _ args: [String]) async throws -> Int32 {
        try await wait(for: process(path, args))
    }

    /// `first | second`, like djpeg | cjpeg.
    func runPipe(_ first: (String, [String]), into second: (String, [String])) async throws -> (Int32, Int32) {
        let a = process(first.0, first.1), b = process(second.0, second.1)
        let pipe = Pipe()
        a.standardOutput = pipe
        b.standardInput = pipe
        async let sa = wait(for: a)
        async let sb = wait(for: b)
        return try await (sa, sb)
    }

    private func process(_ path: String, _ args: [String]) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        return p
    }

    // Waits via terminationHandler instead of waitUntilExit, so a long encode doesn't pin a thread.
    private func wait(for p: Process) async throws -> Int32 {
        let status: Int32 = try await withCheckedThrowingContinuation { cont in
            p.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
            do {
                // launch under the lock so cancel() can't slip in between the check and the launch
                try lock.withLock {
                    if cancelled { throw CancellationError() }
                    try p.run()
                    processes.append(p)
                }
            } catch {
                p.terminationHandler = nil
                cont.resume(throwing: error)
            }
        }
        lock.withLock { processes.removeAll { $0 === p } }
        try checkCancelled()
        return status
    }
}

/// Where the untouched original sits (usually the Trash), plus which file it was. Paths alone
/// lie: after emptying the Trash another file can land under the same name, and a re-run would
/// then compress a stranger's file into the user's place.
struct OriginalRef: Equatable {
    let url: URL
    let fileID: UInt64?

    init(_ url: URL) {
        self.url = url
        fileID = OriginalRef.fileID(of: url)
    }

    func resolve() -> URL? {
        guard let fileID, OriginalRef.fileID(of: url) == fileID else { return nil }
        return url
    }

    private static func fileID(of url: URL) -> UInt64? {
        var fresh = url
        fresh.removeAllCachedResourceValues() // URL caches resource values, and we need today's file
        return try? fresh.resourceValues(forKeys: [.fileIdentifierKey]).fileIdentifier
    }
}
