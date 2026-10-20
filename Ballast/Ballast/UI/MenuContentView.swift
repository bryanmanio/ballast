import SwiftUI

/// Which containers the list is showing. Only offered once there is
/// something stopped to switch to.
private enum ContainerScope: String, CaseIterable, Identifiable {
    case running, stopped
    var id: String { rawValue }
    var label: String {
        switch self {
        case .running: "Running"
        case .stopped: "Stopped"
        }
    }
}

/// The popover: everything running, grouped by stack, with the things that
/// need attention visible without scrolling.
struct MenuContentView: View {
    let store: ContainerStore
    let settings: AppSettings
    /// The popover caps its list; the debug preview window doesn't need to.
    var maxListHeight: CGFloat = 460

    @State private var searchText = ""
    /// Measured height of the list's contents. A ScrollView has no intrinsic
    /// height, so inside a popover — which sizes itself to its content — it
    /// collapses to nothing unless given an explicit height.
    @State private var contentHeight: CGFloat = 0
    @State private var showingSettings = false
    @State private var showingHistory = false
    @State private var showingSearch = false
    @State private var scope: ContainerScope = .running
    @FocusState private var searchFocused: Bool

    private var hasStopped: Bool { !store.stoppedContainers.isEmpty }

    /// Floor for the list, so the popover can never collapse to zero height.
    private static let minListHeight: CGFloat = 44

    var body: some View {
        VStack(spacing: 0) {
            if showingSettings {
                paneHeader("Settings") { showingSettings = false }
                Divider()
                SettingsView(settings: settings, store: store)
            } else if showingHistory {
                paneHeader("History") { showingHistory = false }
                Divider()
                HistoryView(store: store)
            } else {
                listBody
            }
        }
        .frame(width: 340)
        // Quit lives here because the app has no Dock icon and no app menu,
        // so without it there would be no way to quit from the UI at all.
        .contextMenu {
            Button("Quit Ballast") { NSApplication.shared.terminate(nil) }
        }
        .onAppear {
            // Opening the menu is an explicit request for current data, but
            // don't re-fetch if we just did.
            if store.lastRefresh.map({ Date().timeIntervalSince($0) > 5 }) ?? true {
                Task { await store.refresh() }
            }
        }
    }

    private var listBody: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let actionError = store.actionError {
                NoticeBanner(messages: [actionError], isProblem: true)
                Divider()
            } else if let error = store.lastError {
                ErrorBanner(error: error)
                Divider()
            } else if !store.warnings.isEmpty {
                NoticeBanner(messages: store.warnings)
                Divider()
            }

            if showingSearch {
                searchField
            }

            if hasStopped {
                scopePicker
            }

            content
        }
    }

    /// Header for a pane that replaces the list, with the way back.
    private func paneHeader(_ title: String, close: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            Button {
                withAnimation(.easeInOut(duration: 0.15), close)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.pressable)
            .help("Back to the container list")

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            // Baseline-aligned so the smaller summary sits on the same line
            // as the title rather than floating at its centre.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Ballast")
                    .font(.system(size: 13, weight: .semibold))

                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Grouped so the adjacent controls read as one piece of glass
            // rather than three separate blobs.
            GlassEffectContainer(spacing: 4) {
                HStack(spacing: 4) {
                    HeaderButton(
                        symbol: "magnifyingglass",
                        help: "Filter containers",
                        isActive: showingSearch
                    ) {
                        withAnimation(.easeInOut(duration: 0.12)) { showingSearch.toggle() }
                        if showingSearch {
                            searchFocused = true
                        } else {
                            searchText = ""
                        }
                    }

                    HeaderButton(symbol: "arrow.clockwise", help: "Refresh now") {
                        Task { await store.refresh() }
                    }
                    .disabled(store.isRefreshing)
                    .opacity(store.isRefreshing ? 0.4 : 1)

                    HeaderButton(symbol: "clock.arrow.circlepath", help: "Downtime history") {
                        withAnimation(.easeInOut(duration: 0.15)) { showingHistory = true }
                    }

                    HeaderButton(symbol: "gearshape", help: "Settings") {
                        withAnimation(.easeInOut(duration: 0.15)) { showingSettings = true }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var summary: String {
        let running = store.visibleContainers.count { $0.state.isUp }
        guard running > 0 || !store.containers.isEmpty else { return "" }
        let problems = store.problemCount
        return problems > 0 ? "\(running) up · \(problems) need attention" : "\(running) up"
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            TextField("Filter", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
                .onExitCommand {
                    searchText = ""
                    showingSearch = false
                }
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        // The glyph stays small, but the target doesn't: 10pt
                        // of hittable area is a dart throw with a mouse.
                        // Nothing sits beside it, so the larger shape can't
                        // steal a click from another control.
                        .frame(width: 18, height: 18)
                        .contentShape(.circle)
                }
                .buttonStyle(.pressable)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    /// Lets stopped containers be reached in one click rather than a scroll
    /// to the bottom of a long list.
    private var scopePicker: some View {
        ScopeControl(scope: $scope)
            .padding(.horizontal, 10)
            .padding(.top, showingSearch ? 6 : 12)
            .padding(.bottom, 6)
    }

    // MARK: Body

    @ViewBuilder
    private var content: some View {
        if !settings.isConfigured && store.containers.isEmpty {
            EmptyStateView(
                symbol: "cable.connector",
                title: "Connect to your NAS",
                message: "Run nas/deploy.sh on your Mac, then add the SSH destination in Settings."
            )
        } else if store.containers.isEmpty {
            EmptyStateView(
                symbol: store.lastError == nil ? "shippingbox" : "exclamationmark.triangle",
                title: store.lastError == nil ? "No containers" : "Nothing to show",
                message: store.lastError == nil
                    ? "The NAS reported no containers."
                    : "Ballast couldn't read the container list."
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if settings.hideProjectNames || scope == .stopped {
                        ForEach(visibleRows) { container in
                            row(for: container)
                        }
                    } else {
                        ForEach(filteredGroups) { group in
                            SectionHeader(title: group.name, count: group.containers.count)
                            ForEach(group.containers) { container in
                                row(for: container)
                            }
                        }
                    }

                    if visibleRows.isEmpty {
                        Text(searchText.isEmpty ? "Nothing here" : "Nothing matches “\(searchText)”")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
                // Dim, rather than discard, data we know is stale.
                .opacity(store.dataIsFresh ? 1 : 0.5)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    // Swapping scopes rebuilds the list, and the measurement
                    // passes through zero on the way. Letting that reach the
                    // frame collapses the popover to nothing, which the menu
                    // bar treats as a dismissal — so ignore it.
                    guard height > 0 else { return }
                    contentHeight = height
                }
            }
            .frame(height: min(max(contentHeight, Self.minListHeight), maxListHeight))
            .scrollIndicators(.never)
        }
    }

    private func row(for container: Container) -> some View {
        ContainerRow(
            container: container,
            assessment: store.assessment(for: container),
            endpoints: store.allEndpoints(for: container),
            isBusy: store.isBusy(container),
            lastExit: store.lastExit(for: container.name),
            isMuted: store.mutedContainerNames.contains(container.name),
            perform: { action in
                Task { await store.perform(action, on: container) }
            },
            onHide: {
                withAnimation(.easeInOut(duration: 0.15)) { store.hide(container) }
            },
            onToggleMute: {
                if store.mutedContainerNames.contains(container.name) {
                    store.unmute(container.name)
                } else {
                    store.mute(container)
                }
            }
        )
    }

    // MARK: Filtering

    /// The containers the current scope and filter actually show.
    private var visibleRows: [Container] {
        switch scope {
        case .running: filteredActive
        case .stopped: filteredStopped
        }
    }

    private var filteredActive: [Container] {
        searchText.isEmpty ? store.activeContainers : store.activeContainers.filter(matches)
    }

    private var filteredGroups: [ContainerGroup] {
        guard !searchText.isEmpty else { return store.activeGroups }
        return store.activeGroups.compactMap { group in
            let matches = group.containers.filter(self.matches)
            return matches.isEmpty ? nil : ContainerGroup(name: group.name, containers: matches)
        }
    }

    private var filteredStopped: [Container] {
        searchText.isEmpty ? store.stoppedContainers : store.stoppedContainers.filter(matches)
    }

    private func matches(_ container: Container) -> Bool {
        let needle = searchText.lowercased()
        return container.displayName.lowercased().contains(needle)
            || container.image.lowercased().contains(needle)
            || (container.composeProject?.lowercased().contains(needle) ?? false)
    }
}

/// The scope control: one piece of glass with a selection that moves between
/// halves, rather than two separate buttons sitting next to each other.
private struct ScopeControl: View {
    @Binding var scope: ContainerScope
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ContainerScope.allCases) { option in
                segment(for: option)
            }
        }
        // The track is the glass; the selection rides inside it.
        .padding(2)
        .glassEffect(.regular, in: .capsule)
    }

    private func segment(for option: ContainerScope) -> some View {
        let isSelected = scope == option
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) { scope = option }
        } label: {
            Text(option.label)
                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                // Each half takes an equal share, so the control spans the
                // full width of the menu.
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .contentShape(.capsule)
        }
        .buttonStyle(.pressable)
        .background {
            if isSelected {
                Capsule()
                    // Neutral rather than accent-tinted, matching how Finder
                    // marks the selected item in a toolbar group. Derived
                    // from `primary`, so it inverts correctly in light mode.
                    .fill(Color.primary.opacity(0.16))
                    // Shared identity, so the selection slides between
                    // halves instead of blinking from one to the other.
                    .matchedGeometryEffect(id: "scopeSelection", in: namespace)
            }
        }
    }
}

/// A header control rendered in Liquid Glass.
private struct HeaderButton: View {
    let symbol: String
    let help: String
    var isActive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 20, height: 20)
                .contentShape(.circle)
        }
        .buttonStyle(.pressable)
        .foregroundStyle(isActive ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        // Interactive in both states: an active button that stops responding
        // to the pointer reads as disabled.
        .glassEffect(isActive ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: .circle)
        .help(help)
    }
}

struct SectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
            Text("\(count)")
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 3)
    }
}

private struct ErrorBanner: View {
    let error: BallastError

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(error.title)
                    .font(.system(size: 11, weight: .semibold))
                Text(error.hint)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.1))
    }
}

/// Non-fatal problems the agent reported. Quieter than an error, but still
/// visible — a silently shorter list would be worse than a small notice.
private struct NoticeBanner: View {
    let messages: [String]
    var isProblem = false

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: isProblem ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(isProblem ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            VStack(alignment: .leading, spacing: 1) {
                ForEach(messages, id: \.self) { message in
                    Text(message)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(isProblem ? Color.orange.opacity(0.1) : Color.secondary.opacity(0.08))
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 12, weight: .medium))
            Text(message)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
    }
}
