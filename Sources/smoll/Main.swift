import SwiftUI

@main
enum Main {
    static func main() {
        UserDefaults.standard.register(defaults: Level.defaultsKeys)
        let args = CommandLine.arguments
        if args.contains("--cli") {
            cli(files: args.dropFirst().filter { $0 != "--cli" })
            return
        }
        SmollApp.main()
    }

    // headless mode: doubles as the runnable self-check
    static func cli(files: [String]) {
        Task.detached {
            let failed = await cliRun(files: files)
            exit(failed ? 1 : 0)
        }
        dispatchMain()
    }

    private static func cliRun(files: [String]) async -> Bool {
        var failed = false
        for path in files {
            let url = URL(fileURLWithPath: path)
            guard let kind = Kind(url: url) else { print("\(path): unsupported"); failed = true; continue }
            let oldSize = Compressor.fileSize(url)
            do {
                let ctx = try JobContext(near: url)
                defer { ctx.cleanup() }
                let (dest, newSize, _) = try await Compressor.process(
                    url, from: url, kind: kind, settings: Settings.load(),
                    keepOriginal: !Compressor.replacesOriginal, rerun: false, ctx: ctx)
                let ratio = oldSize > 0 ? Int((1.0 - Double(newSize) / Double(oldSize)) * 100) : 0
                print("\(dest.lastPathComponent): \(oldSize) -> \(newSize) (-\(ratio)%)")
            } catch {
                print("\(path): FAILED \(error.localizedDescription)")
                failed = true
            }
        }
        return failed
    }
}

struct SmollApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Window("Smoll", id: "main") {
            ContentView()
        }
        .defaultSize(width: 560, height: 480)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unifiedCompact)

        SwiftUI.Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        JobStore.shared.add(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // closing the app means "stop": no orphaned Ghostscript or LibreOffice working into the void
    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        JobStore.shared.cancelAll()
    }

    // "Make smoll" / "Convert to PDF" services from Finder's context menu
    @MainActor
    @objc func makeSmoll(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let urls = pboard.readObjects(forClasses: [NSURL.self]) as? [URL] else { return }
        JobStore.shared.add(urls)
    }

    @MainActor
    @objc func convertToPDF(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        makeSmoll(pboard, userData: userData, error: error)
    }
}
