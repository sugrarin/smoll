import XCTest
@testable import smoll

final class LevelTests: XCTestCase {
    func testQualityLabelShowsJpegQualityAndPdfResolution() {
        XCTAssertEqual(Level.normal.qualityLabel, "85% quality · PDF 300 dpi")
        XCTAssertEqual(Level.medium.qualityLabel, "78% quality · PDF 220 dpi")
        XCTAssertEqual(Level.strong.qualityLabel, "65% quality · PDF 160 dpi")
        XCTAssertEqual(Level.extreme.qualityLabel, "50% quality · PDF 120 dpi")
    }

    func testHintDescribesTheTradeOff() {
        XCTAssertEqual(Level.normal.hint, "Barely noticeable loss")
        XCTAssertEqual(Level.medium.hint, "Balance of size and quality")
        XCTAssertEqual(Level.strong.hint, "Loss visible when zoomed in")
        XCTAssertEqual(Level.extreme.hint, "Smallest files, clear loss")
    }

    func testReplaceOriginalIsOnByDefault() {
        XCTAssertEqual(Level.defaultsKeys["replace"] as? Bool, true)
    }
}
