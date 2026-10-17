import Foundation

/// What a job is compressed with. Read once when the job starts, so changing settings
/// mid-job can't mix two configurations in one file.
struct Settings: Equatable {
    enum Size: Equatable {
        case original
        case maxWidth(Int)
        case maxHeight(Int)
    }

    enum Format: String {
        case original, heif, jpeg, png, webp
    }

    var level: Level = .medium
    var size: Size = .original
    var format: Format = .original

    static func load(from d: UserDefaults = .standard) -> Settings {
        var px = Int(d.double(forKey: "size.px"))
        if px <= 0 { px = 1024 }
        let size: Size
        switch Int(d.double(forKey: "size.mode")) {
        case 1: size = .maxWidth(px)
        case 2: size = .maxHeight(px)
        default: size = .original
        }
        return Settings(level: Level(rawValue: Int(d.double(forKey: "level"))) ?? .medium,
                        size: size,
                        format: Format(rawValue: d.string(forKey: "format") ?? "") ?? .original)
    }
}
