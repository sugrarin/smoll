import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AVFoundation

enum Level: Int {
    case normal = 0, medium, strong, extreme

    static let defaultsKeys: [String: Any] = [
        "level": 1.0,
        "size.mode": 0.0,     // 0 original, 1 max width, 2 max height
        "size.px": 0.0, // 0 = unset -> 1024
        "format": "original", // original | heif | jpeg | png | webp
        "replace": true,      // false -> keep the original, save "name smoll.ext" beside it
    ]

    /// Numbers come from the same table the engine uses, so the caption can't drift from reality
    var qualityLabel: String {
        "\(Quality.jpegMoz(self))% quality · PDF \(Quality.pdfResolution(self)) dpi"
    }

    var hint: String {
        ["Barely noticeable loss", "Balance of size and quality",
         "Loss visible when zoomed in", "Smallest files, clear loss"][rawValue]
    }
}

// per-level knobs: normal / medium / strong / extreme
enum Quality {
    static func jpegMoz(_ l: Level) -> String { ["85", "78", "65", "50"][l.rawValue] }
    static func jpegFallback(_ l: Level) -> Double { [0.8, 0.7, 0.55, 0.4][l.rawValue] }
    static func pngRange(_ l: Level) -> String { ["80-95", "65-90", "50-80", "20-60"][l.rawValue] }
    static func pdfResolution(_ l: Level) -> String { ["300", "220", "160", "120"][l.rawValue] }
    static func video(_ l: Level) -> Double { [0.65, 0.55, 0.45, 0.33][l.rawValue] }
    static func heic(_ l: Level) -> Double { [0.75, 0.62, 0.5, 0.35][l.rawValue] }
    static func webp(_ l: Level) -> String { ["80", "68", "55", "40"][l.rawValue] }
}

enum Kind {
    case jpeg, png, pdf, video, office

    init?(url: URL) {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": self = .jpeg
        case "png": self = .png
        case "pdf": self = .pdf
        case "mp4", "mov", "m4v": self = .video
        case "doc", "docx", "rtf", "ppt", "pptx": self = .office
        default: return nil
        }
    }
}

enum Tools {
    static let binDirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    static func path(_ name: String, in dirs: [String]? = nil) -> String? {
        if name == "soffice" {
            let p = "/Applications/LibreOffice.app/Contents/MacOS/soffice"
            return FileManager.default.isExecutableFile(atPath: p) ? p : nil
        }
        for dir in dirs ?? searchDirs(for: name) {
            let p = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// Tools shipped inside Smoll.app, so a fresh Mac needs no Homebrew for images.
    static let bundledDir = helpersDir(in: Bundle.main.bundleURL)

    static func helpersDir(in app: URL) -> String? {
        let dir = app.appendingPathComponent("Contents/Helpers").path
        return FileManager.default.fileExists(atPath: dir) ? dir : nil
    }

    static func searchDirs(for name: String, bundled: String? = bundledDir) -> [String] {
        var dirs = bundled.map { [$0] } ?? []
        // mozjpeg is keg-only in Homebrew: it never lands in bin/, where cjpeg is usually plain
        // libjpeg-turbo pulled in by other formulas — same name, noticeably bigger files
        if name == "cjpeg" || name == "djpeg" {
            dirs += ["/opt/homebrew/opt/mozjpeg/bin", "/usr/local/opt/mozjpeg/bin"]
        }
        return dirs + binDirs
    }

    static func brewArgs(for tool: String) -> [String] {
        switch tool {
        case "soffice": return ["install", "--cask", "libreoffice"]
        case "cwebp": return ["install", "webp"]
        case "cjpeg", "djpeg": return ["install", "mozjpeg"]
        default: return ["install", tool]
        }
    }
}

enum CompressError: LocalizedError {
    case toolMissing(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .toolMissing(let t): return "needs \(t)"
        case .failed(let msg): return msg
        }
    }
}

enum Compressor {
    /// One whole job: compress `source`, then put the result at `destination`.
    /// `source` differs from `destination` on a re-run, which starts from the untouched original.
    static func process(_ destination: URL, from source: URL, kind: Kind, settings: Settings,
                        keepOriginal: Bool, rerun: Bool, ctx: JobContext) async throws -> (URL, Int64, URL?) {
        let produced = try await compress(source, kind: kind, settings: settings, ctx: ctx)
        // cancelled while the last step ran: the file must stay as it was
        try ctx.checkCancelled()
        // a re-run swaps the previous result in place, even when originals are kept
        return try finalize(original: destination, produced: produced, force: rerun,
                            keepOriginal: keepOriginal && !rerun)
    }

    /// Compresses/converts `url` into a file inside the job's folder. Returns nil if no gain is possible.
    static func compress(_ url: URL, kind: Kind, settings: Settings, ctx: JobContext) async throws -> URL? {
        switch kind {
        case .jpeg, .png: return try await image(url, source: kind, settings: settings, ctx: ctx)
        case .pdf: return try await pdf(url, level: settings.level, ctx: ctx)
        case .video: return try await VideoEncoder.compress(url, settings: settings, ctx: ctx)
        case .office: return try await office(url, ctx: ctx)
        }
    }

    /// Applies the result: trashes the file at `original`, moves the new file into place.
    /// Same extension + no gain -> keeps original (unless `force`, used by re-runs from the
    /// trashed original, where a bigger result is a deliberate quality choice).
    /// With `keepOriginal` the original stays untouched and the result lands next to it as
    /// "name smoll.ext"; the returned third value is then the original itself.
    /// Returns (finalURL, newSize, whereTheUntouchedOriginalSits).
    static func finalize(original: URL, produced: URL?, force: Bool = false,
                         keepOriginal: Bool = false) throws -> (URL, Int64, URL?) {
        // parallel jobs may pick the same free name ("x.jpg" and "x.png" both -> "x.heic");
        // choosing and claiming it must be one step. It's only renames, so the lock is brief.
        try finalizeLock.withLock {
            try finalizeUnlocked(original: original, produced: produced, force: force, keepOriginal: keepOriginal)
        }
    }

    private static let finalizeLock = NSLock()

    private static func finalizeUnlocked(original: URL, produced: URL?, force: Bool,
                                         keepOriginal: Bool) throws -> (URL, Int64, URL?) {
        let oldSize = fileSize(original)
        guard let produced else { return (original, oldSize, nil) }
        guard FileManager.default.fileExists(atPath: produced.path) else {
            throw CompressError.failed("no result produced")
        }
        let newSize = fileSize(produced)
        let sameExt = normExt(original) == normExt(produced)
        if !force && sameExt && newSize >= oldSize {
            try? FileManager.default.removeItem(at: produced)
            return (original, oldSize, nil)
        }
        if keepOriginal {
            let dest = freeURL(basePath: original.deletingPathExtension().path + " smoll",
                               ext: produced.pathExtension)
            try FileManager.default.moveItem(at: produced, to: dest)
            return (dest, newSize, original)
        }
        var dest = original
        if !sameExt {
            dest = freeURL(basePath: original.deletingPathExtension().path, ext: produced.pathExtension)
        }
        var trashed: NSURL?
        try FileManager.default.trashItem(at: original, resultingItemURL: &trashed)
        try FileManager.default.moveItem(at: produced, to: dest)
        return (dest, newSize, trashed as URL?)
    }

    static var replacesOriginal: Bool { UserDefaults.standard.bool(forKey: "replace") }

    static func fileSize(_ url: URL) -> Int64 {
        let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64
        return size ?? 0
    }

    /// "base.ext", or "base 2.ext", "base 3.ext"… if taken
    private static func freeURL(basePath: String, ext: String) -> URL {
        var dest = URL(fileURLWithPath: basePath).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = URL(fileURLWithPath: basePath + " \(n)").appendingPathExtension(ext)
            n += 1
        }
        return dest
    }

    private static func normExt(_ url: URL) -> String {
        let e = url.pathExtension.lowercased()
        return e == "jpeg" ? "jpg" : e
    }

    // MARK: - Images

    private enum ImgTarget: String { case jpeg, png, heif, webp }

    private static func image(_ url: URL, source: Kind, settings: Settings, ctx: JobContext) async throws -> URL? {
        let level = settings.level
        let target: ImgTarget
        switch settings.format {
        case .heif: target = .heif
        case .jpeg: target = .jpeg
        case .png: target = .png
        case .webp: target = .webp
        case .original: target = source == .jpeg ? .jpeg : .png
        }

        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Double,
              let h = props[kCGImagePropertyPixelHeight] as? Double
        else { throw CompressError.failed("can't read image") }
        let orientation = props[kCGImagePropertyOrientation] as? UInt32 ?? 1
        let metadata = CGImageSourceCopyMetadataAtIndex(src, 0, nil) // date, camera, GPS
        let (ow, oh) = orientation >= 5 ? (h, w) : (w, h) // displayed dimensions

        var scale = 1.0
        switch settings.size {
        case .maxWidth(let px) where ow > Double(px): scale = Double(px) / ow
        case .maxHeight(let px) where oh > Double(px): scale = Double(px) / oh
        default: break
        }

        // fast paths: same format, no resize, upright
        if scale == 1.0, orientation == 1 {
            // creating the CGImage here is lazy: it only reads the colour space, no pixels
            let profile = profileToEmbed(CGImageSourceCreateImageAtIndex(src, 0, nil)?.colorSpace)
            if source == .jpeg, target == .jpeg,
               let out = try? await mozjpeg(url, level: level, profile: profile, ctx: ctx) {
                return withMetadata(out, metadata, ctx: ctx)
            }
            if source == .png, target == .png { return try await pngquant(url, level: level, ctx: ctx) }
        }
        try ctx.checkCancelled()

        // general path: decode with orientation baked in and optional downscale
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: Int((max(w, h) * scale).rounded()),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw CompressError.failed("decode failed")
        }
        try ctx.checkCancelled()
        let upright = metadata.map { uprightMetadata($0, width: cg.width, height: cg.height) }

        switch target {
        case .heif:
            return try encodeImageIO(cg, type: "public.heic", ext: "heic", quality: Quality.heic(level),
                                     metadata: upright, ctx: ctx)
        case .jpeg:
            if let out = try? await cjpegEncode(cg, level: level, ctx: ctx) {
                return withMetadata(out, upright, ctx: ctx)
            }
            try ctx.checkCancelled()
            return try encodeImageIO(cg, type: UTType.jpeg.identifier, ext: "jpg",
                                     quality: Quality.jpegFallback(level), metadata: upright, ctx: ctx)
        case .png:
            let plain = try encodeImageIO(cg, type: UTType.png.identifier, ext: "png", quality: 1.0, ctx: ctx)
            // no pngquant is fine here: a plain PNG is still a valid conversion
            if let quantized = (try? await pngquant(plain, level: level, ctx: ctx)) ?? nil { return quantized }
            return plain
        case .webp:
            guard let cwebp = Tools.path("cwebp") else { throw CompressError.toolMissing("cwebp") }
            let plain = try encodeImageIO(cg, type: UTType.png.identifier, ext: "png", quality: 1.0, ctx: ctx)
            let out = ctx.file(ext: "webp")
            let status = try await ctx.run(cwebp, ["-q", Quality.webp(level), plain.path, "-o", out.path])
            guard status == 0 else { throw CompressError.failed("cwebp exit \(status)") }
            return out
        }
    }

    // mozjpeg squeezes far more than ImageIO at the same visual quality
    private static func mozjpeg(_ url: URL, level: Level, profile: Data?, ctx: JobContext) async throws -> URL {
        guard let djpeg = Tools.path("djpeg"), let cjpeg = Tools.path("cjpeg") else {
            throw CompressError.failed("mozjpeg not installed")
        }
        let out = ctx.file(ext: "jpg")
        let args = try cjpegArgs(level: level, profile: profile, out: out, ctx: ctx)
        let (d, e) = try await ctx.runPipe((djpeg, [url.path]), into: (cjpeg, args))
        guard d == 0, e == 0, fileSize(out) > 0 else { throw CompressError.failed("mozjpeg failed") }
        return out
    }

    // CGImage -> PPM file -> cjpeg, so resized/converted jpegs get mozjpeg quality too
    private static func cjpegEncode(_ img: CGImage, level: Level, ctx: JobContext) async throws -> URL {
        guard let cjpeg = Tools.path("cjpeg") else { throw CompressError.failed("no cjpeg") }
        // keep wide-gamut pixels as they are instead of squeezing them into sRGB
        var space = CGColorSpace(name: CGColorSpace.sRGB)!
        if let own = img.colorSpace, own.model == .rgb, own.supportsOutput { space = own }
        let ppm = ctx.file(ext: "ppm")
        try writePPM(img, to: ppm, space: space)
        let out = ctx.file(ext: "jpg")
        let args = try cjpegArgs(level: level, profile: profileToEmbed(space), out: out, ctx: ctx)
        let status = try await ctx.run(cjpeg, args + [ppm.path])
        try? FileManager.default.removeItem(at: ppm)
        guard status == 0, fileSize(out) > 0 else { throw CompressError.failed("cjpeg exit \(status)") }
        return out
    }

    private static func cjpegArgs(level: Level, profile: Data?, out: URL, ctx: JobContext) throws -> [String] {
        var args = ["-quality", Quality.jpegMoz(level), "-optimize", "-outfile", out.path]
        if let profile {
            let icc = ctx.file(ext: "icc")
            try profile.write(to: icc)
            args += ["-icc", icc.path]
        }
        return args
    }

    /// sRGB is what viewers assume anyway; anything wider (iPhone's Display P3) must travel
    /// with the file, or its colours come out dull.
    static func profileToEmbed(_ space: CGColorSpace?) -> Data? {
        guard let space, space.model == .rgb, let name = space.name as String?,
              name != CGColorSpace.sRGB as String, name != CGColorSpace.genericRGBLinear as String
        else { return nil }
        return space.copyICCData() as Data?
    }

    /// Orientation is baked into the pixels and the size may have changed; the tags must agree.
    private static func uprightMetadata(_ metadata: CGImageMetadata, width: Int, height: Int) -> CGImageMetadata {
        guard let copy = CGImageMetadataCreateMutableCopy(metadata) else { return metadata }
        CGImageMetadataSetValueMatchingImageProperty(copy, kCGImagePropertyTIFFDictionary,
                                                     kCGImagePropertyTIFFOrientation, 1 as CFNumber)
        CGImageMetadataSetValueMatchingImageProperty(copy, kCGImagePropertyExifDictionary,
                                                     kCGImagePropertyExifPixelXDimension, width as CFNumber)
        CGImageMetadataSetValueMatchingImageProperty(copy, kCGImagePropertyExifDictionary,
                                                     kCGImagePropertyExifPixelYDimension, height as CFNumber)
        return copy
    }

    /// Puts EXIF/GPS/XMP back onto a JPEG from cjpeg (which drops them) without re-encoding pixels.
    /// Losing metadata is a pity, not a failure, so any problem returns the bare file.
    private static func withMetadata(_ jpeg: URL, _ metadata: CGImageMetadata?, ctx: JobContext) -> URL {
        guard let metadata,
              let src = CGImageSourceCreateWithURL(jpeg as CFURL, nil) else { return jpeg }
        let out = ctx.file(ext: "jpg")
        guard let dst = CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return jpeg }
        let opts: [CFString: Any] = [kCGImageDestinationMetadata: metadata,
                                     kCGImageDestinationMergeMetadata: false]
        guard CGImageDestinationCopyImageSource(dst, src, opts as CFDictionary, nil) else { return jpeg }
        try? FileManager.default.removeItem(at: jpeg)
        return out
    }

    /// Binary PPM, written row by row so a big photo doesn't need a second full-size buffer.
    static func writePPM(_ img: CGImage, to url: URL,
                         space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) throws {
        let w = img.width, h = img.height
        guard let bitmap = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                     bytesPerRow: w * 4, space: space,
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw CompressError.failed("context failed") }
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1)) // flatten transparency to white
        bitmap.fill(CGRect(x: 0, y: 0, width: w, height: h))
        bitmap.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let buf = bitmap.data else { throw CompressError.failed("no pixel data") }

        guard FileManager.default.createFile(atPath: url.path, contents: Data("P6\n\(w) \(h)\n255\n".utf8)) else {
            throw CompressError.failed("can't write \(url.lastPathComponent)")
        }
        let out = try FileHandle(forWritingTo: url)
        defer { try? out.close() }
        try out.seekToEnd()
        let pixels = buf.assumingMemoryBound(to: UInt8.self)
        var row = [UInt8](repeating: 0, count: w * 3)
        for y in 0..<h {
            let line = pixels + y * bitmap.bytesPerRow
            for x in 0..<w {
                row[x * 3] = line[x * 4]
                row[x * 3 + 1] = line[x * 4 + 1]
                row[x * 3 + 2] = line[x * 4 + 2]
            }
            try out.write(contentsOf: row)
        }
    }

    private static func encodeImageIO(_ img: CGImage, type: String, ext: String, quality: Double,
                                      metadata: CGImageMetadata? = nil, ctx: JobContext) throws -> URL {
        let out = ctx.file(ext: ext)
        guard let dst = CGImageDestinationCreateWithURL(out as CFURL, type as CFString, 1, nil) else {
            throw CompressError.failed("can't encode \(ext)")
        }
        let opts = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        if let metadata {
            CGImageDestinationAddImageAndMetadata(dst, img, metadata, opts)
        } else {
            CGImageDestinationAddImage(dst, img, opts)
        }
        guard CGImageDestinationFinalize(dst) else { throw CompressError.failed("\(ext) encode failed") }
        return out
    }

    /// nil = pngquant found no gain within the quality range
    private static func pngquant(_ url: URL, level: Level, ctx: JobContext) async throws -> URL? {
        guard let tool = Tools.path("pngquant") else { throw CompressError.toolMissing("pngquant") }
        let out = ctx.file(ext: "png")
        let status = try await ctx.run(tool, ["--force", "--skip-if-larger", "--strip",
                                              "--quality", Quality.pngRange(level), "--speed", "1",
                                              "--output", out.path, "--", url.path])
        if status == 98 || status == 99 { return nil }
        guard status == 0 else { throw CompressError.failed("pngquant exit \(status)") }
        return out
    }

    // MARK: - Other formats

    private static func pdf(_ url: URL, level: Level, ctx: JobContext) async throws -> URL? {
        guard let tool = Tools.path("gs") else { throw CompressError.toolMissing("gs") }
        let out = ctx.file(ext: "pdf")
        let res = Quality.pdfResolution(level)
        // PassThroughJPEGImages=false: without it gs copies existing JPEGs verbatim and barely shrinks anything
        // /printer (not /ebook): gentler JPEG re-encode, keeps screenshots/text in images readable
        let status = try await ctx.run(tool, ["-sDEVICE=pdfwrite", "-dCompatibilityLevel=1.5",
                                              "-dPDFSETTINGS=/printer",
                                              "-dPassThroughJPEGImages=false",
                                              "-dPassThroughJPXImages=false",
                                              "-dColorImageResolution=\(res)",
                                              "-dGrayImageResolution=\(res)",
                                              "-dDetectDuplicateImages=true",
                                              "-dNOPAUSE", "-dQUIET", "-dBATCH",
                                              "-o", out.path, url.path])
        guard status == 0 else { throw CompressError.failed("ghostscript exit \(status)") }
        return out
    }

    private static func office(_ url: URL, ctx: JobContext) async throws -> URL? {
        guard let tool = Tools.path("soffice") else { throw CompressError.toolMissing("soffice") }
        let outDir = ctx.file(ext: "office")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        // unique profile so it works even when LibreOffice is open, and in parallel
        let profile = "file://\(outDir.path)/profile"
        let status = try await ctx.run(tool, ["--headless", "-env:UserInstallation=\(profile)",
                                              "--convert-to", "pdf", "--outdir", outDir.path, url.path])
        let produced = outDir.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".pdf")
        guard status == 0, FileManager.default.fileExists(atPath: produced.path) else {
            throw CompressError.failed("libreoffice exit \(status)")
        }
        return produced
    }

    static func audioIsCopyable(_ url: URL) async throws -> Bool {
        guard let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).first else { return false }
        return try await VideoEncoder.audioIsCopyable(track)
    }
}
