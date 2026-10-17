import XCTest
import AVFoundation
@testable import smoll

/// The video engine is AVFoundation; ffmpeg is only used here to make sample clips.
final class VideoTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        try XCTSkipIf(Tools.path("ffmpeg") == nil, "needs ffmpeg to make sample clips")
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("smoll-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { [dir] in try? FileManager.default.removeItem(at: dir!) }
    }

    // MARK: - Helpers

    private func ffmpeg(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: try XCTUnwrap(Tools.path("ffmpeg")))
        p.arguments = ["-y", "-loglevel", "error"] + args
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "ffmpeg \(args)")
    }

    /// 2 s of busy picture plus sound, encoded generously so there is something to squeeze.
    private func clip(_ name: String, size: String = "640x480", sound: String = "sine",
                      video: [String] = ["-c:v", "libx264", "-crf", "8"],
                      audio: [String] = ["-c:a", "aac", "-b:a", "128k"], extra: [String] = []) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=\(size):rate=30", "-f", "lavfi", "-i", sound,
                    "-t", "2"] + video + audio + extra + [url.path])
        return url
    }

    private func compress(_ url: URL, _ settings: Settings = Settings(), ctx: JobContext? = nil) async throws -> URL {
        let ctx = try ctx ?? JobContext(near: url)
        addTeardownBlock { ctx.cleanup() }
        let out = try await Compressor.compress(url, kind: .video, settings: settings, ctx: ctx)
        return try XCTUnwrap(out)
    }

    private func videoTrack(_ url: URL) async throws -> AVAssetTrack {
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
        return try XCTUnwrap(tracks.first)
    }

    private func codec(_ track: AVAssetTrack) async throws -> FourCharCode {
        let formats = try await track.load(.formatDescriptions)
        return CMFormatDescriptionGetMediaSubType(try XCTUnwrap(formats.first))
    }

    /// Size as shown on screen, after the track's rotation.
    private func displaySize(_ url: URL) async throws -> CGSize {
        let track = try await videoTrack(url)
        let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
        let r = CGRect(origin: .zero, size: size).applying(transform)
        return CGSize(width: abs(r.width), height: abs(r.height))
    }

    private func audio(_ url: URL) async throws -> (codec: FourCharCode, bitsPerSecond: Float) {
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let (formats, rate) = try await track.load(.formatDescriptions, .estimatedDataRate)
        return (CMFormatDescriptionGetMediaSubType(try XCTUnwrap(formats.first)), rate)
    }

    // MARK: - Picture

    func testH264BecomesSmallerHevcOfTheSameLength() async throws {
        let source = try clip("a.mp4")

        let out = try await compress(source)

        let codecType = try await codec(try await videoTrack(out))
        XCTAssertEqual(codecType, kCMVideoCodecType_HEVC)
        XCTAssertLessThan(Compressor.fileSize(out), Compressor.fileSize(source))
        let duration = try await AVURLAsset(url: out).load(.duration).seconds
        XCTAssertEqual(duration, 2, accuracy: 0.1)
        let size = try await displaySize(out)
        XCTAssertEqual(size, CGSize(width: 640, height: 480))
    }

    func testStrongerLevelGivesSmallerFile() async throws {
        let source = try clip("a.mp4")

        let normal = try await compress(source, Settings(level: .normal))
        let extreme = try await compress(source, Settings(level: .extreme))

        XCTAssertLessThan(Compressor.fileSize(extreme), Compressor.fileSize(normal))
    }

    func testMaxWidthScalesDown() async throws {
        let out = try await compress(try clip("a.mp4"), Settings(size: .maxWidth(320)))

        let size = try await displaySize(out)
        XCTAssertEqual(size, CGSize(width: 320, height: 240))
    }

    func testSizeLimitNeverUpscales() async throws {
        let out = try await compress(try clip("a.mp4"), Settings(size: .maxWidth(2000)))

        let size = try await displaySize(out)
        XCTAssertEqual(size, CGSize(width: 640, height: 480))
    }

    // phone videos are stored sideways with a rotation flag; the limit applies to what you see
    func testRotatedVideoStaysUprightAndLimitAppliesToShownSize() async throws {
        let flat = try clip("flat.mp4")
        let rotated = dir.appendingPathComponent("rotated.mp4")
        try ffmpeg(["-display_rotation", "90", "-i", flat.path, "-c", "copy", rotated.path])
        let shown = try await displaySize(rotated)
        XCTAssertEqual(shown, CGSize(width: 480, height: 640))

        let out = try await compress(rotated, Settings(size: .maxHeight(320)))

        let size = try await displaySize(out)
        XCTAssertEqual(size, CGSize(width: 240, height: 320))
    }

    func testHdrStaysTenBitHlg() async throws {
        let source = try clip("hdr.mov", video: [
            "-pix_fmt", "yuv420p10le", "-c:v", "libx265", "-tag:v", "hvc1",
            "-x265-params", "log-level=error:crf=4:colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc",
        ])

        let out = try await compress(source)

        let formats = try await videoTrack(out).load(.formatDescriptions)
        let format = try XCTUnwrap(formats.first)
        let transfer = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction)
        XCTAssertEqual(transfer as? String, kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
        let depth = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent)
        XCTAssertEqual(depth as? Int, 10)
    }

    func testCreationDateIsKept() async throws {
        let source = try clip("a.mp4", extra: ["-metadata", "creation_time=2024-05-01T10:00:00Z"])

        let out = try await compress(source)

        let date = try await AVURLAsset(url: out).load(.creationDate)?.load(.dateValue)
        XCTAssertEqual(date, ISO8601DateFormatter().date(from: "2024-05-01T10:00:00Z"))
    }

    func testCancelledJobThrowsAndLeavesNoResult() async throws {
        let source = try clip("a.mp4")
        let ctx = try JobContext(near: source)
        addTeardownBlock { ctx.cleanup() }
        ctx.cancel()

        do {
            _ = try await Compressor.compress(source, kind: .video, settings: Settings(), ctx: ctx)
            XCTFail("expected cancellation")
        } catch is CancellationError {}
    }

    // MARK: - Sound

    // noise, because a pure tone never reaches its target bitrate
    func testModestAacIsCopiedNotReencoded() async throws {
        let source = try clip("a.mp4", sound: "anoisesrc", audio: ["-c:a", "aac", "-b:a", "96k"])

        let out = try await compress(source)

        let (codecType, rate) = try await audio(out)
        XCTAssertEqual(codecType, kAudioFormatMPEG4AAC)
        XCTAssertLessThan(rate, 120_000) // a re-encode would come out at ~160k
    }

    func testPcmBecomesAac() async throws {
        let out = try await compress(try clip("a.mov", audio: ["-c:a", "pcm_s16le"]))

        let (codecType, _) = try await audio(out)
        XCTAssertEqual(codecType, kAudioFormatMPEG4AAC)
    }

    func testAudioDetection() async throws {
        let modest = try await Compressor.audioIsCopyable(try clip("a.mp4", audio: ["-c:a", "aac", "-b:a", "128k"]))
        let fat = try await Compressor.audioIsCopyable(try clip("b.mp4", sound: "anoisesrc",
                                                                audio: ["-c:a", "aac", "-b:a", "320k"]))
        let pcm = try await Compressor.audioIsCopyable(try clip("c.mov", audio: ["-c:a", "pcm_s16le"]))

        XCTAssertTrue(modest)
        XCTAssertFalse(fat)
        XCTAssertFalse(pcm)
    }
}
