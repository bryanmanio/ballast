import AppKit
import ServiceManagement
import SwiftUI

// MARK: - General

/// How the app behaves as an app: when it starts, how often it looks, and
/// the key that summons it.
struct GeneralPane: View {
    @Bindable var settings: AppSettings
    let store: ContainerStore

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?

    private let hotkeys = GlobalHotkeyCenter.shared

    var body: some View {
        SettingsGroup {
            SettingsRow("Launch at login") {
                RowToggle(isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
            }
            if let launchAtLoginError {
                RowNote(launchAtLoginError, tint: .orange)
            }
        }

        SettingsGroup {
            SettingsRow(
                "Refresh automatically",
                help: "Off, Ballast only reads the NAS when you open the menu or press refresh."
            ) {
                RowToggle(isOn: $settings.autoRefreshEnabled)
            }
            RowDivider()
            SettingsRow("Refresh interval") {
                Picker("", selection: $settings.refreshInterval) {
                    Text("10 seconds").tag(10.0)
                    Text("30 seconds").tag(30.0)
                    Text("1 minute").tag(60.0)
                    Text("5 minutes").tag(300.0)
                }
                .rowPicker()
                .disabled(!settings.autoRefreshEnabled)
            }
            if !settings.autoRefreshEnabled {
                RowNote("Paused. Opening the menu still fetches the current state.")
            }
        }

        SettingsGroup {
            SettingsRow(
                "Check for image updates",
                subtitle: "Marks containers whose image has a newer release.",
                help: "Asks Docker Hub, GitHub and other registries directly from this Mac, every 6 hours. Nothing is pulled or changed on the NAS."
            ) {
                RowToggle(isOn: $settings.imageUpdateChecksEnabled)
                    .onChange(of: settings.imageUpdateChecksEnabled) { _, enabled in
                        if enabled { Task { await store.checkForUpdates() } }
                    }
            }
            if settings.imageUpdateChecksEnabled {
                RowDivider()
                SettingsRow("Last checked", subtitle: updateCheckSummary) {
                    if store.isCheckingForUpdates {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Check Now") { Task { await store.checkForUpdates() } }
                            .controlSize(.small)
                            .disabled(!settings.isConfigured)
                    }
                }
                if let error = store.updateCheckError {
                    RowNote(error.hint, symbol: "exclamationmark.triangle.fill", tint: .orange)
                }
            }
        }

        SettingsGroup {
            SettingsRow(
                "Global hotkey",
                subtitle: "Click the shortcut to record a new one."
            ) {
                HotkeyField(binding: $settings.hotkey)
                    .onChange(of: settings.hotkey) { _, binding in hotkeys.apply(binding) }
            }
            if hotkeys.isUnavailable {
                RowNote(
                    "Another app is already using this shortcut.",
                    symbol: "exclamationmark.triangle.fill",
                    tint: .orange
                )
            }
        }
    }

    private var updateCheckSummary: String {
        guard let checked = store.lastUpdateCheck else { return "Not yet" }
        let when = checked.formatted(.relative(presentation: .named))
        switch store.availableUpdateCount {
        case 0: return "\(when) · everything is current"
        case 1: return "\(when) · 1 update available"
        case let count: return "\(when) · \(count) updates available"
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Registration fails for an app that isn't in /Applications, which
            // is the usual state during development.
            launchAtLoginError = "Couldn't change this: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

// MARK: - Connection

/// Everything about reaching the NAS: the SSH destination Ballast runs its
/// agent over, and the hostnames it builds service URLs from.
struct ConnectionPane: View {
    @Bindable var settings: AppSettings
    let store: ContainerStore

    @State private var test: TestState = .idle
    @State private var showAdvanced = false

    enum TestState {
        case idle, running
        case success(AgentCheck)
        case failure(BallastError)
    }

    var body: some View {
        SettingsGroup("NAS") {
            SettingsRow(
                "SSH destination",
                subtitle: "user@host, or a ~/.ssh/config alias."
            ) {
                RowField(text: $settings.sshDestination, prompt: BundledScripts.placeholderDestination)
                    .onSubmit { runTest() }
            }
            RowDivider()
            SettingsRow("Test connection") {
                if isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Test") { runTest() }
                        .controlSize(.small)
                        .disabled(!settings.isConfigured)
                }
            }
            testResult
        }

        SettingsGroup("Service URLs") {
            SettingsRow("Local host") {
                RowField(
                    text: $settings.lanHost,
                    prompt: settings.effectiveLANHost.isEmpty ? "nas.local" : settings.effectiveLANHost
                )
            }
            RowDivider()
            SettingsRow("Remote host") {
                RowField(text: $settings.remoteHost, prompt: "100.x.y.z")
            }
            RowNote("For when you're away from home — a Tailscale name keeps the same menu working off your network.")
        }

        advanced
    }

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showAdvanced.toggle() }
            } label: {
                HStack(spacing: 3) {
                    Text("Advanced")
                        .font(.system(size: 11, weight: .semibold))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                }
                .padding(.leading, 2)
                .contentShape(.rect)
            }
            .buttonStyle(.pressable)
            .hoverHighlight()

            if showAdvanced {
                SettingsCard {
                    SettingsRow("Agent path") {
                        RowField(text: $settings.agentPath, prompt: SSHContainerSource.defaultAgentPath)
                    }
                    RowDivider()
                    SettingsRow("Reachability port") {
                        TextField("", value: $settings.reachabilityPort, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                    }
                }
            }
        }
    }

    private var isRunning: Bool {
        if case .running = test { return true }
        return false
    }

    @ViewBuilder
    private var testResult: some View {
        switch test {
        case .idle, .running:
            EmptyView()
        case .success(let check):
            RowNote("Connected — Docker \(check.dockerServerVersion)", symbol: "checkmark.circle.fill", tint: .green)
        case .failure(let error):
            RowNote(error.title, symbol: "xmark.circle.fill", tint: .red, help: error.hint)
        }
    }

    private func runTest() {
        test = .running
        Task {
            switch await store.testConnection() {
            case .success(let check):
                test = .success(check)
                await store.refresh()
            case .failure(let error):
                test = .failure(error)
            }
        }
    }
}

// MARK: - Menu

/// What the menu shows and in what order, plus the two lists that only the
/// menu can add to: muted and hidden containers.
struct MenuPane: View {
    @Bindable var settings: AppSettings
    let store: ContainerStore

    var body: some View {
        SettingsGroup {
            SettingsRow("Sort by") {
                Picker("", selection: $settings.sortOrder) {
                    ForEach(ContainerSortOrder.allCases) { order in
                        Text(order.label).tag(order)
                    }
                }
                .rowPicker()
            }
            RowDivider()
            SettingsRow(
                "Group by project",
                help: "Group containers under their compose stack instead of one flat list."
            ) {
                RowToggle(isOn: Binding(
                    get: { !settings.hideProjectNames },
                    set: { settings.hideProjectNames = !$0 }
                ))
            }
        }

        // The menu's header controls are icons with no room for a label, so
        // this is where the keys they answer to are written down.
        SettingsGroup("Keyboard") {
            SettingsRow("Filter containers") { KeyCaps("⌘F") }
            RowDivider()
            SettingsRow("Refresh now") { KeyCaps("⌘R") }
            RowDivider()
            SettingsRow("Downtime history") { KeyCaps("⌘Y") }
            RowDivider()
            SettingsRow("Settings") { KeyCaps("⌘,") }
            RowDivider()
            SettingsRow("Back to the list") { KeyCaps("esc") }
            RowNote("These work while the menu is open — the hotkey that opens it from anywhere is under General. Quit is in the right-click menu, on the menu bar icon or on the menu itself.")
        }

        let muted = store.mutedContainerNames
        SettingsGroup("Muted") {
            if muted.isEmpty {
                RowPlaceholder("Nothing is muted. Mute a container from its row in the menu to stop it notifying.")
            } else {
                ForEach(Array(muted.enumerated()), id: \.element) { index, name in
                    if index > 0 { RowDivider() }
                    SettingsRow(name) {
                        Button("Unmute") { store.unmute(name) }
                            .controlSize(.small)
                    }
                }
            }
        }

        let hidden = store.hiddenContainerNames
        SettingsGroup("Hidden") {
            if hidden.isEmpty {
                RowPlaceholder("Nothing is hidden. Hide a container from its row in the menu to keep it out of the list.")
            } else {
                ForEach(Array(hidden.enumerated()), id: \.element) { index, name in
                    if index > 0 { RowDivider() }
                    SettingsRow(name) {
                        Button("Show") { store.unhide(name) }
                            .controlSize(.small)
                    }
                }
            }
        }
    }
}

// MARK: - Notifications

struct NotificationsPane: View {
    @Bindable var settings: AppSettings
    let store: ContainerStore

    /// Set when the user turns notifications on and macOS says no, so the
    /// reason is still on screen after the toggle has switched itself back off.
    @State private var notificationsBlocked = false
    /// Confirms the test notification went out, for the case where macOS
    /// shows the banner somewhere the user isn't looking.
    @State private var testNotificationSent = false

    var body: some View {
        SettingsGroup {
            SettingsRow(
                "Unexpected exits",
                subtitle: "Only a non-zero exit code or an out-of-memory kill notifies.",
                help: "Clean exits and anything you stop yourself stay quiet."
            ) {
                RowToggle(isOn: $settings.notifyOnUnexpectedExit)
                    .onChange(of: settings.notifyOnUnexpectedExit) { _, enabled in
                        if enabled { enableNotifications() } else { notificationsBlocked = false }
                    }
            }
            if notificationsBlocked
                || (settings.notifyOnUnexpectedExit && store.notificationAuthorization == .denied) {
                RowNote("Blocked by macOS. Allow them in System Settings → Notifications.", tint: .orange)
            }
            RowDivider()
            SettingsRow("Test notification") {
                if testNotificationSent {
                    Text("Sent")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
                Button("Send") { sendTestNotification() }
                    .controlSize(.small)
            }
        }
    }

    /// Asks for permission if it hasn't been granted yet, so this doubles as
    /// the way to trigger the macOS prompt.
    private func sendTestNotification() {
        Task {
            let sent = await store.sendTestNotification()
            withAnimation(.easeInOut(duration: 0.15)) {
                testNotificationSent = sent
                notificationsBlocked = !sent
            }
            guard sent else { return }
            try? await Task.sleep(for: .seconds(3))
            withAnimation(.easeInOut(duration: 0.15)) { testNotificationSent = false }
        }
    }

    private func enableNotifications() {
        notificationsBlocked = false
        Task {
            if await store.requestNotificationAuthorization() { return }
            // Left on, the toggle would promise notifications that can't arrive.
            notificationsBlocked = true
            settings.notifyOnUnexpectedExit = false
        }
    }
}

// MARK: - History

struct HistoryPane: View {
    let store: ContainerStore

    var body: some View {
        SettingsGroup {
            SettingsRow(
                "Recorded events",
                subtitle: "Exits, restarts and image updates Ballast sees while it's running."
            ) {
                Text("\(store.history.count)")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button("Clear") { store.clearHistory() }
                    .controlSize(.small)
                    .disabled(store.history.isEmpty)
            }
        }

        SettingsGroup("Recent") {
            if store.history.isEmpty {
                RowPlaceholder("Nothing recorded yet.")
            } else {
                let recent = Array(store.history.reversed().prefix(8))
                ForEach(Array(recent.enumerated()), id: \.element.id) { index, event in
                    if index > 0 { RowDivider() }
                    SettingsRow(event.containerName, subtitle: event.summary) {
                        Text(event.at.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - About

struct AboutPane: View {
    private static let repository = URL(string: "https://github.com/bryanmanio/ballast")!
    private static let newIssue = URL(string: "https://github.com/bryanmanio/ballast/issues/new")!

    var body: some View {
        VStack(spacing: 10) {
            BallastMark(size: 72)
            VStack(spacing: 3) {
                Text("Ballast")
                    .font(.system(size: 20, weight: .semibold))
                Text(Self.versionString)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Text("Docker on your NAS, in the menu bar.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .padding(.bottom, 6)

        SettingsCard {
            LinkRow(
                title: "Report an Issue",
                subtitle: "Something broken or missing — open an issue on GitHub.",
                symbol: "ladybug.fill",
                tint: .red,
                url: Self.newIssue
            )
            RowDivider()
            LinkRow(
                title: "Source Code",
                subtitle: "github.com/bryanmanio/ballast",
                symbol: "chevron.left.forwardslash.chevron.right",
                tint: .secondary,
                url: Self.repository
            )
        }

        Text("No account, no daemon, no stored credentials — just your own SSH key.")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            .padding(.top, 2)
    }

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "Version \(short) (\($0))" } ?? "Version \(short)"
    }
}

/// A row that opens something in the browser.
private struct LinkRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color
    let url: URL

    @Environment(\.openURL) private var openURL
    @State private var isHovering = false

    var body: some View {
        Button { openURL(url) } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(tint)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13))
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(minHeight: 40)
            .background(Color.primary.opacity(isHovering ? 0.05 : 0))
            .contentShape(.rect)
        }
        .buttonStyle(.pressable)
        .onHover { isHovering = $0 }
    }
}

/// Explains an empty card, so a group with nothing in it still says what
/// would go there.
struct RowPlaceholder: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
    }
}
