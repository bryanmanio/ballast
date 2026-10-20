import ServiceManagement
import SwiftUI

/// Settings, laid out for the width of the menu rather than a separate
/// window: labels sit above their fields so nothing is cramped at 340pt.
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
            VStack(alignment: .leading, spacing: 14) {
                nasSection
                urlSection
                appearanceSection
                hiddenSection
                behaviourSection
                notificationsSection
                advancedSection
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

    // MARK: Sections

    private var nasSection: some View {
        SettingsSection("NAS") {
            LabelledField("SSH destination", text: $settings.sshDestination, prompt: "ballast@nas.local")
                .onSubmit { runTest() }

            HStack(spacing: 6) {
                Button("Test connection") { runTest() }
                    .controlSize(.small)
                    .disabled(!settings.isConfigured || isRunning)
                if isRunning { ProgressView().controlSize(.small) }
            }

            testResult

            Caption("Ballast uses your existing SSH key. It stores no password or token.")
        }
    }

    private var urlSection: some View {
        SettingsSection("Service URLs") {
            LabelledField(
                "Local hostname",
                text: $settings.lanHost,
                prompt: settings.effectiveLANHost.isEmpty ? "nas.local" : settings.effectiveLANHost
            )
            LabelledField("Remote hostname", text: $settings.remoteHost, prompt: "100.x.y.z")
            Caption("Used to build each service's URL. The remote hostname is used whenever the local one doesn't answer, so the menu keeps working away from home.")
        }
    }

    private var appearanceSection: some View {
        SettingsSection("Appearance") {
            Picker("Sort by", selection: $settings.sortOrder) {
                ForEach(ContainerSortOrder.allCases) { order in
                    Text(order.label).tag(order)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Toggle("Hide project names", isOn: $settings.hideProjectNames)
                .help("Show one flat list instead of grouping containers under their compose stack.")
        }
    }

    /// Only present when something is hidden, so it isn't an empty box most
    /// of the time.
    @ViewBuilder
    private var hiddenSection: some View {
        let hidden = store.hiddenContainerNames
        if !hidden.isEmpty {
            SettingsSection("Hidden") {
                ForEach(hidden, id: \.self) { name in
                    HStack(spacing: 6) {
                        Text(name)
                            .font(.system(size: 11))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Button {
                            store.unhide(name)
                        } label: {
                            Text("Show")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .help("Show \(name) in the menu again")
                    }
                }
                Caption("Hidden with “Hide from menu” on a container's right-click menu. This is stored on this Mac; it doesn't change anything on the NAS.")
            }
        }
    }

    private var behaviourSection: some View {
        SettingsSection("Behaviour") {
            Picker("Refresh every", selection: $settings.refreshInterval) {
                Text("10 seconds").tag(10.0)
                Text("30 seconds").tag(30.0)
                Text("1 minute").tag(60.0)
                Text("5 minutes").tag(300.0)
            }

            Toggle("Check that services respond", isOn: $settings.probeEnabled)
                .help("Requests each service's URL as well as reading Docker's state. Catches a container that is running but wedged, at the cost of occasional false alarms.")

            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }

            if let launchAtLoginError {
                Text(launchAtLoginError)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var notificationsSection: some View {
        SettingsSection("Notifications") {
            Toggle("Notify when a container exits unexpectedly", isOn: $settings.notifyOnUnexpectedExit)
                .onChange(of: settings.notifyOnUnexpectedExit) { _, enabled in
                    if enabled { enableNotifications() } else { notificationsBlocked = false }
                }

            if notificationsBlocked
                || (settings.notifyOnUnexpectedExit && store.notificationAuthorization == .denied) {
                Text("macOS is blocking notifications from Ballast. Allow them in System Settings → Notifications.")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Caption("Only a non-zero exit code or an out-of-memory kill notifies. A clean exit, a container Docker already restarted, and anything you stop from Ballast are recorded in History but stay quiet.")

            let muted = store.mutedContainerNames
            ForEach(muted, id: \.self) { name in
                HStack(spacing: 6) {
                    Text(name)
                        .font(.system(size: 11))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button {
                        store.unmute(name)
                    } label: {
                        Text("Unmute")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .help("Notify about \(name) again")
                }
            }
            if !muted.isEmpty {
                Caption("Muted with “Mute exit notifications” on a container's right-click menu. A container can also opt out from its compose file with the ballast.notify=false label.")
            }

            HStack(spacing: 6) {
                Button("Send a test notification") { sendTestNotification() }
                    .controlSize(.small)
                    .help("Posts a sample notification so you can check they arrive without waiting for something to break")

                if testNotificationSent {
                    Text("Sent")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }

            Button("Clear history") { store.clearHistory() }
                .controlSize(.small)
                .disabled(store.history.isEmpty)
        }
    }

    private var advancedSection: some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 10) {
                LabelledField("Agent path", text: $settings.agentPath, prompt: SSHContainerSource.defaultAgentPath)
                HStack {
                    Text("Reachability port")
                        .font(.system(size: 11))
                    Spacer()
                    TextField("", value: $settings.reachabilityPort, format: .number)
                        .frame(width: 60)
                        .multilineTextAlignment(.trailing)
                }
            }
            .padding(.top, 6)
        } label: {
            SectionLabel("Advanced")
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
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.green)
                Text("Connected — Docker \(check.dockerServerVersion)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        case .failure(let error):
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 1) {
                    Text(error.title).font(.system(size: 10.5, weight: .medium))
                    Text(error.hint)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
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

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}

private struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Label above field, so a long value isn't squeezed into half the width.
private struct LabelledField: View {
    let title: String
    @Binding var text: String
    let prompt: String

    init(_ title: String, text: Binding<String>, prompt: String) {
        self.title = title
        self._text = text
        self.prompt = prompt
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11))
            TextField("", text: $text, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
        }
    }
}

/// A titled group of controls. Stands in for Form's Section, which needs a
/// List or Form around it and reads badly at the width of a menu.
private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionLabel(title)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
