import AppKit
import SwiftUI

/// Settings slide in inside the panel, like every other screen.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var prefs
    @State private var openAtLogin = LoginItem.isEnabled
    @State private var loginError: String?

    var body: some View {
        @Bindable var prefs = prefs
        VStack(spacing: 10) {
            PanelHeader(title: "Settings") {
                IconButton(symbol: "chevron.left", label: "Back") { model.back() }
            } trailing: {
                EmptyView()
            }
            Well(padding: 0) {
                VStack(spacing: 0) {
                    SettingRow(symbol: "folder", title: "Save to") {
                        FolderMenu(current: prefs.saveFolder,
                                   onPick: { prefs.saveFolder = $0 ?? Preferences.downloads },
                                   onChoose: { model.chooseFolder(asDefault: true) })
                    }
                    WellDivider()
                    SettingRow(symbol: "arrow.up.doc", title: "Upload size limit") { TargetMenu() }
                }
            }
            Well(padding: 0) {
                VStack(spacing: 0) {
                    OptionRow(symbol: "text.viewfinder", title: "Make scans searchable",
                              caption: "Off is faster", isOn: $prefs.ocr)
                    WellDivider()
                    OptionRow(symbol: "arrow.down.right.and.arrow.up.left", title: "Shrink to fit upload limit",
                              caption: "Only when the file is over the limit", isOn: $prefs.shrink)
                    WellDivider()
                    OptionRow(symbol: "location.slash", title: "Remove location from photos",
                              caption: "When converting to JPEG", isOn: $prefs.stripLocation)
                    WellDivider()
                    OptionRow(symbol: "power", title: "Open at login", caption: loginError, isOn: loginBinding)
                }
            }
            Well(padding: 0) {
                SettingRow(symbol: "doc.richtext", title: "Word & PowerPoint") {
                    if OfficeConverter.isInstalled {
                        Label("LibreOffice ready", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        Link("Get LibreOffice", destination: OfficeConverter.installHelpURL)
                            .font(.system(size: 12))
                    }
                }
            }
            HStack {
                Text("Stitch \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Quit Stitch") { NSApp.terminate(nil) }
                    .buttonStyle(SecondaryButtonStyle(fullWidth: false))
            }
            .padding(.horizontal, 2)
        }
        .padding(Theme.padding)
    }

    private var loginBinding: Binding<Bool> {
        Binding {
            openAtLogin
        } set: { enabled in
            do {
                try LoginItem.setEnabled(enabled)
                openAtLogin = enabled
                loginError = nil
            } catch {
                openAtLogin = LoginItem.isEnabled
                loginError = "Couldn't change it: install Stitch in Applications first"
            }
        }
    }
}

private struct SettingRow<Accessory: View>: View {
    let symbol: String
    let title: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(title).font(.system(size: 13))
            Spacer(minLength: 6)
            accessory
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 36)
    }
}
