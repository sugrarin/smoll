import AppKit
import QuickLookThumbnailing

struct Job: Identifiable {
    enum State: Equatable {
        case pending, running
        case done(newSize: Int64)
        case needsTool(String)
        case failed(String)
        case unsupported
    }

    let id = UUID()
    var url: URL
    var kind: Kind?
    var oldSize: Int64
    var state: State = .pending
    var thumbnail: NSImage?
    var trashedOriginal: OriginalRef? // the untouched original, usually in the Trash

    var ratio: Double? {
        guard case .done(let newSize) = state, oldSize > 0 else { return nil }
        return 1.0 - Double(newSize) / Double(oldSize)
    }
}

struct JobResult {
    var url: URL
    var newSize: Int64
    var original: OriginalRef? // set only when this run moved the true original somewhere
}

@MainActor
final class JobStore: ObservableObject {
    /// Does one job inside its context; replaced in tests.
    typealias Work = @Sendable (Job, Settings, _ keepOriginal: Bool, JobContext) async throws -> JobResult
    /// Installs a tool, true if it's usable afterwards; replaced in tests.
    typealias Install = @Sendable (String) async -> Bool

    static let shared = JobStore()

    @Published var jobs: [Job] = []
    @Published var installingTool: String?
    @Published var failedInstall: String?
    @Published var settingsDirty = false

    private var running: [UUID: JobContext] = [:]
    private var settingsSnapshot = Settings.load()
    private let work: Work
    private let install: Install
    private let primesFileAccess: Bool

    init(work: @escaping Work = JobStore.compress, install: @escaping Install = JobStore.brewInstall,
         primesFileAccess: Bool = true) {
        self.work = work
        self.install = install
        self.primesFileAccess = primesFileAccess
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if Settings.load() != self.settingsSnapshot { self.settingsDirty = true }
            }
        }
    }

    var missingTools: [String] {
        let needed = Set(jobs.compactMap { if case .needsTool(let t) = $0.state { return t } else { return nil } })
        return needed.sorted()
    }

    func add(_ urls: [URL]) {
        if primesFileAccess { primeFileAccess() }
        // fresh batch runs with the current settings — reset the "settings changed" marker
        if jobs.isEmpty {
            settingsSnapshot = Settings.load()
            settingsDirty = false
        }
        let existing = Set(jobs.map(\.url.path))
        for url in urls where !existing.contains(url.path) {
            let kind = Kind(url: url)
            var job = Job(url: url, kind: kind, oldSize: Compressor.fileSize(url))
            job.thumbnail = NSWorkspace.shared.icon(forFile: url.path) // until Quick Look's preview arrives
            if kind == nil { job.state = .unsupported }
            jobs.append(job)
            loadThumbnail(for: job.id, url: url)
        }
        pump()
    }

    /// Re-run everything in the table with the current settings.
    /// Jobs whose original is still in the Trash are re-run from that original,
    /// so quality doesn't degrade cascade-style.
    func rerunAll() {
        settingsSnapshot = Settings.load()
        settingsDirty = false
        for idx in jobs.indices where jobs[idx].state != .running { reset(idx) }
        pump()
    }

    /// Re-run just the selected rows.
    func rerun(_ ids: Set<UUID>) {
        for idx in jobs.indices where ids.contains(jobs[idx].id) && jobs[idx].state != .running {
            reset(idx)
        }
        pump()
    }

    // Reset one row to pending, preferring the untouched original in the Trash so
    // quality doesn't degrade cascade-style.
    private func reset(_ idx: Int) {
        if let orig = jobs[idx].trashedOriginal?.resolve(), let kind = Kind(url: orig) {
            jobs[idx].kind = kind
            jobs[idx].oldSize = Compressor.fileSize(orig)
            jobs[idx].state = .pending
        } else {
            let url = jobs[idx].url
            jobs[idx].trashedOriginal = nil
            jobs[idx].kind = Kind(url: url) // extension may have changed after a conversion
            jobs[idx].oldSize = Compressor.fileSize(url)
            jobs[idx].state = jobs[idx].kind == nil ? .unsupported : .pending
        }
    }

    // Removing a running row kills its external processes; the file stays as it was.
    func remove(_ ids: Set<UUID>) {
        for id in ids { running[id]?.cancel() }
        jobs.removeAll { ids.contains($0.id) }
    }

    /// On quit: nothing may keep encoding in the background or litter the disk.
    func cancelAll() {
        for ctx in running.values {
            ctx.cancel()
            ctx.cleanup()
        }
    }

    // Touch the TCC-protected folders once, so all permission prompts happen
    // at the first file instead of one per folder later.
    private func primeFileAccess() {
        guard !UserDefaults.standard.bool(forKey: "tcc.primed") else { return }
        UserDefaults.standard.set(true, forKey: "tcc.primed")
        Task.detached {
            let fm = FileManager.default
            for dir in [FileManager.SearchPathDirectory.desktopDirectory, .documentDirectory, .downloadsDirectory] {
                if let url = fm.urls(for: dir, in: .userDomainMask).first {
                    _ = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                }
            }
        }
    }

    /// Images and PDFs are light enough to overlap; videos go one at a time,
    /// since two hardware encodes only fight over the same encoder.
    static let maxParallel = 3

    private func pump() {
        while let idx = nextStartable() { start(idx) }
    }

    private func nextStartable() -> Int? {
        guard running.count < Self.maxParallel else { return nil }
        let videoBusy = jobs.contains { $0.state == .running && $0.kind == .video }
        return jobs.firstIndex { $0.state == .pending && !(videoBusy && $0.kind == .video) }
    }

    private func start(_ idx: Int) {
        let job = jobs[idx]
        let ctx: JobContext
        do {
            ctx = try JobContext(near: job.url)
        } catch {
            jobs[idx].state = .failed(error.localizedDescription)
            return
        }
        jobs[idx].state = .running
        running[job.id] = ctx
        let settings = Settings.load()
        let keepOriginal = !Compressor.replacesOriginal

        Task.detached { [work] in
            let outcome: Result<JobResult, Error>
            do {
                outcome = .success(try await work(job, settings, keepOriginal, ctx))
            } catch {
                outcome = .failure(error)
            }
            ctx.cleanup()
            await self.complete(job.id, outcome)
        }
    }

    private func complete(_ id: UUID, _ outcome: Result<JobResult, Error>) {
        running[id] = nil
        if let idx = jobs.firstIndex(where: { $0.id == id }) {
            switch outcome {
            case .success(let result):
                let urlChanged = jobs[idx].url != result.url
                jobs[idx].state = .done(newSize: result.newSize)
                jobs[idx].url = result.url
                if let original = result.original { jobs[idx].trashedOriginal = original }
                if urlChanged { loadThumbnail(for: id, url: result.url) }
            case .failure(CompressError.toolMissing(let t)):
                jobs[idx].state = .needsTool(t)
            case .failure(is CancellationError):
                jobs[idx].state = .failed("cancelled")
            case .failure(let error):
                jobs[idx].state = .failed(error.localizedDescription)
            }
        }
        pump()
    }

    nonisolated static let compress: Work = { job, settings, keepOriginal, ctx in
        // re-run: compress the untouched original instead of the compressed copy
        let source = job.trashedOriginal?.resolve() ?? job.url
        guard let kind = Kind(url: source) else { throw CompressError.failed("unsupported") }
        let rerun = source != job.url
        let (url, newSize, preserved) = try await Compressor.process(
            job.url, from: source, kind: kind, settings: settings,
            keepOriginal: keepOriginal, rerun: rerun, ctx: ctx)
        return JobResult(url: url, newSize: newSize, original: rerun ? nil : preserved.map(OriginalRef.init))
    }

    // MARK: - Installing tools

    func installMissingTools() {
        guard installingTool == nil, let tool = missingTools.first else { return }
        installingTool = tool
        failedInstall = nil
        Task { [install] in
            let ok = await install(tool)
            finishInstall(tool, ok: ok)
        }
    }

    private func finishInstall(_ tool: String, ok: Bool) {
        installingTool = nil
        // no automatic retry: a failure (no network, say) would otherwise loop forever
        guard ok else {
            failedInstall = tool
            return
        }
        for idx in jobs.indices {
            if case .needsTool(let t) = jobs[idx].state, t == tool || Tools.path(t) != nil {
                jobs[idx].state = .pending
            }
        }
        pump()
        if !missingTools.isEmpty { installMissingTools() }
    }

    // Its own context, so cancelling a job never kills an install in progress.
    nonisolated static let brewInstall: Install = { tool in
        guard let brew = Tools.path("brew"),
              let ctx = try? JobContext(near: FileManager.default.temporaryDirectory) else { return false }
        defer { ctx.cleanup() }
        let status = try? await ctx.run(brew, Tools.brewArgs(for: tool))
        return status == 0 && Tools.path(tool) != nil
    }

    private func loadThumbnail(for id: UUID, url: URL) {
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 32, height: 32),
                                               scale: 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
            let img = rep?.nsImage ?? NSWorkspace.shared.icon(forFile: url.path)
            Task { @MainActor in
                if let idx = self?.jobs.firstIndex(where: { $0.id == id }) {
                    self?.jobs[idx].thumbnail = img
                }
            }
        }
    }
}
