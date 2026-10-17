import XCTest
@testable import smoll

final class SettingsTests: XCTestCase {
    private func defaults(_ values: [String: Any]) -> UserDefaults {
        let name = "smoll-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        d.register(defaults: Level.defaultsKeys)
        for (key, value) in values { d.set(value, forKey: key) }
        return d
    }

    func testDefaultsAreMediumOriginalSizeOriginalFormat() {
        let s = Settings.load(from: defaults([:]))

        XCTAssertEqual(s, Settings(level: .medium, size: .original, format: .original))
    }

    func testMaxWidthWithoutPixelsFallsBackTo1024() {
        let s = Settings.load(from: defaults(["size.mode": 1.0, "size.px": 0.0]))

        XCTAssertEqual(s.size, .maxWidth(1024))
    }

    func testMaxHeightUsesGivenPixels() {
        let s = Settings.load(from: defaults(["size.mode": 2.0, "size.px": 800.0]))

        XCTAssertEqual(s.size, .maxHeight(800))
    }

    func testLevelAndFormatAreRead() {
        let s = Settings.load(from: defaults(["level": 3.0, "format": "webp"]))

        XCTAssertEqual(s.level, .extreme)
        XCTAssertEqual(s.format, .webp)
    }

    func testUnknownFormatMeansOriginal() {
        XCTAssertEqual(Settings.load(from: defaults(["format": "bmp"])).format, .original)
    }

    // pixels only matter when a size limit is on, so changing them alone shouldn't ask for a re-run
    func testPixelsAreIgnoredForOriginalSize() {
        let a = Settings.load(from: defaults(["size.mode": 0.0, "size.px": 500.0]))
        let b = Settings.load(from: defaults(["size.mode": 0.0, "size.px": 900.0]))

        XCTAssertEqual(a, b)
    }
}
