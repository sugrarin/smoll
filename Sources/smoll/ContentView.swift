import SwiftUI
import QuickLook
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var store = JobStore.shared
    @State private var dropTargeted = false
    @State private var selection = Set<Job.ID>()
    @State private var previewURL: URL?
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            if !store.missingTools.isEmpty { toolBanner }
            table
        }
        .frame(minWidth: 560, minHeight: 480)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { handleDrop($0) }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(6)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if store.settingsDirty && !store.jobs.isEmpty {
                    Button {
                        store.rerunAll()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Re-run files with the new settings")
                }
                Button {
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
            }
        }
    }

    private var table: some View {
        Table(store.jobs, selection: $selection) {
            TableColumn("File") { job in
                HStack(spacing: 8) {
                    Image(nsImage: job.thumbnail ?? NSImage())
                        .resizable().scaledToFit().frame(width: 24, height: 24)
                    Text(job.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                }
            }
            TableColumn("Size") { job in
                Text(fmt(job.oldSize)).monospacedDigit()
            }.width(72)
            TableColumn("New size") { job in
                switch job.state {
                case .pending:
                    Text("waiting")
                case .running:
                    ProgressView().controlSize(.small)
                case .done(let newSize):
                    Text(fmt(newSize)).monospacedDigit()
                case .needsTool(let t):
                    Text("needs \(t)").lineLimit(1).help("needs \(t)")
                case .failed(let msg):
                    Text(msg).lineLimit(1).help(msg)
                case .unsupported:
                    Text("unsupported")
                }
            }.width(72)
            TableColumn("Ratio") { job in
                if let r = job.ratio {
                    Text(r <= 0.001 ? "—" : String(format: "-%.0f%%", r * 100))
                        .monospacedDigit()
                } else {
                    Text("")
                }
            }.width(62)
        }
        .contextMenu(forSelectionType: Job.ID.self) { ids in
            if !ids.isEmpty {
                Button("Open") { open(ids) }
                Button("Show in Finder") { showInFinder(ids) }
                Button("Re-run") { store.rerun(ids) }
                Divider()
                Button("Remove from list") { store.remove(ids) }
            }
        } primaryAction: { ids in
            open(ids)
        }
        .background(DisableHorizontalBounce())
        .onDeleteCommand { store.remove(selection) }
        .onKeyPress(.space) {
            if let id = selection.first, let job = store.jobs.first(where: { $0.id == id }) {
                previewURL = job.url
                return .handled
            }
            return .ignored
        }
        .quickLookPreview($previewURL, in: store.jobs.map(\.url))
    }

    private var toolBanner: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("Missing: \(store.missingTools.joined(separator: ", "))")
            Spacer()
            if let tool = store.installingTool {
                ProgressView().controlSize(.small)
                Text("Installing \(tool)…")
            } else if Tools.path("brew") != nil {
                if let tool = store.failedInstall {
                    Text("Couldn't install \(tool)").foregroundStyle(.secondary)
                }
                Button(store.failedInstall == nil ? "Install via Homebrew" : "Try again") {
                    store.installMissingTools()
                }
            } else {
                Text("Install Homebrew first: brew.sh").textSelection(.enabled)
            }
        }
        .padding(10)
        .background(.orange.opacity(0.12))
    }

    private func open(_ ids: Set<Job.ID>) {
        for id in ids {
            if let job = store.jobs.first(where: { $0.id == id }) {
                NSWorkspace.shared.open(job.url)
            }
        }
    }

    private func showInFinder(_ ids: Set<Job.ID>) {
        let urls = store.jobs.filter { ids.contains($0.id) }.map(\.url)
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in JobStore.shared.add([url]) } }
            }
        }
        return true
    }

    private func fmt(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// SwiftUI Table is an NSTableView in an NSScrollView with horizontal rubber-banding on;
// Finder-like behavior needs it off, and there's no SwiftUI API — so we reach in.
// The walk runs until the table is found once, not on every table update.
private struct DisableHorizontalBounce: NSViewRepresentable {
    final class Coordinator { var done = false }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ probe: NSView, context: Context) {
        guard !context.coordinator.done else { return }
        DispatchQueue.main.async { context.coordinator.done = fix(around: probe) }
    }

    private func fix(around probe: NSView) -> Bool {
        guard let root = probe.window?.contentView else { return false }
        var found = false
        var stack: [NSView] = [root]
        while let v = stack.popLast() {
            if let scroll = v as? NSScrollView, scroll.documentView is NSTableView {
                scroll.horizontalScrollElasticity = .none
                found = true
            }
            stack.append(contentsOf: v.subviews)
        }
        return found
    }
}
