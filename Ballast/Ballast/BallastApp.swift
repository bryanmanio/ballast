import SwiftUI

@main
struct BallastApp: App {
    @Environment(\.openWindow) private var openWindow
    @State private var settings: AppSettings
    @State private var store: ContainerStore
    /// Owns the right-click menu on the status item. Held here so it lives as
    /// long as the app does.
    @State private var contextMenu = MenuBarContextMenu()
    /// Owns the system-wide shortcut. A singleton because the Carbon
    /// registration it wraps is process-wide whether we like it or not.
    private let hotkeys = GlobalHotkeyCenter.shared
    /// Renders the menu's contents in an ordinary window as well, so the
    /// layout can be inspected and screenshotted without fighting the menu
    /// bar. Enable with `-BallastDebugWindow YES`.
    private let showsDebugWindow: Bool
    /// Opens Settings at launch, so the panes can be worked on and
    /// screenshotted without clicking through the menu bar. Enable with
    /// `-BallastSettingsWindow YES`.
    private let showsSettingsAtLaunch: Bool

    private static let fixtureDefaultsSuite = "com.bryanmaniotakis.ballast.fixtures"

    init() {
        // Launch with `-BallastUseFixtures YES` to drive the menu from
        // sample data, for working on the UI without a NAS to hand.
        let useFixtures = UserDefaults.standard.bool(forKey: "BallastUseFixtures")

        // Fixture mode gets its own defaults domain so poking at settings
        // while developing can't disturb a real configuration.
        let settings = AppSettings(
            defaults: useFixtures
                ? (UserDefaults(suiteName: Self.fixtureDefaultsSuite) ?? .standard)
                : .standard
        )
        if useFixtures {
            if settings.sshDestination.isEmpty { settings.sshDestination = "fixtures@nas" }
            if settings.lanHost.isEmpty { settings.lanHost = "nas.local" }
        }

        // Fixture mode only: makes one container crash and recover on a
        // timer, so notifications and history can be checked end to end.
        let simulateCrash = UserDefaults.standard.bool(forKey: "BallastSimulateCrash")

        let makeSource: @MainActor @Sendable (AppSettings) -> ContainerSource
        if useFixtures {
            makeSource = { _ in FixtureContainerSource(simulatesCrash: simulateCrash) }
        } else {
            makeSource = { settings in
                SSHContainerSource(destination: settings.sshDestination, agentPath: settings.agentPath)
            }
        }

        // Fixture mode logs to its own file, for the same reason it has its
        // own defaults domain.
        let historyStore = FileDowntimeHistoryStore(url: FileDowntimeHistoryStore.defaultURL(fixtures: useFixtures))
        if useFixtures && historyStore.load().isEmpty {
            historyStore.append(FixtureContainerSource.sampleHistory())
        }

        let store = ContainerStore(
            settings: settings,
            probe: useFixtures ? FixtureProbe() : ServiceProbe(),
            historyStore: historyStore,
            notifier: UserNotificationsExitNotifier(),
            requiresSSHConfiguration: !useFixtures,
            makeSource: makeSource
        )

        showsDebugWindow = UserDefaults.standard.bool(forKey: "BallastDebugWindow")
        showsSettingsAtLaunch = UserDefaults.standard.bool(forKey: "BallastSettingsWindow")
        _settings = State(initialValue: settings)
        _store = State(initialValue: store)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(store: store, settings: settings)
        } label: {
            MenuBarLabel(status: store.overallStatus, problemCount: store.problemCount)
                // Opening a window is something only SwiftUI can do, so the
                // menu is handed the action rather than the other way round.
                .onAppear {
                    contextMenu.openSettings = { openWindow(id: "settings") }
                    contextMenu.install()
                    // The shortcut can only be registered once there is a
                    // menu bar item for it to open.
                    hotkeys.action = { MenuBarPresenter.toggle() }
                    hotkeys.apply(settings.hotkey)
                }
                // Polling is driven from the label, not the menu's contents:
                // with the window style those contents aren't created until
                // the menu is first opened, which would leave the menu bar
                // icon blank until clicked — the opposite of its purpose.
                .task { store.startPolling() }
        }
        // The window style is what allows a scrollable, grouped list with
        // per-row controls; the default menu style can't host one.
        .menuBarExtraStyle(.window)

        // Settings live in a window, the way a Mac app's do — the popover
        // is too narrow for a source list, and this is the one surface both
        // the gear button and the right-click menu open.
        Window("Ballast Settings", id: "settings") {
            SettingsView(settings: settings, store: store)
        }
        .defaultSize(width: 720, height: 520)
        // The sidebar is the point of this window, so it's resizable down to
        // the width that still keeps a label and its control on one line.
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(showsSettingsAtLaunch ? .presented : .suppressed)

        // Always declared so the scene graph has one concrete shape; only
        // presented at launch when the debug flag is set.
        Window("Ballast — menu preview", id: "debug-preview") {
            // Sized like the popover — content height, not window height —
            // so layout bugs that only appear in the menu show up here too.
            MenuContentView(store: store, settings: settings)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .defaultSize(width: 340, height: 600)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(showsDebugWindow ? .presented : .suppressed)
    }
}
