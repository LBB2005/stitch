import AppKit
import SwiftUI

/// Colors from the Direction A mockup, as light/dark pairs of system white/black at set opacities.
enum Theme {
    static let padding: CGFloat = 12
    static let well = dynamic(light: NSColor.white.withAlphaComponent(0.72), dark: NSColor.white.withAlphaComponent(0.065))
    static let button = dynamic(light: NSColor.white, dark: NSColor.white.withAlphaComponent(0.13))
    static let hover = dynamic(light: NSColor.black.withAlphaComponent(0.05), dark: NSColor.white.withAlphaComponent(0.07))
    static let cell = dynamic(light: NSColor.black.withAlphaComponent(0.035), dark: NSColor.white.withAlphaComponent(0.05))
    static let disabledFill = dynamic(light: NSColor.black.withAlphaComponent(0.04), dark: NSColor.white.withAlphaComponent(0.05))
    static let hairline = dynamic(light: NSColor.black.withAlphaComponent(0.16), dark: NSColor.white.withAlphaComponent(0.06))
    static let separator = Color(nsColor: .separatorColor)

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

// MARK: layout pieces

/// Rounded inset group, like the sections of Control Center.
struct Well<Content: View>: View {
    var padding: CGFloat = 4
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(Theme.well, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct WellDivider: View {
    var body: some View {
        Rectangle().fill(Theme.separator).frame(height: 0.5).padding(.leading, 36)
    }
}

/// Title row at the top of each screen.
struct PanelHeader<Leading: View, Trailing: View>: View {
    var title: String
    var detail: String?
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            leading
            Text(title).font(.system(size: 13, weight: .semibold))
            if let detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            trailing
        }
        .padding(.horizontal, 2)
        .frame(height: 24)
    }
}

extension PanelHeader where Leading == EmptyView {
    init(title: String, detail: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.init(title: title, detail: detail, leading: { EmptyView() }, trailing: trailing)
    }
}

/// A 24 pt borderless SF Symbol button that highlights on hover.
struct IconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(hovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: buttons

/// Accent-filled, white text: the one main action on each screen.
struct PrimaryButtonStyle: ButtonStyle {
    var height: CGFloat = 32
    var fullWidth = true

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, height: height, fullWidth: fullWidth, primary: true)
    }
}

/// White (light) or translucent (dark) fill with a hairline edge.
struct SecondaryButtonStyle: ButtonStyle {
    var height: CGFloat = 28
    var fullWidth = true

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, height: height, fullWidth: fullWidth, primary: false)
    }
}

private struct StyledButton: View {
    let configuration: ButtonStyleConfiguration
    let height: CGFloat
    let fullWidth: Bool
    let primary: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: height > 30 ? 8 : 7, style: .continuous)
        configuration.label
            .font(.system(size: primary ? 13 : 12.5, weight: primary ? .semibold : .regular))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: height)
            .background(fill, in: shape)
            .overlay(shape.strokeBorder(primary || !isEnabled ? .clear : Theme.hairline, lineWidth: 0.5))
            .shadow(color: .black.opacity(primary || !isEnabled ? 0 : 0.07), radius: 0.75, y: 0.5)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(shape)
    }

    private var fill: Color {
        guard isEnabled else { return Theme.disabledFill }
        return primary ? .accentColor : Theme.button
    }

    private var foreground: Color {
        guard isEnabled else { return Color(nsColor: .tertiaryLabelColor) }
        return primary ? .white : .primary
    }
}

/// A text-only accent link ("Save to…", "Use order added").
struct LinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(Color.accentColor)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

// MARK: options

/// A row in the options well: icon, title, optional caption (with an accessory at its end), switch.
struct OptionRow<Accessory: View>: View {
    let symbol: String
    let title: String
    var caption: String?
    @Binding var isOn: Bool
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13)).lineLimit(1)
                if let caption {
                    HStack(spacing: 3) {
                        Text(caption).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        accessory
                    }
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 6)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, caption == nil ? 9 : 7)
    }
}

extension OptionRow where Accessory == EmptyView {
    init(symbol: String, title: String, caption: String? = nil, isOn: Binding<Bool>) {
        self.init(symbol: symbol, title: title, caption: caption, isOn: isOn, accessory: { EmptyView() })
    }
}

/// "30 MB ▾": pick the upload size target.
struct TargetMenu: View {
    @Environment(Preferences.self) private var prefs

    var body: some View {
        Menu {
            ForEach(Preferences.targetChoices, id: \.self) { mb in
                Button { prefs.targetMB = mb } label: {
                    if mb == prefs.targetMB { Label("\(mb) MB", systemImage: "checkmark") } else { Text("\(mb) MB") }
                }
            }
        } label: {
            Text("\(prefs.targetMB) MB").font(.system(size: 11, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Upload size limit")
    }
}

/// "Downloads ▾": where this job saves.
struct FolderMenu: View {
    let current: URL
    let onPick: (URL?) -> Void
    let onChoose: () -> Void

    var body: some View {
        Menu {
            ForEach(Self.places, id: \.self) { url in
                Button { onPick(url) } label: { Label(name(url), systemImage: symbol(url)) }
            }
            Divider()
            Button("Other Folder…", action: onChoose)
        } label: {
            Label(name(current), systemImage: symbol(current)).font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    static var places: [URL] {
        [FileManager.SearchPathDirectory.downloadsDirectory, .desktopDirectory, .documentDirectory]
            .compactMap { FileManager.default.urls(for: $0, in: .userDomainMask).first }
    }

    private func name(_ url: URL) -> String { FileManager.default.displayName(atPath: url.path) }

    private func symbol(_ url: URL) -> String {
        switch url.lastPathComponent {
        case "Downloads": "arrow.down.circle"
        case "Desktop": "menubar.dock.rectangle"
        case "Documents": "doc"
        default: "folder"
        }
    }
}

// MARK: thumbnails

/// A file's Finder-style thumbnail, falling back to its icon.
struct FileThumbView: View {
    let url: URL
    var side: CGFloat = 28
    @State private var image: NSImage?
    @Environment(\.displayScale) private var scale

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit()
            }
        }
        .frame(width: side, height: side)
        .task(id: url) {
            if let thumb = await FileThumbnail.load(url, side: side, scale: scale) {
                image = NSImage(cgImage: thumb.cgImage, size: NSSize(width: side, height: side))
            }
        }
    }
}
