import Foundation
import Observation

/// A section in the menu: one compose stack, or the loose containers.
struct ContainerGroup: Identifiable, Sendable {
    var name: String
    var containers: [Container]
    var id: String { name }
}

/// The app's single source of truth: fetches, probes, assesses, and holds the
/// result for the menu to render.
@MainActor
@Observable
final class ContainerStore {
    private(set) var containers: [Container] = []
    private(set) var assessments: [String: StatusAssessment] = [:]
    private(set) var endpoints: [String: [ServiceEndpoint]] = [:]
    private(set) var probes: [String: ProbeOutcome] = [:]
    private(set) var hostSelection: HostSelection?
    private(set) var lastRefresh: Date?
    private(set) var lastError: BallastError?
    private(set) var isRefreshing = false
    private(set) var consecutiveFailures = 0
    /// Non-fatal problems reported by the agent on the last successful fetch.
    private(set) var warnings: [String] = []
    /// Containers with a start/stop/restart in flight, so their row can show
    /// progress and refuse a second click.
    private(set) var busy: Set<String> = []
    /// Last action failure, shown in the banner.
    private(set) var actionError: String?
    /// False once we've lost confidence that the container list reflects
    /// reality. A single failed poll is tolerated, since a brief SSH hiccup
    /// shouldn't blank the whole menu.
    private(set) var dataIsFresh = true
    /// Exits, crash-restarts and starts seen across polls, oldest first.
    private(set) var history: [DowntimeEvent]
    private(set) var notificationAuthorization: NotificationAuthorization = .notDetermined

    /// How many consecutive failures we tolerate before declaring the data stale.
    private static let staleAfterFailures = 2

    /// How long after a start/stop/restart from the menu an exit is taken to
    /// be the user's doing rather than a crash. `docker stop` waits out its
    /// grace period before killing, so the exit can land well after the click.
    private static let userActionWindow: TimeInterval = 90

    private let settings: AppSettings
    private let makeSource: @MainActor (AppSettings) -> ContainerSource
    private let probe: any ServiceProbing
    private let historyStore: any DowntimeHistoryStoring
    private let notifier: any ExitNotifying
    /// False when driven by fixtures, which need no SSH destination.
    private let requiresSSHConfiguration: Bool
    private var pollTask: Task<Void, Never>?
    /// The last successful poll, reduced to what transitions are detected
    /// from. Deliberately untouched by a failed poll, so an outage can never
    /// look like containers exiting.
    private var previousSnapshot: [String: ContainerSnapshot] = [:]
    /// Container names the user has just started, stopped or restarted.
    private var recentActions: [String: Date] = [:]

    /// The history and notifier defaults touch neither disk nor the
    /// notification centre, so a store built without them (tests, previews)
    /// can't write to the real log. The app passes the real ones.
    init(
        settings: AppSettings,
        probe: any ServiceProbing = ServiceProbe(),
        historyStore: any DowntimeHistoryStoring = InMemoryDowntimeHistoryStore(),
        notifier: any ExitNotifying = DisabledExitNotifier(),
        requiresSSHConfiguration: Bool = true,
        makeSource: @MainActor @escaping (AppSettings) -> ContainerSource = { settings in
            SSHContainerSource(destination: settings.sshDestination, agentPath: settings.agentPath)
        }
    ) {
        self.settings = settings
        self.probe = probe
        self.historyStore = historyStore
        self.notifier = notifier
        self.history = historyStore.load()
        self.requiresSSHConfiguration = requiresSSHConfiguration
        self.makeSource = makeSource
    }

    // MARK: - Derived state

    /// Containers the user wants to see: neither opted out on the NAS with
    /// `ballast.hide`, nor hidden from this Mac.
    var visibleContainers: [Container] {
        containers.filter { !$0.isHidden && !settings.hiddenContainers.contains($0.name) }
    }

    /// Hidden here rather than on the NAS, so they can be restored from
    /// Settings. Names only — the container may not even exist any more.
    var hiddenContainerNames: [String] {
        settings.hiddenContainers.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func hide(_ container: Container) {
        settings.hiddenContainers.insert(container.name)
    }

    func unhide(_ name: String) {
        settings.hiddenContainers.remove(name)
    }

    // MARK: - History and notifications

    /// Newest first.
    func events(for name: String) -> [DowntimeEvent] {
        history.filter { $0.containerName == name }.reversed()
    }

    /// The most recent time this container went down, for its tooltip.
    func lastExit(for name: String) -> DowntimeEvent? {
        history.last { $0.containerName == name && $0.kind != .started }
    }

    func clearHistory() {
        historyStore.clear()
        history = []
    }

    var mutedContainerNames: [String] {
        settings.mutedContainers.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func mute(_ container: Container) {
        settings.mutedContainers.insert(container.name)
    }

    func unmute(_ name: String) {
        settings.mutedContainers.remove(name)
    }

    /// Posts a sample notification so the user can see whether notifications
    /// actually arrive, without waiting for something to break.
    ///
    /// Deliberately not recorded in history: nothing happened on the NAS.
    /// Returns false when macOS refused permission.
    func sendTestNotification() async -> Bool {
        guard await requestNotificationAuthorization() else { return false }
        await notifier.post([
            DowntimeEvent(
                containerName: "ballast-test",
                kind: .exited,
                at: Date(),
                exitCode: 137,
                image: "ballast/test:latest"
            )
        ])
        return true
    }

    func refreshNotificationAuthorization() async {
        notificationAuthorization = await notifier.authorizationStatus()
    }

    /// Asks macOS for permission. Only called when the user turns
    /// notifications on, not at launch: a menu bar app with no window has no
    /// context to explain a permission prompt.
    func requestNotificationAuthorization() async -> Bool {
        let granted = await notifier.requestAuthorization()
        await refreshNotificationAuthorization()
        return granted
    }

    /// Everything that should be up, as one flat list.
    var activeContainers: [Container] {
        sorted(visibleContainers.filter { $0.state.isUp })
    }

    /// Compose stacks of containers that are meant to be up, loose ones last.
    var activeGroups: [ContainerGroup] {
        let grouped = Dictionary(grouping: visibleContainers.filter { $0.state.isUp }) {
            $0.composeProject ?? ""
        }

        return grouped
            .map { project, containers in
                ContainerGroup(name: project.isEmpty ? "Other" : project, containers: sorted(containers))
            }
            .sorted { lhs, rhs in
                // "Other" is a catch-all, so it belongs at the bottom.
                if (lhs.name == "Other") != (rhs.name == "Other") { return rhs.name == "Other" }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    var stoppedContainers: [Container] {
        sorted(visibleContainers.filter { !$0.state.isUp })
    }

    /// Applies the user's chosen order. Status sorting puts whatever needs
    /// attention first and falls back to alphabetical within each status, so
    /// a list with nothing wrong still reads alphabetically.
    func sorted(_ containers: [Container]) -> [Container] {
        containers.sorted { lhs, rhs in
            if settings.sortOrder == .status {
                let left = assessment(for: lhs).status
                let right = assessment(for: rhs).status
                if left != right { return left > right }
            }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    func assessment(for container: Container) -> StatusAssessment {
        assessments[container.id] ?? StatusAssessment(status: .unknown, reason: "No data yet")
    }

    func primaryEndpoint(for container: Container) -> ServiceEndpoint? {
        endpoints[container.id]?.first
    }

    func allEndpoints(for container: Container) -> [ServiceEndpoint] {
        endpoints[container.id] ?? []
    }

    /// Worst status across everything that should be up. Stopped containers
    /// are excluded on purpose: a container the user deliberately stopped
    /// shouldn't light up the menu bar forever.
    var overallStatus: ServiceStatus {
        guard dataIsFresh else { return .unknown }
        let relevant = visibleContainers.filter { $0.state.isUp }.map { assessment(for: $0) }
        return StatusResolver.aggregate(relevant)
    }

    var problemCount: Int {
        visibleContainers
            .filter { $0.state.isUp }
            .count { assessment(for: $0).status >= .degraded }
    }

    // MARK: - Polling

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                if self?.settings.autoRefreshEnabled == true {
                    await self?.refresh()
                }
                guard let interval = self?.currentPollInterval else { return }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Backs off after repeated failures so a sleeping NAS isn't hammered
    /// every 30 seconds all night.
    private var currentPollInterval: TimeInterval {
        // Paused, the loop still has to come round often enough to notice
        // being switched back on, so it idles on a short tick instead of
        // whatever interval it would have polled at.
        guard settings.autoRefreshEnabled else { return 5 }
        return consecutiveFailures >= 3 ? min(120, settings.refreshInterval * 4) : settings.refreshInterval
    }

    // MARK: - Refresh

    func refresh() async {
        guard !isRefreshing else { return }
        guard settings.isConfigured || !requiresSSHConfiguration else {
            lastError = .notConfigured
            dataIsFresh = false
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        let source = makeSource(settings)
        let resolver = HostResolver(
            lanHost: settings.effectiveLANHost,
            remoteHost: settings.remoteHost,
            port: settings.reachabilityPort
        )

        async let selectionTask = resolver.resolve()

        do {
            let output = try await source.fetch()
            hostSelection = await selectionTask
            let notifiable = recordTransitions(in: output.containers)
            containers = output.containers
            warnings = output.warnings
            dataIsFresh = true
            lastError = nil
            consecutiveFailures = 0
            lastRefresh = Date()

            recomputeEndpoints()
            recomputeAssessments()

            if !notifiable.isEmpty { await notifier.post(notifiable) }

            // Probing happens after the list is already on screen, so the
            // menu updates immediately and sharpens a moment later.
            await runProbes()
        } catch {
            hostSelection = await selectionTask
            let failure = error as? BallastError
                ?? .agentFailed(exitCode: -1, detail: error.localizedDescription)
            lastError = failure
            consecutiveFailures += 1
            lastRefresh = Date()

            if consecutiveFailures >= Self.staleAfterFailures {
                dataIsFresh = false
                probes.removeAll()
            }
            recomputeAssessments()
        }
    }

    /// Starts, stops or restarts a container, then refreshes so the result
    /// is visible rather than inferred.
    func perform(_ action: ContainerAction, on container: Container) async {
        guard !busy.contains(container.id) else { return }
        busy.insert(container.id)
        actionError = nil
        defer { busy.remove(container.id) }

        // Marked before as well as after: a poll already in flight can see
        // the result of the action while it is still running.
        recentActions[container.name] = Date()

        do {
            try await makeSource(settings).perform(action, on: container.id)
        } catch let error as BallastError {
            actionError = "\(action.verb) \(container.displayName) failed — \(error.hint)"
        } catch {
            actionError = "\(action.verb) \(container.displayName) failed — \(error.localizedDescription)"
        }

        recentActions[container.name] = Date()
        await refresh()
    }

    func isBusy(_ container: Container) -> Bool {
        busy.contains(container.id)
    }

    /// Runs `ballast-agent check`, for the Settings "Test connection" button.
    func testConnection() async -> Result<AgentCheck, BallastError> {
        let source = makeSource(settings)
        do {
            return .success(try await source.check())
        } catch let error as BallastError {
            return .failure(error)
        } catch {
            return .failure(.agentFailed(exitCode: -1, detail: error.localizedDescription))
        }
    }

    // MARK: - Internals

    /// Diffs the fetched list against the last one, records what changed, and
    /// returns the events that should notify.
    ///
    /// Compared even when the data had gone stale: the snapshot only ever
    /// comes from a successful poll, so it is still the last thing we really
    /// knew. Skipping the comparison would lose exactly the exits that happen
    /// while the Mac is asleep or the NAS is unreachable.
    private func recordTransitions(in fetched: [Container]) -> [DowntimeEvent] {
        defer { previousSnapshot = DowntimeDetector.snapshot(fetched) }

        let now = Date()
        recentActions = recentActions.filter { now.timeIntervalSince($0.value) < Self.userActionWindow }

        let events = DowntimeDetector.events(
            previous: previousSnapshot,
            current: fetched,
            suppressed: Set(recentActions.keys),
            now: now
        )
        guard !events.isEmpty else { return [] }

        historyStore.append(events)
        history = historyStore.load()

        guard settings.notifyOnUnexpectedExit else { return [] }
        let optedOut = Set(fetched.filter(\.notifyOptOut).map(\.name))
        return events.filter {
            $0.isNotifiable
                && !settings.mutedContainers.contains($0.containerName)
                && !optedOut.contains($0.containerName)
        }
    }

    private func recomputeEndpoints() {
        let host = hostSelection?.host ?? settings.effectiveLANHost
        let byID = Dictionary(uniqueKeysWithValues: containers.map { ($0.id, $0) })

        // First pass: containers sharing another's network that match one of
        // its published ports exactly. Those ports are then off the table for
        // siblings that have to be guessed at.
        var claimed: [String: Set<Int>] = [:]
        for container in containers {
            guard let ownerID = container.networkOwnerID, let owner = byID[ownerID] else { continue }
            let matched = ServiceURLResolver.matchedOwnerPorts(for: container, owner: owner)
            if !matched.isEmpty {
                claimed[ownerID, default: []].formUnion(matched)
            }
        }

        endpoints = Dictionary(
            uniqueKeysWithValues: containers.map { container in
                let ownerID = container.networkOwnerID
                let owner = ownerID.flatMap { byID[$0] }
                return (
                    container.id,
                    ServiceURLResolver.endpoints(
                        for: container,
                        host: host,
                        networkOwner: owner,
                        claimedOwnerPorts: ownerID.flatMap { claimed[$0] } ?? []
                    )
                )
            }
        )
    }

    private func recomputeAssessments() {
        assessments = Dictionary(
            uniqueKeysWithValues: containers.map { container in
                (container.id, StatusResolver.assess(
                    container: container,
                    probe: probes[container.id],
                    dataIsFresh: dataIsFresh
                ))
            }
        )
    }

    private func runProbes() async {
        guard settings.probeEnabled, dataIsFresh else {
            probes.removeAll()
            recomputeAssessments()
            return
        }

        var targets: [String: URL] = [:]
        for container in containers where container.state.isUp && !container.isHidden {
            guard let endpoint = primaryEndpoint(for: container), endpoint.isProbeable else {
                probes[container.id] = .skipped(reason: "no HTTP endpoint")
                continue
            }
            targets[container.id] = endpoint.url
        }

        let results = await probe.probe(targets)
        // Discard if the container set changed underneath us mid-probe.
        for (id, outcome) in results where containers.contains(where: { $0.id == id }) {
            probes[id] = outcome
        }
        recomputeAssessments()
    }
}
