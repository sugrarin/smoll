import AVFoundation
import VideoToolbox

/// Video through AVFoundation: the same hardware HEVC encoder ffmpeg drove, with nothing to install.
enum VideoEncoder {
    static func compress(_ url: URL, settings: Settings, ctx: JobContext) async throws -> URL {
        try ctx.checkCancelled()
        let asset = AVURLAsset(url: url)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw CompressError.failed("no video track")
        }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first

        let ext = url.pathExtension.lowercased()
        let out = ctx.file(ext: ext)
        let writer = try AVAssetWriter(outputURL: out, fileType: ext == "mp4" ? .mp4 : ext == "m4v" ? .m4v : .mov)
        writer.shouldOptimizeForNetworkUse = true // moov up front, like ffmpeg's +faststart
        writer.metadata = try await metadata(of: asset)
        let reader = try AVAssetReader(asset: asset)

        var pairs = [try await video(videoTrack, settings: settings)]
        if let audioTrack { pairs.append(try await audio(audioTrack)) }
        for (output, input) in pairs {
            guard reader.canAdd(output), writer.canAdd(input) else { throw CompressError.failed("can't set up video") }
            reader.add(output)
            writer.add(input)
        }

        guard reader.startReading() else { throw CompressError.failed(reader.error?.localizedDescription ?? "can't read video") }
        guard writer.startWriting() else { throw CompressError.failed(writer.error?.localizedDescription ?? "can't write video") }
        writer.startSession(atSourceTime: .zero)

        // both tracks at once: the writer interleaves them and stalls one that runs too far ahead
        await withTaskGroup(of: Void.self) { group in
            for (output, input) in pairs {
                group.addTask { await pump(output, into: input, ctx: ctx) }
            }
        }

        if ctx.isCancelled || reader.status == .failed {
            reader.cancelReading()
            writer.cancelWriting()
            try ctx.checkCancelled()
            throw CompressError.failed(reader.error?.localizedDescription ?? "can't read video")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw CompressError.failed(writer.error?.localizedDescription ?? "can't write video")
        }
        return out
    }

    // MARK: - Picture

    private static func video(_ track: AVAssetTrack, settings: Settings) async throws
        -> (AVAssetReaderOutput, AVAssetWriterInput) {
        let (natural, transform, formats) = try await track.load(.naturalSize, .preferredTransform, .formatDescriptions)
        let format = formats.first
        let hdr = format.map(isHDR) ?? false

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                                                            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        output.alwaysCopiesSampleData = false

        let size = outputSize(natural: natural, transform: transform, limit: settings.size)
        var compression: [String: Any] = [AVVideoQualityKey: Quality.video(settings.level)]
        if hdr { compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel }
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoCompressionPropertiesKey: compression,
        ]
        if let colors = format.flatMap(colorProperties) { videoSettings[AVVideoColorPropertiesKey] = colors }

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.transform = transform // keep the rotation flag instead of re-rotating pixels
        input.expectsMediaDataInRealTime = false
        return (output, input)
    }

    /// Size in the track's stored orientation, scaled so the picture as shown fits the limit.
    static func outputSize(natural: CGSize, transform: CGAffineTransform,
                           limit: Settings.Size) -> (width: Int, height: Int) {
        let shown = CGRect(origin: .zero, size: natural).applying(transform)
        let (shownW, shownH) = (abs(shown.width), abs(shown.height))
        var scale: CGFloat = 1
        switch limit {
        case .maxWidth(let px) where shownW > CGFloat(px): scale = CGFloat(px) / shownW
        case .maxHeight(let px) where shownH > CGFloat(px): scale = CGFloat(px) / shownH
        default: break
        }
        // the encoder wants even dimensions
        func even(_ v: CGFloat) -> Int { max(2, Int((v * scale / 2).rounded()) * 2) }
        return (even(natural.width), even(natural.height))
    }

    private static func isHDR(_ format: CMFormatDescription) -> Bool {
        let transfer = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction)
            as? String
        return transfer == kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String
            || transfer == kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String
    }

    /// The writer takes colour tags only as a full set; untagged video stays untagged.
    private static func colorProperties(_ format: CMFormatDescription) -> [String: Any]? {
        func tag(_ key: CFString) -> String? {
            CMFormatDescriptionGetExtension(format, extensionKey: key) as? String
        }
        guard let primaries = tag(kCMFormatDescriptionExtension_ColorPrimaries),
              let transfer = tag(kCMFormatDescriptionExtension_TransferFunction),
              let matrix = tag(kCMFormatDescriptionExtension_YCbCrMatrix) else { return nil }
        return [AVVideoColorPrimariesKey: primaries, AVVideoTransferFunctionKey: transfer, AVVideoYCbCrMatrixKey: matrix]
    }

    // MARK: - Sound

    private static func audio(_ track: AVAssetTrack) async throws -> (AVAssetReaderOutput, AVAssetWriterInput) {
        let format = try await track.load(.formatDescriptions).first
        if try await audioIsCopyable(track) {
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            return (output, AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format))
        }
        let source = format.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        let channels = min(max(Int(source?.mChannelsPerFrame ?? 2), 1), 2)
        let rate = [44_100.0, 48_000.0].contains(source?.mSampleRate ?? 0) ? source!.mSampleRate : 48_000
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVNumberOfChannelsKey: channels,
            AVSampleRateKey: rate,
        ])
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: channels,
            AVSampleRateKey: rate,
            AVEncoderBitRateKey: 80_000 * channels,
        ])
        input.expectsMediaDataInRealTime = false
        return (output, input)
    }

    /// AAC at a modest bitrate is already small; re-encoding it would only add generation loss.
    static func audioIsCopyable(_ track: AVAssetTrack) async throws -> Bool {
        let (formats, bitsPerSecond) = try await track.load(.formatDescriptions, .estimatedDataRate)
        guard let format = formats.first else { return false }
        return CMFormatDescriptionGetMediaSubType(format) == kAudioFormatMPEG4AAC && bitsPerSecond <= 192_000
    }

    // MARK: - Plumbing

    private static func metadata(of asset: AVURLAsset) async throws -> [AVMetadataItem] {
        var items = try await asset.load(.metadata)
        // the shooting date often lives only in the container header, not among the items
        let hasDate = items.contains { $0.commonKey == .commonKeyCreationDate }
        if !hasDate, let date = try await asset.load(.creationDate) {
            let item = AVMutableMetadataItem()
            item.identifier = .commonIdentifierCreationDate
            item.value = try await date.load(.value)
            items.append(item)
        }
        return items
    }

    private static func pump(_ output: AVAssetReaderOutput, into input: AVAssetWriterInput,
                             ctx: JobContext) async {
        let queue = DispatchQueue(label: "smoll.video.pump")
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var finished = false
            input.requestMediaDataWhenReady(on: queue) {
                guard !finished else { return }
                while input.isReadyForMoreMediaData {
                    // polled per frame: in-process work has no process to kill
                    let sample = ctx.isCancelled ? nil : output.copyNextSampleBuffer()
                    guard let sample, input.append(sample) else {
                        finished = true
                        input.markAsFinished()
                        done.resume()
                        return
                    }
                }
            }
        }
    }
}
