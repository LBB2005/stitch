import SwiftUI

/// Every screen lives inside the one panel; switching slides the new screen in from the side it
/// belongs to. The panel follows the content's height.
struct PanelRoot: View {
    let controller: PanelController
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack(alignment: .top) {
            screen
                .id(model.screen)
                .transition(.asymmetric(
                    insertion: .move(edge: model.forward ? .trailing : .leading).combined(with: .opacity),
                    removal: .move(edge: model.forward ? .leading : .trailing).combined(with: .opacity)))
        }
        .frame(width: PanelController.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
        })
        .onPreferenceChange(ContentHeightKey.self) { height in
            MainActor.assumeIsolated { controller.contentHeightChanged(height) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
        .animation(.smooth(duration: 0.28), value: model.screen)
    }

    @ViewBuilder private var screen: some View {
        switch model.screen {
        case .home: HomeView()
        case .arrange: ArrangeView()
        case .working: WorkingView()
        case .done: DoneView(controller: controller)
        case .settings: SettingsView()
        }
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
