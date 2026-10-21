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

/// Which pane the popover is showing. One value rather than a flag apiece,
/// so there is no state in which two of them are up at once. Settings isn't
/// among them — those live in their own window.
private enum Pane {
    case list, history
}

/// The popover: everything running, grouped by stack, with the things that
/// need attention visible without scrolling.
struct MenuContentView: View {
    let store: ContainerStore
    let settings: AppSettings
    /// The popover caps its list; the debug preview window doesn't need to.
    var maxListHeight: CGFloat = 460

    @Environment(\.openWindow) private var openWindow

    @State private var searchText = ""
    /// Measured height of the list's contents. A ScrollView has no intrinsic
    /// height, so inside a popover — which sizes itself to its content — it
    /// collapses to nothing unless given an explicit height.
    @State private var contentHeight: CGFloat = 0
    @State private var pane: Pane = .list
    @State private var showingSearch = false
    @State private var scope: ContainerScope = .running
    @FocusState private var searchFocused: Bool

    private var hasStopped: Bool { !store.stoppedContainers.isEmpty }

    /// Floor for the list, so the popover can never collapse to zero height.
    private static let minListHeight: CGFloat = 44

    var body: some View {
        // Overlaid rather than stacked: mid-transition both panes exist, and
        // in a VStack that would briefly make the popover as tall as the two
        // of them together.
        ZStack(alignment: .top) {
            switch pane {
            case .list:
                listBody
                    .transition(Self.paneTransition(from: -14))
            case .history:
                paneBody("History") { HistoryView(store: store) }
                    .transition(Self.paneTransition(from: 14))
            }
        }
        .frame(width: 340)
        // Quit lives here because the app has no Dock icon and no app menu,
        // so without it there would be no way to quit from the UI at all.
        .contextMenu {
            Button("Quit Ballast") { NSApplication.shared.terminate(nil) }
                // Only live while this menu is open — an agent app has no app
                // menu to own ⌘Q — but it labels the item the way every other
                // Mac app labels Quit.
                .keyboardShortcut("q")
        }
        // Escape steps back out of a pane. With the list already showing
        // there is nothing to step back to, so the key is left alone and goes
        // on dismissing the popover the way it does in any other menu.
        .onExitCommand(perform: pane == .list ? nil : { show(.list) })
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
                    // Opacity alone: the field's arrival already moves
                    // everything under it, and sliding as well would be two
                    // motions for one change.
                    .transition(.opacity)
            }

            if hasStopped {
                scopePicker
            }

            content
        }
    }

    /// Panes travel in from the side they conceptually sit on — a forward
    /// pane from the right, the list back in from the left — so stepping in
    /// and out again reads as one movement rather than two cuts.
    private static func paneTransition(from offset: CGFloat) -> AnyTransition {
        .offset(x: offset).combined(with: .opacity)
    }

    private func show(_ next: Pane) {
        withAnimation(.easeInOut(duration: 0.15)) { pane = next }
    }

    /// A pane that replaces the list: its own header carrying the way back,
    /// then its content.
    private func paneBody<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            paneHeader(title) { show(.list) }
            Divider()
            content()
        }
    }

    /// Header for a pane that replaces the list, with the way back.
    private func paneHeader(_ title: String, close: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            Button(action: close) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.pressable)
            .help("Back to the container list (esc)")

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
                        help: "Filter containers (⌘F)",
                        shortcut: KeyboardShortcut("f"),
                        isActive: showingSearch,
                        action: toggleSearch
                    )

                    HeaderButton(
                        symbol: "arrow.clockwise",
                        help: "Refresh now (⌘R)",
                        shortcut: KeyboardShortcut("r")
                    ) {
                        Task { await store.refresh() }
                    }
                    .disabled(store.isRefreshing)
                    .opacity(store.isRefreshing ? 0.4 : 1)

                    HeaderButton(
                        symbol: "clock.arrow.circlepath",
                        help: "Downtime history (⌘Y)",
                        shortcut: KeyboardShortcut("y")
                    ) {
                        show(.history)
                    }

                    HeaderButton(
                        symbol: "gearshape",
                        help: "Settings (⌘,)",
                        shortcut: KeyboardShortcut(",")
                    ) {
                        // Settings are a window now, not a pane: a source
                        // list doesn't fit in 340 points, and an agent app
                        // isn't frontmost, so it has to be brought forward.
                        NSApp.activate(ignoringOtherApps: true)
                        openWindow(id: "settings")
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

    /// ⌘F and the magnifying glass share this. Pressing either with the
    /// field already up and focused is how you put it away; an unfocused
    /// field gets the caret back instead of being dismissed out from under
    /// the thing you were about to type into.
    private func toggleSearch() {
        if showingSearch && searchFocused {
            closeSearch()
        } else if showingSearch {
            searchFocused = true
        } else {
            withAnimation(.easeInOut(duration: 0.12)) { showingSearch = true }
            searchFocused = true
        }
    }

    private func closeSearch() {
        searchText = ""
        withAnimation(.easeInOut(duration: 0.12)) { showingSearch = false }
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            TextField("Filter", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
                .onExitCommand { closeSearch() }

            if !searchText.isEmpty {
                // How much of the list is left, so a filter that hides most
                // of it says so rather than just looking like a short list.
                Text("\(visibleRows.count) of \(scopeTotal)")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)

                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        // The glyph stays small, but the target doesn't: 10pt
                        // of hittable area is a dart throw with a mouse.
                        // The count beside it isn't a control, so the
                        // larger shape can't steal anyone's click.
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
                // Deliberately not the old "run nas/deploy.sh" line: it named
                // a path in a repo the user may never have had. Setup now
                // carries its own copy of that script, and its own commands.
                message: "Ballast needs a few minutes of setup on your NAS.",
                actionTitle: "Set up Ballast…",
                action: openOnboarding
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

    /// An agent app isn't frontmost when its menu bar icon is clicked, so
    /// without this the window opens behind whatever the user was looking at.
    private func openOnboarding() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "onboarding")
    }

    private func row(for container: Container) -> some View {
        ContainerRow(
            container: container,
            assessment: store.assessment(for: container),
            endpoints: store.allEndpoints(for: container),
            isBusy: store.isBusy(container),
            lastExit: store.lastExit(for: container.name),
            isMuted: store.mutedContainerNames.contains(container.name),
            update: store.updateStatus(for: container),
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

    /// What the current scope holds before filtering, so the count beside
    /// the field reads as "3 of 18" rather than as a bare number.
    private var scopeTotal: Int {
        switch scope {
        case .running: store.activeContainers.count
        case .stopped: store.stoppedContainers.count
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
    /// Hidden controls can't be reached by eye, so each one that matters is
    /// also a key away. The hint lives in `help`, since there is no room for
    /// a visible label at this size.
    var shortcut: KeyboardShortcut?
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
        .keyboardShortcut(shortcut)
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
    /// Present only when the state has something the user can do about it.
    var actionTitle: String?
    var action: () -> Void = {}

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
            if let actionTitle {
                Button(actionTitle, action: action)
                    .controlSize(.small)
                    .padding(.top, 3)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
    }
}
