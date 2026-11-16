import SwiftUI

/// The sidebar's panels, in rail order.
enum SidebarPanel: String, CaseIterable, Identifiable {
    case pages, todo, sign, myInfo, history, find

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pages: "Pages"
        case .todo: "To-Do"
        case .sign: "Sign"
        case .myInfo: "My Info"
        case .history: "History"
        case .find: "Find"
        }
    }

    var symbol: String {
        switch self {
        case .pages: "doc.on.doc"
        case .todo: "checklist"
        case .sign: "signature"
        case .myInfo: "person.text.rectangle"
        case .history: "clock.arrow.circlepath"
        case .find: "magnifyingglass"
        }
    }

    /// ⌘1…⌘5, ⌘F.
    var key: KeyEquivalent {
        switch self {
        case .pages: "1"
        case .todo: "2"
        case .sign: "3"
        case .myInfo: "4"
        case .history: "5"
        case .find: "f"
        }
    }

    var shortcutLabel: String {
        switch self {
        case .find: "⌘F"
        default: "⌘\(String(key.character))"
        }
    }
}

/// The sidebar: the rail, the open panel, and the selected item's card pinned at the bottom.
struct SidebarView: View {
    let controller: DocumentWindowController
    @Environment(DocumentUI.self) private var ui

    var body: some View {
        HStack(spacing: 0) {
            RailView(controller: controller)
            Divider().opacity(0.6)
            VStack(spacing: 0) {
                panel
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                if ui.selection != nil {
                    Divider()
                    SelectionCard(controller: controller)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity)
            .animation(.snappy(duration: 0.2), value: ui.selection != nil)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .clipped()
    }

    @ViewBuilder private var panel: some View {
        switch ui.panel {
        case .pages: PagesPanel(controller: controller)
        case .todo: TodoPanel(controller: controller)
        case .sign: SignPanel(controller: controller)
        case .myInfo: MyInfoPanel(controller: controller)
        case .history: HistoryPanel(controller: controller)
        case .find: FindPanel(controller: controller)
        }
    }
}

/// A panel's title row and scrolling body.
struct PanelScaffold<Accessory: View, Content: View>: View {
    let title: String
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 4)
                accessory()
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)
            content()
        }
    }
}

extension PanelScaffold where Accessory == EmptyView {
    init(title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.accessory = { EmptyView() }
        self.content = content
    }
}

/// A small section heading inside a panel.
struct PanelSection: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.secondary)
            Spacer()
            if let trailing {
                Text(trailing).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 2)
    }
}

/// A short grey sentence for empty panels.
struct PanelNote: View {
    let text: String
    var symbol: String?

    var body: some View {
        VStack(spacing: 8) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(.tertiary)
            }
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 12)
    }
}

/// Blurred contents until Touch ID passes (Sign and My Info).
struct RevealGate<Content: View>: View {
    let controller: DocumentWindowController
    let reason: String
    @ViewBuilder var content: () -> Content
    @Environment(DocumentUI.self) private var ui

    var body: some View {
        ZStack {
            content()
                .blur(radius: ui.revealed ? 0 : 7)
                .allowsHitTesting(ui.revealed)
                .accessibilityHidden(!ui.revealed)
            if !ui.revealed {
                Button {
                    controller.revealSidebar(reason)
                } label: {
                    Label("Show with Touch ID", systemImage: "touchid")
                }
                .controlSize(.regular)
            }
        }
    }
}
