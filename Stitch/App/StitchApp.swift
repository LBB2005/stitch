import AppKit
import SwiftUI

@main
struct StitchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    // Everything happens in the menu bar panel (`PanelController`, set up by the app delegate), including
    // Settings. This scene only exists because an App needs one.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// True when the app is only hosting unit tests: no menu bar icon, notifications or cleanup.
    static let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    let model: AppModel
    private var panel: PanelController?

    override init() {
        let defaults = Self.isTesting ? UserDefaults(suiteName: "StitchTestHost") ?? .standard : .standard
        model = AppModel(prefs: Preferences(defaults: defaults))
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isTesting else { return }
        Workspace.clearAll()
        let panel = PanelController(model: model)
        panel.install()
        model.panel = panel
        self.panel = panel
        Notifier.shared.onOpen = { [weak panel] in panel?.open() }
        #if DEBUG
        if let demo = UserDefaults.standard.string(forKey: "StitchDemo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [model] in DemoMode.run(demo, model: model, panel: panel) }
            return
        }
        #endif
        Notifier.shared.install()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Workspace.clearAll()
    }
}
