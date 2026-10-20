import Foundation
import Testing
@testable import BallastCore

/// A source that returns whatever the test tells it to, including failures.
private final class StubSource: ContainerSource, @unchecked Sendable {
    var result: Result<AgentListOutput, BallastError>
    var actionError: BallastError?
    private(set) var fetchCount = 0
    private(set) var actions: [(ContainerAction, String)] = []

    init(containers: [Container]) {
        result = .success(AgentListOutput(protocolVersion: 1, containers: containers))
    }

    func fetch() async throws -> AgentListOutput {
        fetchCount += 1
        return try result.get()
    }

    func check() async throws -> AgentCheck {
        AgentCheck(protocolVersion: 1, dockerPath: "/usr/local/bin/docker",
                   dockerServerVersion: "24.0.2", agentPath: "/usr/local/bin/ballast-agent",
                   effectiveUID: 0)
    }

    func perform(_ action: ContainerAction, on container: String) async throws {
        actions.append((action, container))
        if let actionError { throw actionError }
    }
}

private struct StubProbe: ServiceProbing {
    var outcome: ProbeOutcome = .responded(statusCode: 200)
    func probe(_ targets: [String: URL]) async -> [String: ProbeOutcome] {
        targets.mapValues { _ in outcome }
    }
}

private func makeContainer(
    _ name: String,
    state: DockerState = .running,
    health: HealthState = .undefined,
    ports: [Int] = [],
    labels: [String: String] = [:]
) -> Container {
    Container(
        id: name, name: name, state: state, health: health, exitCode: 0,
        oomKilled: false, restartCount: 0, image: "\(name):latest",
        publishedPorts: ports.map {
            PortBinding(containerPort: $0, transport: "tcp", hostIP: "0.0.0.0", hostPort: $0)
        },
        exposedPorts: [], networkMode: "bridge", labels: labels,
        startedAt: nil, finishedAt: nil
    )
}

@MainActor
@Suite("Container store")
struct ContainerStoreTests {

    private func makeStore(
        containers: [Container],
        probe: any ServiceProbing = StubProbe()
    ) -> (ContainerStore, StubSource, AppSettings) {
        let defaults = UserDefaults(suiteName: "ballast-tests-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.sshDestination = "test@nas"
        settings.lanHost = "nas.local"
        // Probing is off by default; these tests are about probe behaviour.
        settings.probeEnabled = true
        let source = StubSource(containers: containers)
        let store = ContainerStore(settings: settings, probe: probe) { _ in source }
        return (store, source, settings)
    }

    @Test("a successful refresh populates containers, endpoints and statuses")
    func successfulRefresh() async {
        let (store, _, _) = makeStore(containers: [makeContainer("immich", ports: [2283])])
        await store.refresh()

        #expect(store.containers.count == 1)
        #expect(store.lastError == nil)
        #expect(store.dataIsFresh)
        let container = store.containers[0]
        #expect(store.primaryEndpoint(for: container)?.url.absoluteString == "http://nas.local:2283")
        #expect(store.assessment(for: container).status == .healthy)
    }

    @Test("containers are grouped by compose stack, with loose ones last")
    func grouping() async {
        let (store, _, _) = makeStore(containers: [
            makeContainer("loose"),
            makeContainer("web", labels: ["com.docker.compose.project": "paperless"]),
            makeContainer("db", labels: ["com.docker.compose.project": "paperless"]),
            makeContainer("api", labels: ["com.docker.compose.project": "immich"]),
        ])
        await store.refresh()

        #expect(store.activeGroups.map(\.name) == ["immich", "paperless", "Other"])
        #expect(store.activeGroups[1].containers.map(\.name) == ["db", "web"])
    }

    @Test("stopped containers are separated from running ones")
    func stoppedAreSeparate() async {
        let (store, _, _) = makeStore(containers: [
            makeContainer("up"),
            makeContainer("down", state: .exited),
        ])
        await store.refresh()

        #expect(store.activeGroups.flatMap(\.containers).map(\.name) == ["up"])
        #expect(store.stoppedContainers.map(\.name) == ["down"])
    }

    @Test("ballast.hide keeps a container out of the menu entirely")
    func hiddenContainers() async {
        let (store, _, _) = makeStore(containers: [
            makeContainer("visible"),
            makeContainer("secret", labels: ["ballast.hide": "true"]),
        ])
        await store.refresh()

        #expect(store.containers.count == 2)
        #expect(store.visibleContainers.map(\.name) == ["visible"])
    }

    @Test("one failed poll keeps the last known data on screen")
    func singleFailureIsTolerated() async {
        // An SSH hiccup shouldn't blank the whole menu.
        let (store, source, _) = makeStore(containers: [makeContainer("immich", ports: [2283])])
        await store.refresh()

        source.result = .failure(.timedOut)
        await store.refresh()

        #expect(store.dataIsFresh, "a single failure is tolerated")
        #expect(store.lastError == .timedOut, "but it is reported immediately")
        #expect(store.assessment(for: store.containers[0]).status == .healthy)
    }

    @Test("repeated failures stop the app claiming anything about status")
    func repeatedFailuresGoUnknown() async {
        let (store, source, _) = makeStore(containers: [makeContainer("immich", ports: [2283])])
        await store.refresh()

        source.result = .failure(.dockerUnavailable)
        await store.refresh()
        await store.refresh()

        #expect(store.dataIsFresh == false)
        #expect(store.containers.count == 1, "the list is kept, so the menu isn't empty")
        #expect(store.assessment(for: store.containers[0]).status == .unknown)
        #expect(store.overallStatus == .unknown)
    }

    @Test("recovering from failures restores freshness")
    func recovery() async {
        let (store, source, _) = makeStore(containers: [makeContainer("immich", ports: [2283])])
        source.result = .failure(.timedOut)
        await store.refresh()
        await store.refresh()
        #expect(store.dataIsFresh == false)

        source.result = .success(AgentListOutput(protocolVersion: 1, containers: [makeContainer("immich", ports: [2283])]))
        await store.refresh()

        #expect(store.dataIsFresh)
        #expect(store.lastError == nil)
        #expect(store.assessment(for: store.containers[0]).status == .healthy)
    }

    @Test("a failing probe degrades a running container")
    func probeDegrades() async {
        let (store, _, _) = makeStore(
            containers: [makeContainer("immich", ports: [2283])],
            probe: StubProbe(outcome: .timedOut)
        )
        await store.refresh()

        #expect(store.assessment(for: store.containers[0]).status == .degraded)
        #expect(store.problemCount == 1)
    }

    @Test("containers with no HTTP endpoint are not probed or penalised")
    func unprobeableContainers() async {
        let (store, _, _) = makeStore(
            containers: [makeContainer("redis", ports: [6379])],
            probe: StubProbe(outcome: .timedOut)
        )
        await store.refresh()

        // 6379 is a known non-HTTP port, so a failed probe must not be what
        // decides this container's status.
        #expect(store.assessment(for: store.containers[0]).status == .healthy)
        #expect(store.problemCount == 0)
    }

    @Test("turning probing off falls back to Docker state alone")
    func probingDisabled() async {
        let (store, _, settings) = makeStore(
            containers: [makeContainer("immich", ports: [2283])],
            probe: StubProbe(outcome: .refused)
        )
        settings.probeEnabled = false
        await store.refresh()

        #expect(store.assessment(for: store.containers[0]).status == .healthy)
    }

    @Test("stopped containers don't count toward the menu bar badge")
    func stoppedDoNotAlarm() async {
        // A container the user deliberately stopped shouldn't light up the
        // menu bar indefinitely.
        let (store, _, _) = makeStore(containers: [
            makeContainer("up", ports: [8080]),
            makeContainer("deliberately-off", state: .exited),
        ])
        await store.refresh()

        #expect(store.problemCount == 0)
        #expect(store.overallStatus == .healthy)
    }

    @Test("an unconfigured app reports that rather than failing obscurely")
    func notConfigured() async {
        let defaults = UserDefaults(suiteName: "ballast-tests-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        let source = StubSource(containers: [])
        let store = ContainerStore(settings: settings) { _ in source }

        await store.refresh()

        #expect(store.lastError == .notConfigured)
        #expect(source.fetchCount == 0, "no point dialing out with no destination")
    }

    @Test("concurrent refreshes don't stack up")
    func concurrentRefreshesCoalesce() async {
        let (store, source, _) = makeStore(containers: [makeContainer("immich")])
        async let first: Void = store.refresh()
        async let second: Void = store.refresh()
        _ = await (first, second)

        #expect(source.fetchCount == 1)
    }
}

@MainActor
@Suite("Settings defaults")
struct AppSettingsDefaultsTests {

    @Test("HTTP probing is off unless the user turns it on")
    func probingIsOptIn() {
        // Docker state is the trustworthy signal. The probe can report a
        // healthy service as degraded for reasons unrelated to the service,
        // so it must not be on by default.
        let defaults = UserDefaults(suiteName: "ballast-tests-\(UUID().uuidString)")!
        #expect(AppSettings(defaults: defaults).probeEnabled == false)
    }

    @Test("an explicit choice is remembered")
    func explicitChoiceWins() {
        let suite = "ballast-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        AppSettings(defaults: defaults).probeEnabled = true
        #expect(AppSettings(defaults: defaults).probeEnabled)
    }
}

@MainActor
@Suite("Sorting and grouping")
struct SortingTests {

    private func makeStore(_ containers: [Container]) -> (ContainerStore, AppSettings) {
        let defaults = UserDefaults(suiteName: "ballast-tests-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.sshDestination = "test@nas"
        settings.lanHost = "nas.local"
        let source = StubSource(containers: containers)
        let store = ContainerStore(settings: settings) { _ in source }
        return (store, settings)
    }

    @Test("project names are hidden by default")
    func projectNamesHiddenByDefault() {
        let defaults = UserDefaults(suiteName: "ballast-tests-\(UUID().uuidString)")!
        #expect(AppSettings(defaults: defaults).hideProjectNames)
    }

    @Test("status sorting puts problems first")
    func statusSortingSurfacesProblems() async {
        let (store, settings) = makeStore([
            makeContainer("alpha"),
            makeContainer("bravo", state: .restarting),
            makeContainer("charlie", health: .unhealthy),
            makeContainer("delta"),
        ])
        settings.sortOrder = .status
        await store.refresh()

        let names = store.activeContainers.map(\.name)
        #expect(names.prefix(2).sorted() == ["bravo", "charlie"], "degraded containers come first")
        #expect(Array(names.suffix(2)) == ["alpha", "delta"], "healthy ones follow, alphabetically")
    }

    @Test("status sorting still reads alphabetically when nothing is wrong")
    func statusSortingTiesAlphabetically() async {
        let (store, settings) = makeStore([
            makeContainer("zulu"), makeContainer("alpha"), makeContainer("mike"),
        ])
        settings.sortOrder = .status
        await store.refresh()

        #expect(store.activeContainers.map(\.name) == ["alpha", "mike", "zulu"])
    }

    @Test("name sorting ignores status entirely")
    func nameSorting() async {
        let (store, settings) = makeStore([
            makeContainer("zulu", state: .restarting),
            makeContainer("alpha"),
        ])
        settings.sortOrder = .name
        await store.refresh()

        #expect(store.activeContainers.map(\.name) == ["alpha", "zulu"])
    }

    @Test("the flat list holds the same containers as the groups")
    func flatListMatchesGroups() async {
        let (store, _) = makeStore([
            makeContainer("a", labels: ["com.docker.compose.project": "one"]),
            makeContainer("b", labels: ["com.docker.compose.project": "two"]),
            makeContainer("c"),
            makeContainer("stopped", state: .exited),
        ])
        await store.refresh()

        #expect(store.activeContainers.map(\.name).sorted()
            == store.activeGroups.flatMap(\.containers).map(\.name).sorted())
        #expect(store.activeContainers.contains { $0.name == "stopped" } == false)
    }

    @Test("sorting applies inside groups too")
    func sortingAppliesWithinGroups() async {
        let (store, settings) = makeStore([
            makeContainer("web", labels: ["com.docker.compose.project": "stack"]),
            makeContainer("db", state: .restarting, labels: ["com.docker.compose.project": "stack"]),
        ])
        settings.sortOrder = .status
        await store.refresh()

        let group = try! #require(store.activeGroups.first)
        #expect(group.containers.map(\.name) == ["db", "web"])
    }
}

@MainActor
@Suite("Container actions")
struct ContainerActionTests {

    private func makeStore(_ containers: [Container]) -> (ContainerStore, StubSource) {
        let defaults = UserDefaults(suiteName: "ballast-tests-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.sshDestination = "test@nas"
        settings.lanHost = "nas.local"
        let source = StubSource(containers: containers)
        return (ContainerStore(settings: settings) { _ in source }, source)
    }

    @Test("an action is sent for the right container and then refreshes")
    func performsAction() async {
        let (store, source) = makeStore([makeContainer("immich")])
        await store.refresh()
        let container = store.containers[0]

        await store.perform(.restart, on: container)

        #expect(source.actions.count == 1)
        #expect(source.actions[0].0 == .restart)
        #expect(source.actions[0].1 == container.id)
        // Refreshed afterwards, so the row reflects the real outcome rather
        // than an assumed one.
        #expect(source.fetchCount == 2)
    }

    @Test("a failed action is reported and doesn't leave the row stuck")
    func reportsFailure() async {
        let (store, source) = makeStore([makeContainer("immich")])
        await store.refresh()
        source.actionError = .dockerUnavailable

        await store.perform(.stop, on: store.containers[0])

        #expect(store.actionError?.contains("Stop") == true)
        #expect(store.actionError?.contains("immich") == true)
        #expect(store.isBusy(store.containers[0]) == false)
    }

    @Test("the busy flag clears after success")
    func busyClears() async {
        let (store, _) = makeStore([makeContainer("immich")])
        await store.refresh()

        await store.perform(.start, on: store.containers[0])
        #expect(store.isBusy(store.containers[0]) == false)
    }

    @Test("every action maps to a distinct agent subcommand")
    func actionsAreDistinct() {
        #expect(Set(ContainerAction.allCases.map(\.rawValue)).count == ContainerAction.allCases.count)
        #expect(ContainerAction.restart.rawValue == "restart")
        #expect(ContainerAction.stop.rawValue == "stop")
        #expect(ContainerAction.start.rawValue == "start")
    }

    @Test("the container reference is passed as its own argument, not interpolated")
    func argumentIsSeparate() throws {
        // Keeps anything in a container name from reaching a shell on the NAS.
        let args = SSHContainerSource.sshArguments(
            destination: "nas", agentPath: "/usr/local/bin/ballast-agent",
            subcommand: "restart", argument: "weird; rm -rf /"
        )
        #expect(args.last == "weird; rm -rf /")
        #expect(args.contains("restart"))
        #expect(args.contains { $0.contains("restart weird") } == false)
    }
}

@MainActor
@Suite("Hiding containers")
struct HiddenContainerTests {

    private func makeStore(_ containers: [Container]) -> (ContainerStore, AppSettings) {
        let defaults = UserDefaults(suiteName: "ballast-tests-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.sshDestination = "test@nas"
        settings.lanHost = "nas.local"
        let source = StubSource(containers: containers)
        return (ContainerStore(settings: settings) { _ in source }, settings)
    }

    @Test("a hidden container leaves the menu but stays in the list we fetched")
    func hidingRemovesFromMenu() async {
        let (store, _) = makeStore([makeContainer("keep"), makeContainer("noise")])
        await store.refresh()

        store.hide(store.containers.first { $0.name == "noise" }!)

        #expect(store.visibleContainers.map(\.name) == ["keep"])
        #expect(store.containers.count == 2, "still fetched, just not shown")
        #expect(store.hiddenContainerNames == ["noise"])
    }

    @Test("unhiding brings it back")
    func unhiding() async {
        let (store, _) = makeStore([makeContainer("noise")])
        await store.refresh()

        store.hide(store.containers[0])
        #expect(store.visibleContainers.isEmpty)

        store.unhide("noise")
        #expect(store.visibleContainers.map(\.name) == ["noise"])
        #expect(store.hiddenContainerNames.isEmpty)
    }

    @Test("hiding is keyed by name, so it survives the container being recreated")
    func survivesRecreation() async {
        // `docker compose up` gives a container a new id; hiding by id would
        // silently stop working.
        let (store, settings) = makeStore([makeContainer("noise")])
        await store.refresh()
        store.hide(store.containers[0])

        var recreated = makeContainer("noise")
        recreated.id = "a-completely-different-id"
        #expect(settings.hiddenContainers.contains(recreated.name))
    }

    @Test("a hidden container doesn't count toward the menu bar badge")
    func hiddenDoesNotAlarm() async {
        let (store, _) = makeStore([
            makeContainer("fine"),
            makeContainer("broken", state: .restarting),
        ])
        await store.refresh()
        #expect(store.problemCount == 1)

        store.hide(store.containers.first { $0.name == "broken" }!)
        #expect(store.problemCount == 0)
        #expect(store.overallStatus == .healthy)
    }

    @Test("the hidden list persists")
    func persists() {
        let suite = "ballast-tests-\(UUID().uuidString)"
        let first = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        first.hiddenContainers = ["alpha", "bravo"]

        let second = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        #expect(second.hiddenContainers == ["alpha", "bravo"])
    }
}
