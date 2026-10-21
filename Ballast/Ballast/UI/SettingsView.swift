import ServiceManagement
import SwiftUI

/// Settings in the shape macOS System Settings uses: a titled group per
/// topic, each one a card of rows with the control on the right. Explanatory
/// copy is kept to the few places a control is genuinely ambiguous; the rest
/// lives in tooltips.
struct SettingsView: View {
    @Bindable var settings: AppSettings
    let store: ContainerStore

    @State private var test: TestState = .idle
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?
    @State private var showAdvanced = false
    /// Set when the user turns notifications on and macOS says no, so the
    /// reason is still on screen after the toggle has switched itself back off.
    @State private var notificationsBlocked = false
    /// Confirms the test notification went out, for the case where macOS
    /// shows the banner somewhere the user isn't looking.
    @State private var testNotificationSent = false

    enum TestState {
        case idle, running
        case success(AgentCheck)
        case failure(BallastError)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                connectionGroup
                serviceURLGroup
                appGroup
                menuGroup
                notificationsGroup
                mutedGroup
                hiddenGroup
                historyGroup
                advancedGroup
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
        .frame(maxHeight: 460)
        // Unlike the container list, settings give no hint that there is more
        // below the fold, so the scroller stays on to show how far down we are.
        .scrollIndicators(.automatic)
        .task { await store.refreshNotificationAuthorization() }
    }

    // MARK: Groups

    private var connectionGroup: some View {
        SettingsGroup("Connection") {
            SettingsRow("SSH destination") {
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
    }

    private var serviceURLGroup: some View {
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
            RowNote("Used when the local host doesn't answer.")
            RowDivider()
            SettingsRow(
                "Check services respond",
                help: "Requests each service's URL as well as reading Docker's state. Catches a container that is running but wedged, at the cost of occasional false alarms."
            ) {
                RowToggle(isOn: $settings.probeEnabled)
            }
        }
    }

    private var appGroup: some View {
        SettingsGroup("App") {
            SettingsRow("Launch at login") {
                RowToggle(isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
            }
            if let launchAtLoginError {
                RowNote(launchAtLoginError, tint: .orange)
            }
            RowDivider()
            SettingsRow("Refresh every") {
                Picker("", selection: $settings.refreshInterval) {
                    Text("10 seconds").tag(10.0)
                    Text("30 seconds").tag(30.0)
                    Text("1 minute").tag(60.0)
                    Text("5 minutes").tag(300.0)
                }
                .rowPicker()
            }
        }
    }

    private var menuGroup: some View {
        SettingsGroup("Menu") {
            SettingsRow("Sort by") {
                Picker("", selection: $settings.sortOrder) {
                    ForEach(ContainerSortOrder.allCases) { order in
                        Text(order.label).tag(order)
                    }
                }
                .rowPicker()
            }
            RowDivider()
            SettingsRow("Group by project", help: "Group containers under their compose stack instead of one flat list.") {
                RowToggle(isOn: Binding(
                    get: { !settings.hideProjectNames },
                    set: { settings.hideProjectNames = !$0 }
                ))
            }
        }
    }

    private var notificationsGroup: some View {
        SettingsGroup("Notifications") {
            SettingsRow(
                "Unexpected exits",
                help: "Only a non-zero exit code or an out-of-memory kill notifies. Clean exits and anything you stop yourself stay quiet."
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
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
                Button("Send") { sendTestNotification() }
                    .controlSize(.small)
            }
        }
    }

    /// Only present when something is muted, so it isn't an empty box most
    /// of the time.
    @ViewBuilder
    private var mutedGroup: some View {
        let muted = store.mutedContainerNames
        if !muted.isEmpty {
            SettingsGroup("Muted") {
                ForEach(Array(muted.enumerated()), id: \.element) { index, name in
                    if index > 0 { RowDivider() }
                    SettingsRow(name) {
                        Button("Unmute") { store.unmute(name) }
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var hiddenGroup: some View {
        let hidden = store.hiddenContainerNames
        if !hidden.isEmpty {
            SettingsGroup("Hidden") {
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

    private var historyGroup: some View {
        SettingsGroup("History") {
            SettingsRow("Recorded events") {
                Text("\(store.history.count)")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button("Clear") { store.clearHistory() }
                    .controlSize(.small)
                    .disabled(store.history.isEmpty)
            }
        }
    }

    private var advancedGroup: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showAdvanced.toggle() }
            } label: {
                HStack(spacing: 3) {
                    GroupLabel("Advanced")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.pressable)

            if showAdvanced {
                SettingsCard {
                    SettingsRow("Agent path") {
                        RowField(text: $settings.agentPath, prompt: SSHContainerSource.defaultAgentPath, width: 170)
                    }
                    RowDivider()
                    SettingsRow("Reachability port") {
                        TextField("", value: $settings.reachabilityPort, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                            .multilineTextAlignment(.trailing)
                            .frame(width: 60)
                    }
                }
            }
        }
    }

    // MARK: Test connection

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

// MARK: - Building blocks

/// The title above a card.
private struct GroupLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
    }
}

/// A group of related rows under a title, the unit System Settings is built
/// from.
private struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GroupLabel(title)
            SettingsCard { content }
        }
    }
}

private struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.06))
            }
    }
}

/// Label on the left, control on the right, on one line.
private struct SettingsRow<Trailing: View>: View {
    let title: String
    var help: String?
    @ViewBuilder var trailing: Trailing

    init(_ title: String, help: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.help = help
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minHeight: 30)
        .help(help ?? "")
    }
}

/// Secondary copy that belongs to the row above it, so it stays inside the
/// card rather than floating between groups.
private struct RowNote: View {
    let text: String
    var symbol: String?
    var tint: Color?
    var help: String?

    init(_ text: String, symbol: String? = nil, tint: Color? = nil, help: String? = nil) {
        self.text = text
        self.symbol = symbol
        self.tint = tint
        self.help = help
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 9))
                    .foregroundStyle(tint ?? .secondary)
            }
            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle(symbol == nil ? (tint ?? Color.secondary) : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .padding(.top, -2)
        .help(help ?? "")
    }
}

/// Inset on the leading edge, the way a grouped list separates its rows.
private struct RowDivider: View {
    var body: some View {
        Divider().padding(.leading, 10)
    }
}

private struct RowToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
    }
}

private struct RowField: View {
    @Binding var text: String
    let prompt: String
    var width: CGFloat = 160

    var body: some View {
        TextField("", text: $text, prompt: Text(prompt))
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11))
            .frame(width: width)
    }
}

private extension View {
    /// A popup sized to its selection, as the right-hand control of a row.
    func rowPicker() -> some View {
        self.pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            .font(.system(size: 11))
            .fixedSize()
    }
}
