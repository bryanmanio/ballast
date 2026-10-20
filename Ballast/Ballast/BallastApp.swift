import SwiftUI

@main
struct BallastApp: App {
    @State private var settings: AppSettings
    @State private var store: ContainerStore
    /// Renders the menu's contents in an ordinary window as well, so the
    /// layout can be inspected and screenshotted without fighting the menu
    /// bar. Enable with `-BallastDebugWindow YES`.
    private let showsDebugWindow: Bool

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

        let makeSource: @MainActor @Sendable (AppSettings) -> ContainerSource
        if useFixtures {
            makeSource = { _ in FixtureContainerSource() }
        } else {
            makeSource = { settings in
                SSHContainerSource(destination: settings.sshDestination, agentPath: settings.agentPath)
            }
        }

        let store = ContainerStore(
            settings: settings,
            probe: useFixtures ? FixtureProbe() : ServiceProbe(),
            requiresSSHConfiguration: !useFixtures,
            makeSource: makeSource
        )

        showsDebugWindow = UserDefaults.standard.bool(forKey: "BallastDebugWindow")
        _settings = State(initialValue: settings)
        _store = State(initialValue: store)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(store: store, settings: settings)
        } label: {
            MenuBarLabel(status: store.overallStatus, problemCount: store.problemCount)
                .contextMenu {
                    Button("Quit Ballast") { NSApplication.shared.terminate(nil) }
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
