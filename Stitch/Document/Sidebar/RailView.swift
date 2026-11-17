import SwiftUI

/// The sidebar's column of icons. Clicking one opens its panel; clicking the open one folds the sidebar.
/// Folded, the same rail floats over the PDF in a glass capsule (`floating`).
struct RailView: View {
    let controller: DocumentWindowController
    var floating = false
    @Environment(DocumentUI.self) private var ui

    var body: some View {
        VStack(spacing: 4) {
            ForEach(SidebarPanel.allCases) { panel in
                RailButton(symbol: panel.symbol, active: !ui.isFolded && ui.panel == panel, badge: badge(panel),
                           help: help(panel), label: accessibility(panel)) {
                    controller.railTapped(panel)
                }
            }
            if floating {
                Divider().frame(width: 24).padding(.vertical, 2)
            } else {
                Spacer(minLength: 8)
            }
            RailButton(symbol: "sidebar.left", active: false, badge: nil,
                       help: ui.isFolded ? "Show Sidebar (⌃⌘S)" : "Hide Sidebar (⌃⌘S)",
                       label: ui.isFolded ? "Show Sidebar" : "Hide Sidebar") {
                controller.toggleSidebar()
            }
        }
        .padding(.vertical, floating ? 8 : 6)
        .frame(width: floating ? 48 : 56)
        .modifier(FloatingGlass(enabled: floating))
    }

    private func badge(_ panel: SidebarPanel) -> RailButton.Badge? {
        switch panel {
        case .todo:
            if ui.todoLeft > 0 { return .count(ui.todoLeft, warning: ui.hasWarning) }
            if ui.hasWarning { return .dot(.orange) }
            if !ui.todo.isEmpty { return .check }
            return nil
        case .history:
            return ui.isDirty ? .dot(.accentColor) : nil
        case .combine:
            let job = controller.combine
            if job.isWorking { return .dot(.accentColor) }
            if job.phase == .done { return .check }
            return job.isEmpty ? nil : .count(job.files.count, warning: false)
        default:
            return nil
        }
    }

    private func status(_ panel: SidebarPanel) -> String? {
        switch panel {
        case .todo:
            if ui.todo.isEmpty { return ui.hasWarning ? "Has a note" : nil }
            if let next = ui.todo.first(where: { !$0.done }) { return "\(ui.todoLeft) left · next: \(next.label)" }
            return "All done"
        case .history:
            return ui.isDirty ? "Not saved" : nil
        case .find:
            return ui.find.results.isEmpty ? nil : "\(ui.find.results.count) found"
        case .combine:
            let job = controller.combine
            if job.isWorking { return "Working…" }
            return job.isEmpty ? "Merge or convert files" : job.title
        default:
            return nil
        }
    }

    private func help(_ panel: SidebarPanel) -> String {
        let base = "\(panel.title) (\(panel.shortcutLabel))"
        return status(panel).map { "\(base) · \($0)" } ?? base
    }

    private func accessibility(_ panel: SidebarPanel) -> String {
        switch panel {
        case .todo where ui.todoLeft > 0: "To-Do, \(ui.todoLeft) left"
        case .history where ui.isDirty: "History, not saved"
        default: panel.title
        }
    }
}

struct RailButton: View {
    enum Badge: Equatable {
        case count(Int, warning: Bool)
        case dot(Color)
        case check
    }

    let symbol: String
    let active: Bool
    let badge: Badge?
    let help: String
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(active ? Color.accentColor : Color.primary.opacity(0.75))
                .frame(width: 36, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(active ? Color.accentColor.opacity(0.16) : hovering ? Color.primary.opacity(0.06) : .clear)
                )
                .overlay(alignment: .topTrailing) { badgeView.offset(x: 4, y: -3) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    @ViewBuilder private var badgeView: some View {
        switch badge {
        case .count(let n, let warning):
            Text("\(n)")
                .font(.system(size: 9, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .frame(minWidth: 15, minHeight: 15)
                .background(Capsule().fill(warning ? Color.orange : Color.accentColor))
        case .dot(let color):
            Circle().fill(color).frame(width: 8, height: 8)
                .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
        case .check:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white, .green)
        case nil:
            EmptyView()
        }
    }
}

/// Liquid Glass on macOS 26; a material capsule before.
struct FloatingGlass: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if !enabled {
            content
        } else if #available(macOS 26, *) {
            // Material under the glass: the icons stay legible over a bright page in dark mode.
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .glassEffect(.regular, in: .rect(cornerRadius: 18))
        } else {
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        }
    }
}
