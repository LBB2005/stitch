import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// The Stitch window's Settings (⌘,): default PDF app, date format, Touch ID, signatures and your info.
/// The menu bar panel keeps its own settings screen exactly as it was.
@MainActor
enum SettingsOpener {
    enum Tab: Hashable { case general, signatures, yourInfo }

    @MainActor @Observable final class State { var tab: Tab = .general }
    static let state = State()
    private static var controller: NSWindowController?
    static var prefs: Preferences?
    static var documents: DocumentController?

    static func open(tab: Tab) {
        state.tab = tab
        documents?.becomeApp()
        if controller == nil, let prefs {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Stitch Settings"
            window.isRestorable = false
            window.tabbingMode = .disallowed
            window.contentView = NSHostingView(rootView: AppSettingsView()
                .environment(prefs).environment(state).environment(SignatureStore.shared))
            window.center()
            window.setFrameAutosaveName("StitchSettingsWindow")
            controller = NSWindowController(window: window)
        }
        controller?.window?.makeKeyAndOrderFront(nil)
    }
}

struct AppSettingsView: View {
    @Environment(SettingsOpener.State.self) private var state

    var body: some View {
        @Bindable var state = state
        TabView(selection: $state.tab) {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsOpener.Tab.general)
            SignatureSettings().tabItem { Label("Signatures", systemImage: "signature") }.tag(SettingsOpener.Tab.signatures)
            YourInfoSettings().tabItem { Label("Your Info", systemImage: "person.text.rectangle") }.tag(SettingsOpener.Tab.yourInfo)
        }
        .padding(20)
        .frame(width: 560, height: 520)
    }
}

private struct GeneralSettings: View {
    @Environment(Preferences.self) private var prefs
    @State private var isDefault = DefaultPDFApp.isStitch
    @State private var error: String?

    var body: some View {
        @Bindable var prefs = prefs
        Form {
            Section {
                LabeledContent("Default PDF app") {
                    if isDefault {
                        Label("Stitch is your PDF app", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                    } else {
                        Button("Make Stitch the Default PDF App") {
                            DefaultPDFApp.makeStitch { ok, message in
                                isDefault = ok
                                error = message
                            }
                        }
                    }
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                Text("PDFs then open here with a double-click. Finder's Open With → Stitch always works. For right-click → Services → “Sign or Edit with Stitch”, switch it on once in System Settings → Keyboard → Keyboard Shortcuts → Services.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("Date format", selection: $prefs.dateFormat) {
                    ForEach(Preferences.dateFormats, id: \.self) { f in
                        Text(Self.sample(f)).tag(f)
                    }
                }
                Toggle("Don't ask for Touch ID again for 5 minutes", isOn: $prefs.touchIDGrace)
                    .onChange(of: prefs.touchIDGrace) { _, on in BiometricGate.graceSeconds = on ? 300 : 0 }
            }
            Section {
                Text("Saving always makes a new file next to the original (Lease_signed.pdf or Lease_edited.pdf). The original is never written to. If that folder can't be written, copies go to \(FileManager.default.displayName(atPath: prefs.saveFolder.path)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { isDefault = DefaultPDFApp.isStitch }
    }

    static func sample(_ format: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f.string(from: .now)
    }
}

private struct SignatureSettings: View {
    @Environment(SignatureStore.self) private var store
    @State private var editing: Bool?   // nil: closed; false: signature; true: initials

    var body: some View {
        Form {
            row(title: "Signature", sig: store.signature, initials: false)
            row(title: "Initials", sig: store.initials, initials: true)
            Text("Stored as vector strokes (or typed text) in your login Keychain, only on this Mac. Stitch asks for Touch ID before putting either on a page.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .sheet(item: Binding(get: { editing.map(SheetID.init) }, set: { editing = $0?.initials })) { id in
            SignaturePad(initials: id.initials) { result in
                if let result { try? store.setSignature(result, initials: id.initials) }
                editing = nil
            }
        }
    }

    private struct SheetID: Identifiable {
        let initials: Bool
        var id: Bool { initials }
    }

    private func row(title: String, sig: Signature?, initials: Bool) -> some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                if let sig {
                    SignaturePreview(signature: sig)
                        .frame(width: 140, height: 44)
                    Button("Change…") { editing = initials }
                    Button("Delete", role: .destructive) { try? store.setSignature(nil, initials: initials) }
                } else {
                    Text("None").foregroundStyle(.secondary)
                    Button("Create…") { editing = initials }
                }
            }
        }
    }
}

struct SignaturePreview: View {
    let signature: Signature

    var body: some View {
        Canvas { ctx, size in
            ctx.withCGContext { cg in
                cg.translateBy(x: 0, y: size.height)
                cg.scaleBy(x: 1, y: -1)
                signature.draw(in: cg, size: size, color: NSColor.labelColor.cgColor)
            }
        }
        .padding(4)
        .background(Theme.cell, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct YourInfoSettings: View {
    @Environment(SignatureStore.self) private var store
    @State private var unlocked = false
    @State private var draft = Profile()
    @State private var saved = true
    @State private var error: String?

    var body: some View {
        Group {
            if unlocked {
                Form {
                    Section("You") {
                        TextField("First name", text: $draft.firstName)
                        TextField("Last name", text: $draft.lastName)
                        TextField("Email", text: $draft.email)
                        TextField("Phone", text: $draft.phone)
                        TextField("Student ID", text: $draft.studentID)
                        TextField("Date of birth", text: $draft.dateOfBirth, prompt: Text("MM/DD/YYYY"))
                    }
                    ForEach($draft.addresses) { $a in
                        Section {
                            TextField("Label", text: $a.label, prompt: Text("School, Mailing, Home…"))
                            TextField("Street", text: $a.street)
                            TextField("Apt / Suite", text: $a.street2)
                            TextField("City", text: $a.city)
                            HStack {
                                TextField("State", text: $a.state)
                                TextField("ZIP", text: $a.zip)
                            }
                            TextField("Country", text: $a.country)
                            Button("Remove This Address", role: .destructive) {
                                draft.addresses.removeAll { $0.id == a.id }
                            }
                        } header: {
                            Text(a.label.isEmpty ? "Address" : a.label + " Address")
                        }
                    }
                    Section {
                        Button("Add Address") {
                            draft.addresses.append(Profile.Address(label: draft.addresses.isEmpty ? "Home" : "Mailing"))
                        }
                        if let error { Text(error).foregroundStyle(.red).font(.caption) }
                        Text("Stored only on this Mac, in your login Keychain. Used by My Info → Fill Matching Fields, which asks for Touch ID first.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
                .onChange(of: draft) { _, _ in saved = false }
                .safeAreaInset(edge: .bottom) {
                    HStack {
                        Spacer()
                        Button("Save") {
                            do {
                                try store.setProfile(draft)
                                saved = true
                                error = nil
                            } catch {
                                self.error = error.localizedDescription
                            }
                        }
                        .keyboardShortcut("s")
                        .disabled(saved)
                    }
                    .padding(.top, 8)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "touchid").font(.system(size: 36)).foregroundStyle(.secondary)
                    Text("Your details are locked").font(.headline)
                    Button("Show With Touch ID") { unlock() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if !unlocked { unlock() } }
    }

    private func unlock() {
        Task {
            if await BiometricGate.authorize("show your saved details") {
                draft = store.profile
                unlocked = true
                saved = true
            }
        }
    }
}

/// Makes Stitch the app that opens PDFs on a double-click.
@MainActor
enum DefaultPDFApp {
    static var isStitch: Bool {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: .pdf) else { return false }
        return Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    static func makeStitch(_ done: @escaping @MainActor (Bool, String?) -> Void) {
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: .pdf) { error in
            Task { @MainActor in
                if let error { done(false, "Couldn't change it: \(error.localizedDescription)") } else { done(isStitch, nil) }
            }
        }
    }
}
