import SwiftUI

struct SettingsView: View {
    @AppStorage("size.mode") private var sizeMode = 0.0
    @AppStorage("size.px") private var sizePx = 0.0
    @AppStorage("format") private var format = "original"
    @AppStorage("level") private var level = 1.0
    @AppStorage("replace") private var replace = true

    private var selectedLevel: Level { Level(rawValue: Int(level)) ?? .medium }

    // 0 = unset, shows the "1024" placeholder; engine falls back to 1024
    private var pxBinding: Binding<Double?> {
        Binding(get: { sizePx == 0 ? nil : sizePx }, set: { sizePx = $0 ?? 0 })
    }

    private var supportLink: some View {
        HStack(spacing: 4) {
            Text("Support me:").foregroundStyle(.secondary)
            Link("ko-fi.com/sugrarin", destination: URL(string: "https://ko-fi.com/sugrarin")!)
        }
        .font(.caption)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsGrid
            supportLink
        }
        .padding(20)
    }

    private var settingsGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 12) {
            GridRow {
                Text("Size")
                HStack(spacing: 6) {
                    Picker("", selection: $sizeMode) {
                        Text("Original").tag(0.0)
                        Text("Max width").tag(1.0)
                        Text("Max height").tag(2.0)
                    }
                    .labelsHidden()
                    .fixedSize()
                    TextField("", value: pxBinding, format: .number.grouping(.never), prompt: Text("1024"))
                        .frame(width: 64)
                        .multilineTextAlignment(.trailing)
                        .disabled(sizeMode == 0.0)
                    Text("px")
                }
            }
            GridRow {
                Text("Format")
                Picker("", selection: $format) {
                    Text("Original").tag("original")
                    Text("HEIF").tag("heif")
                    Text("JPEG").tag("jpeg")
                    Text("PNG").tag("png")
                    Text("WEBP").tag("webp")
                }
                .labelsHidden()
                .fixedSize()
            }
            GridRow(alignment: .top) {
                Text("Original")
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Replace original file", isOn: $replace)
                    Text(replace ? "The original goes to the Trash."
                                 : "The original stays; the result is saved as “name smoll”.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            GridRow(alignment: .top) {
                Text("Compression")
                VStack(alignment: .leading, spacing: 4) {
                    Slider(value: $level, in: 0...3, step: 1)
                    HStack {
                        Text("Normal")
                        Spacer()
                        Text("Medium")
                        Spacer()
                        Text("Strong")
                        Spacer()
                        Text("Extreme")
                    }
                    .font(.caption)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selectedLevel.qualityLabel)
                        Text(selectedLevel.hint)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                }
                .frame(width: 280)
            }
        }
    }
}
