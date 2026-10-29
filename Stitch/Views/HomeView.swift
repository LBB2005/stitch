import SwiftUI
import UniformTypeIdentifiers

/// Screen 1 (empty: drop zone) and screen 2 (files loaded: list, options, name, actions).
struct HomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.files.isEmpty {
                EmptyHome()
            } else {
                FilesHome()
            }
        }
        .padding(Theme.padding)
        .onDrop(of: [.fileURL], delegate: FileDropDelegate(model: model))
    }
}

struct FileDropDelegate: DropDelegate {
    let model: AppModel

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL]) }
    func dropEntered(info: DropInfo) { model.dropHover = info.itemProviders(for: [.fileURL]).count }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .copy) }
    func dropExited(info: DropInfo) { model.dropHover = nil }

    func performDrop(info: DropInfo) -> Bool {
        model.dropHover = nil
        model.add(info.itemProviders(for: [.fileURL]))
        return true
    }
}

// MARK: empty

private struct EmptyHome: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 10) {
            PanelHeader(title: "Stitch") {
                IconButton(symbol: "gearshape", label: "Settings") { model.openSettings() }
            }
            if let banner = model.banner { BannerView(banner: banner) }
            DropZone(count: model.dropHover)
            Button("Choose Files…") { model.chooseFiles() }
                .buttonStyle(SecondaryButtonStyle())
            HStack(spacing: 6) {
                Image(systemName: "folder")
                Text("Saves to \(model.destinationName)")
                Spacer()
                if let toast = model.toast { Text(toast).foregroundStyle(.orange) }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 2)
        }
    }
}

struct DropZone: View {
    let count: Int?
    /// Fill the space given (the overlay on a loaded list) instead of the empty screen's 236 pt.
    var fills = false

    var body: some View {
        let active = count != nil
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(spacing: 8) {
            Image(systemName: active ? "arrow.down.doc.fill" : "doc.on.doc")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(active ? Color.accentColor : .secondary)
                .symbolEffect(.bounce, value: active)
                .frame(height: 38)
            Text(active ? releaseText : "Drop files here")
                .font(.system(size: 15, weight: .semibold))
            Text("PDF · HEIC · JPEG · PNG · Word · PowerPoint")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: fills ? nil : 236)
        .frame(maxHeight: fills ? .infinity : nil)
        .background(active ? Color.accentColor.opacity(0.1) : Color.clear, in: shape)
        .overlay(shape.strokeBorder(active ? Color.accentColor : Color.secondary.opacity(0.35),
                                    style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
        .animation(.easeOut(duration: 0.15), value: active)
    }

    private var releaseText: String {
        let n = count ?? 0
        return n == 1 ? "Release to add 1 file" : "Release to add \(n) files"
    }
}

// MARK: files loaded

private struct FilesHome: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var prefs

    var body: some View {
        @Bindable var prefs = prefs
        VStack(spacing: 10) {
            PanelHeader(title: "Stitch", detail: summary) {
                IconButton(symbol: "plus", label: "Add Files") { model.chooseFiles() }
                IconButton(symbol: "gearshape", label: "Settings") { model.openSettings() }
            }
            if let banner = model.banner { BannerView(banner: banner) }
            FileList()
            Well(padding: 0) {
                VStack(spacing: 0) {
                    OptionRow(symbol: "text.viewfinder", title: "Make scans searchable", isOn: $prefs.ocr)
                    WellDivider()
                    OptionRow(symbol: "arrow.down.right.and.arrow.up.left", title: "Shrink to fit upload limit",
                              caption: model.shrinkCaption, isOn: $prefs.shrink) {
                        TargetMenu()
                    }
                    if model.imageCount >= 2 {
                        WellDivider()
                        OptionRow(symbol: "photo.stack", title: "One PDF for all images", caption: "For Convert to PDF",
                                  isOn: $prefs.combineImages)
                    }
                }
            }
            OutputNameBlock()
            VStack(spacing: 8) {
                Button { model.startMerge() } label: {
                    Label("Merge to PDF", systemImage: "doc.on.doc.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!model.canMerge)
                .help(model.canMerge ? "Arrange the pages, then merge into one PDF" : "Install LibreOffice to merge Word and PowerPoint files")
                HStack(spacing: 8) {
                    Button("Convert to PDF") { model.convertToPDF() }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(!model.canConvertToPDF)
                        .help(model.canConvertToPDF
                              ? (prefs.combineImages || model.imageCount == 1 ? "Images into one PDF" : "Each image becomes its own PDF")
                              : "Add images to convert")
                    Button("Convert to JPEG") { model.convertToJPEG() }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(!model.canConvertToJPEG)
                        .help(model.canConvertToJPEG ? "Each image becomes a JPEG" : "Add HEIC, PNG or other non-JPEG images")
                }
            }
        }
        .overlay {
            if let count = model.dropHover {
                DropZone(count: count, fills: true)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.dropHover != nil)
    }

    private var summary: String {
        let n = model.files.count
        return "\(n) file\(n == 1 ? "" : "s") · \(ByteSize.string(model.totalBytes))"
    }
}

private struct FileList: View {
    @Environment(AppModel.self) private var model
    private let rowHeight: CGFloat = 40
    private let visibleRows = 5

    var body: some View {
        let files = model.orderedFiles
        VStack(alignment: .leading, spacing: 6) {
            Well {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(files) { FileRow(file: $0) }
                    }
                }
                .scrollDisabled(files.count <= visibleRows)
                .frame(height: CGFloat(min(files.count, visibleRows)) * rowHeight + (files.count > visibleRows ? rowHeight / 2 : 0))
            }
            if model.series != nil || model.toast != nil {
                HStack(spacing: 4) {
                    if model.series != nil { OrderSwitch() }
                    Spacer()
                    if let toast = model.toast { Text(toast).foregroundStyle(.orange) }
                }
                .font(.system(size: 11))
                .padding(.horizontal, 2)
            }
        }
    }
}

/// "Sorted by lecture number · Use order added", with a one-click switch back and forth.
struct OrderSwitch: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.up.arrow.down").foregroundStyle(.secondary)
            Text(model.orderLabel).foregroundStyle(.secondary)
            if let series = model.series {
                Text("·").foregroundStyle(.tertiary)
                Button(model.orderMode == .smart ? "Use order added" : series.label.replacingOccurrences(of: "Sorted", with: "Sort")) {
                    model.setOrderMode(model.orderMode == .smart ? .added : .smart)
                }
                .buttonStyle(LinkButtonStyle())
                .font(.system(size: 11))
            }
        }
        .font(.system(size: 11))
        .lineLimit(1)
    }
}

private struct FileRow: View {
    let file: InputFile
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            FileThumbView(url: file.url, side: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(meta.text)
                    .font(.system(size: 11))
                    .foregroundStyle(meta.warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button { model.remove(file) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 0.85 : 0.35)
            .help("Remove from list (the file isn't touched)")
            .accessibilityLabel("Remove \(file.name)")
        }
        .padding(.horizontal, 6)
        .frame(height: 40)
        .background(hovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { hovering = $0 }
    }

    private var meta: (text: String, warning: Bool) {
        let size = ByteSize.string(file.bytes)
        if let reason = model.skipped[file.id], let open = reason.lastIndex(of: "(") {
            return (String(reason[open...]).trimmingCharacters(in: CharacterSet(charactersIn: "()")).capitalizedFirst, true)
        }
        switch file.kind {
        case .pdf:
            let n = file.pageCount ?? 0
            return ("\(size) · \(n) page\(n == 1 ? "" : "s")", false)
        case .image:
            return ("\(size) · \(file.url.pathExtension.uppercased()) image", false)
        case .word, .powerpoint:
            let app = file.kind == .word ? "Word" : "PowerPoint"
            return OfficeConverter.isInstalled ? ("\(size) · \(app)", false) : ("\(app) · needs LibreOffice", true)
        }
    }
}

/// Name field and save location, right above the action buttons.
struct OutputNameBlock: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 4) {
                Text("File name").font(.system(size: 11)).foregroundStyle(.secondary)
                FileNameField(text: model.outputName, focusToken: model.focusToken,
                              onChange: { model.setName($0) },
                              onSubmit: { model.screen == .arrange ? model.merge() : model.startMerge() })
                    .frame(height: 22)
            }
            HStack(spacing: 6) {
                Text("Save to").font(.system(size: 12)).foregroundStyle(.secondary)
                FolderMenu(current: model.destination, onPick: { model.useFolder($0) },
                           onChoose: { model.chooseFolder(asDefault: false) })
                Spacer()
                Button("Save to…") { model.chooseSaveLocation() }
                    .buttonStyle(LinkButtonStyle())
                    .help("Choose a name and folder for this one")
            }
        }
        .padding(.horizontal, 2)
    }
}

struct BannerView: View {
    let banner: AppModel.Banner
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint).font(.system(size: 13))
            VStack(alignment: .leading, spacing: 4) {
                switch banner {
                case .libreOffice:
                    Text("Word and PowerPoint files need LibreOffice (free). Until it's installed, they're skipped.")
                    Text(OfficeConverter.brewCommand)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                    Link("Download LibreOffice", destination: OfficeConverter.installHelpURL)
                        .font(.system(size: 11))
                case .error(let message):
                    Text(message).textSelection(.enabled)
                }
            }
            .font(.system(size: 11))
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { model.banner = nil } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(10)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var icon: String {
        if case .error = banner { return "exclamationmark.octagon.fill" }
        return "exclamationmark.triangle.fill"
    }

    private var tint: Color {
        if case .error = banner { return .red }
        return .orange
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
