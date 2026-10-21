import SwiftUI

/// Settings in the shape a Mac app is expected to take: a source list of
/// topics on the left, one topic's controls on the right. Splitting the old
/// single scroll into panes means each one fits on screen whole, which is
/// what makes a setting findable.
struct SettingsView: View {
    @Bindable var settings: AppSettings
    let store: ContainerStore

    @State private var pane: SettingsPane = .general

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 440, idealHeight: 520)
        .task { await store.refreshNotificationAuthorization() }
    }

    private var sidebar: some View {
        List(selection: $pane) {
            Section("Settings") {
                ForEach(SettingsPane.settings) { row(for: $0) }
            }
            Section("Ballast") {
                ForEach(SettingsPane.app) { row(for: $0) }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 176, ideal: 192, max: 240)
    }

    private func row(for pane: SettingsPane) -> some View {
        HStack(spacing: 7) {
            PaneIcon(symbol: pane.symbol, tint: pane.tint)
            Text(pane.title)
                .font(.system(size: 13))
        }
        .padding(.vertical, 1)
        .tag(pane)
    }

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch pane {
                case .general: GeneralPane(settings: settings, store: store)
                case .connection: ConnectionPane(settings: settings, store: store)
                case .menu: MenuPane(settings: settings, store: store)
                case .notifications: NotificationsPane(settings: settings, store: store)
                case .history: HistoryPane(store: store)
                case .about: AboutPane()
                }
            }
            .padding(20)
            // A column rather than the full width of the window: rows whose
            // label and control are metres apart are hard to pair up.
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(pane.title)
    }
}

/// The topics in the source list, in the order they're shown.
enum SettingsPane: String, CaseIterable, Identifiable, Hashable {
    case general, connection, menu, notifications, history, about

    var id: String { rawValue }

    /// Everything that configures the app…
    static let settings: [SettingsPane] = [.general, .connection, .menu, .notifications, .history]
    /// …and everything that's about it, which System Settings keeps apart.
    static let app: [SettingsPane] = [.about]

    var title: String {
        switch self {
        case .general: "General"
        case .connection: "Connection"
        case .menu: "Menu"
        case .notifications: "Notifications"
        case .history: "History"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .connection: "network"
        case .menu: "menubar.rectangle"
        case .notifications: "bell.badge.fill"
        case .history: "clock.arrow.circlepath"
        case .about: "info"
        }
    }

    var tint: Color {
        switch self {
        case .general: .gray
        case .connection: .blue
        case .menu: .indigo
        case .notifications: .red
        case .history: .orange
        case .about: .blue
        }
    }
}

/// The tinted glyph that stands in for a pane in the source list.
private struct PaneIcon: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(tint.gradient, in: .rect(cornerRadius: 4.5))
    }
}
