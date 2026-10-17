import XCTest
@testable import smoll

final class ToolsTests: XCTestCase {
    // mozjpeg is keg-only in Homebrew, while bin/cjpeg is usually plain libjpeg-turbo
    func testJpegToolsLookInMozjpegKegFirst() {
        let dirs = Tools.searchDirs(for: "cjpeg", bundled: nil)

        XCTAssertEqual(Array(dirs.prefix(2)), ["/opt/homebrew/opt/mozjpeg/bin", "/usr/local/opt/mozjpeg/bin"])
        XCTAssertEqual(Tools.searchDirs(for: "djpeg", bundled: nil), dirs)
    }

    func testOtherToolsUseRegularBinDirs() {
        XCTAssertEqual(Tools.searchDirs(for: "pngquant", bundled: nil), Tools.binDirs)
    }

    func testFirstDirectoryWithTheToolWins() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("smoll-tests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        for dir in [first, second] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let tool = second.appendingPathComponent("cjpeg")
        FileManager.default.createFile(atPath: tool.path, contents: Data(), attributes: [.posixPermissions: 0o755])

        XCTAssertEqual(Tools.path("cjpeg", in: [first.path, second.path]), tool.path)
        XCTAssertNil(Tools.path("djpeg", in: [first.path, second.path]))
    }

    // MARK: - Tools shipped inside the app

    func testBundledToolsComeFirst() {
        XCTAssertEqual(Tools.searchDirs(for: "pngquant", bundled: "/A/Contents/Helpers").first, "/A/Contents/Helpers")
        XCTAssertEqual(Tools.searchDirs(for: "cjpeg", bundled: "/A/Contents/Helpers").first, "/A/Contents/Helpers")
    }

    func testHelpersDirIsFoundOnlyWhenTheAppHasOne() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("smoll-tests-\(UUID().uuidString).app")
        addTeardownBlock { try? FileManager.default.removeItem(at: app) }
        XCTAssertNil(Tools.helpersDir(in: app))

        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Helpers"),
                                                withIntermediateDirectories: true)

        XCTAssertEqual(Tools.helpersDir(in: app), app.appendingPathComponent("Contents/Helpers").path)
    }
}
