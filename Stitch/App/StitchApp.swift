import AppKit
import SwiftUI

@main
struct StitchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    // The menu bar panel (`PanelController`) works exactly as before. The Stitch window, document tabs
    // and their Settings are AppKit windows run by `DocumentController`; this scene only exists because
    // an App needs one, and carries the menu bar menus shown while a Stitch window is open.
    var body: some Scene {
        Settings { EmptyView() }
            .commands { StitchCommands(documents: delegate.documents) }
    }
}

/// File / Edit / Insert / View menus, sent to the frontmost document tab.
struct StitchCommands: Commands {
    let documents: DocumentController

    var body: some Commands {
        let doc = documents.current
        let _ = documents.commandsTick
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { SettingsOpener.open(tab: .general) }
                .keyboardShortcut(",")
        }
        CommandGroup(replacing: .newItem) {
            Button("Open…") { documents.showOpenPanel() }
                .keyboardShortcut("o")
            Menu("Open Recent") {
                ForEach(documents.recents, id: \.self) { url in
                    Button(url.lastPathComponent) { documents.open(url) }
                }
                if !documents.recents.isEmpty {
                    Divider()
                    Button("Clear Menu") { documents.clearRecents() }
                }
            }
            Button("Stitch Window") { documents.showHome() }
                .keyboardShortcut("1", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .saveItem) {
            // Replacing the Save group also drops the standard Close, so it comes back here.
            Button("Close Tab") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w")
            Divider()
            Button("Save Copy") { documents.current?.saveCopy() }
                .keyboardShortcut("s")
                .disabled(doc == nil || doc?.ui.isSaving == true)
            Button("Save Copy As…") { documents.current?.saveCopyAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(doc == nil)
        }
        CommandGroup(replacing: .printItem) {}
        CommandMenu("Insert") {
            Group {
            Button("Signature") { documents.current?.placeSignature(initials: false) }
                .keyboardShortcut("s", modifiers: [.command, .option])
            Button("Initials") { documents.current?.placeSignature(initials: true) }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Button("Today's Date") { documents.current?.insertDate() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Text Box") { documents.current?.startTextBox() }
                .keyboardShortcut("t", modifiers: [.command, .option])
            Button("Fill My Info") { documents.current?.fillMatchingFields(address: nil) }
                .keyboardShortcut("f", modifiers: [.command, .option])
            Divider()
            Button(doc?.ui.tool == .editText ? "Stop Editing Text" : "Edit Text") { documents.current?.toggleEditText() }
                .keyboardShortcut("e", modifiers: [.command, .option])
            Divider()
            Button("Create or Change Signature…") { documents.current?.createSignature(initials: false) }
            Button("Create or Change Initials…") { documents.current?.createSignature(initials: true) }
            }
            .disabled(doc == nil)
        }
        CommandGroup(replacing: .sidebar) {
            Button(doc?.ui.isFolded == true ? "Show Sidebar" : "Hide Sidebar") { documents.current?.toggleSidebar() }
                .keyboardShortcut("s", modifiers: [.command, .control])
                .disabled(doc == nil)
            Menu("Sidebar") {
                ForEach(SidebarPanel.allCases) { panel in
                    Button(panel.title) { documents.current?.showPanel(panel) }
                        .keyboardShortcut(panel.key)
                }
            }
            .disabled(doc == nil)
            Divider()
        }
        CommandGroup(replacing: .textEditing) {
            Menu("Find") {
                Button("Find…") { documents.current?.startFind() }
                    .keyboardShortcut("f")
                Button("Find Next") { documents.current?.findNext() }
                    .keyboardShortcut("g")
                Button("Find Previous") { documents.current?.findPrevious() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
            }
            .disabled(doc == nil)
        }
        CommandGroup(after: .toolbar) {
            Button("Zoom In") { documents.current?.zoomIn() }
                .keyboardShortcut("+")
                .disabled(doc == nil)
            Button("Zoom Out") { documents.current?.zoomOut() }
                .keyboardShortcut("-")
                .disabled(doc == nil)
            Button("Actual Size") { documents.current?.actualSize() }
                .keyboardShortcut("0")
                .disabled(doc == nil)
            Button("Fit Width") { documents.current?.fitWidth() }
                .keyboardShortcut("9")
                .disabled(doc == nil)
            Divider()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// True when the app is only hosting unit tests: no menu bar icon, notifications or cleanup.
    static let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    let model: AppModel
    let documents: DocumentController
    private var panel: PanelController?
    private let services = ServiceProvider()
    private var launchedAtLogin = false
    private var openedFilesAtLaunch = false

    override init() {
        let defaults = Self.isTesting ? UserDefaults(suiteName: "StitchTestHost") ?? .standard : .standard
        model = AppModel(prefs: Preferences(defaults: defaults))
        documents = DocumentController(model: model)
        super.init()
        SettingsOpener.prefs = model.prefs
        SettingsOpener.documents = documents
        BiometricGate.graceSeconds = model.prefs.touchIDGrace ? 300 : 0
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAtLogin = event?.eventID == AEEventID(kAEOpenApplication)
            && event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
        // Login items registered with SMAppService may not say so; a launch right after logging in, with
        // Open at Login on, counts as one too.
        if !launchedAtLogin, LoginItem.isEnabled, let since = Self.secondsSinceLogin(), since < 90 { launchedAtLogin = true }
    }

    /// Seconds since this login session began (when loginwindow started).
    private static func secondsSinceLogin() -> TimeInterval? {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.loginwindow").first?.processIdentifier
        else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        let started = Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
        return Date().timeIntervalSince(started)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isTesting else { return }
        Workspace.clearAll()
        let panel = PanelController(model: model)
        panel.onOpenApp = { [documents] in documents.showHome() }
        panel.onOpenPDF = { [documents] in documents.showOpenPanel() }
        panel.install()
        model.panel = panel
        self.panel = panel
        services.documents = documents
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        Notifier.shared.onOpen = { [weak panel] in panel?.open() }
        #if DEBUG
        if let demo = UserDefaults.standard.string(forKey: "StitchDemo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [model, documents] in
                if DocumentDemo.screens.contains(demo) {
                    DocumentDemo.run(demo, documents: documents)
                } else {
                    DemoMode.run(demo, model: model, panel: panel)
                }
            }
            return
        }
        #endif
        Notifier.shared.install()
        // Opened by hand (Dock, Applications, Spotlight): show the Stitch window. Opened at login or to
        // open a file: stay in the menu bar.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
            if !launchedAtLogin, !openedFilesAtLaunch, documents.windows.isEmpty { documents.showHome() }
        }
    }

    /// Double-click (once Stitch is the default), Open With, a drop on the Dock icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        openedFilesAtLaunch = true
        guard !Self.isTesting else { return }
        documents.open(urls)
    }

    /// Clicking Stitch in the Dock or opening it again from Applications.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let anyWindow = documents.windows.contains { $0.window?.isVisible == true } || documents.home.window?.isVisible == true
        if !anyWindow { documents.showHome() }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard documents.windows.contains(where: \.needsSaving) else { return .terminateNow }
        DispatchQueue.main.async { [documents] in
            documents.reviewBeforeQuit { NSApp.reply(toApplicationShouldTerminate: $0) }
        }
        return .terminateLater
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open PDF…", action: #selector(openPDFFromDock), keyEquivalent: "").target = self
        return menu
    }

    @objc private func openPDFFromDock() { documents.showOpenPanel() }

    func applicationWillTerminate(_ notification: Notification) {
        Workspace.clearAll()
    }
}

/// Finder → right-click → Services → Sign or Edit with Stitch.
final class ServiceProvider: NSObject {
    @MainActor weak var documents: DocumentController?

    @MainActor @objc func signOrEditPDF(_ pboard: NSPasteboard, userData: String?,
                                        error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else {
            error.pointee = "No PDF was selected." as NSString
            return
        }
        documents?.open(urls)
    }
}
