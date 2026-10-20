import Foundation
import Testing
@testable import BallastCore

/// Records what it was asked to post.
private final class StubNotifier: ExitNotifying, @unchecked Sendable {
    private(set) var posted: [DowntimeEvent] = []
    func authorizationStatus() async -> NotificationAuthorization { .authorized }
    func requestAuthorization() async -> Bool { true }
    func post(_ events: [DowntimeEvent]) async { posted += events }
}

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func hours(_ value: Double) -> Date { now.addingTimeInterval(-value * 3_600) }

private func detect(
    from before: [Container],
    to after: [Container],
    suppressed: Set<String> = []
) -> [DowntimeEvent] {
    DowntimeDetector.events(
        previous: DowntimeDetector.snapshot(before),
        current: after,
        suppressed: suppressed,
        now: now
    )
}

@Suite("Downtime detection")
struct DowntimeDetectorTests {

    @Test("the first poll has nothing to compare against")
    func coldStart() {
        let events = DowntimeDetector.events(
            previous: [:],
            current: [makeContainer("plex", state: .exited, exitCode: 137)],
            suppressed: [],
            now: now
        )
        #expect(events.isEmpty)
    }

    @Test("a clean exit is recorded but never notifiable")
    func cleanExit() throws {
        let events = detect(
            from: [makeContainer("job")],
            to: [makeContainer("job", state: .exited, exitCode: 0, finishedAt: hours(1))]
        )
        let event = try #require(events.first)
        #expect(event.kind == .exited)
        #expect(event.isNotifiable == false)
        #expect(event.summary == "Stopped")
    }

    @Test("a non-zero exit is notifiable and timestamped from Docker, not from the poll")
    func failedExit() throws {
        let events = detect(
            from: [makeContainer("plex")],
            to: [makeContainer("plex", state: .exited, exitCode: 137, finishedAt: hours(6))]
        )
        let event = try #require(events.first)
        #expect(event.isNotifiable)
        #expect(event.at == hours(6))
        #expect(event.summary == "Exited with code 137")
    }

    @Test("an OOM kill is notifiable")
    func oomKill() throws {
        let events = detect(
            from: [makeContainer("transmission")],
            to: [makeContainer("transmission", state: .exited, exitCode: 137, oomKilled: true)]
        )
        let event = try #require(events.first)
        #expect(event.isNotifiable)
        #expect(event.summary == "Killed — out of memory")
    }

    @Test("an exit with no finish time falls back to when it was noticed")
    func missingFinishTime() throws {
        let events = detect(
            from: [makeContainer("plex")],
            to: [makeContainer("plex", state: .exited, exitCode: 1)]
        )
        #expect(try #require(events.first).at == now)
    }

    @Test("a stop the user asked for is recorded but not notifiable")
    func userInitiatedStop() throws {
        // `docker stop` exits 137 when the container is slow to quit.
        let events = detect(
            from: [makeContainer("plex")],
            to: [makeContainer("plex", state: .exited, exitCode: 137, finishedAt: hours(0))],
            suppressed: ["plex"]
        )
        let event = try #require(events.first)
        #expect(event.userInitiated)
        #expect(event.isNotifiable == false)
        #expect(event.summary == "Stopped")
    }

    @Test("a restart-count jump is a crash-restart, never notifiable")
    func crashRestart() throws {
        let events = detect(
            from: [makeContainer("api", restartCount: 2)],
            to: [makeContainer("api", restartCount: 5, finishedAt: hours(0.1))]
        )
        #expect(events.map(\.kind) == [.crashRestarted])
        #expect(events[0].isNotifiable == false)
    }

    @Test("a container that restarts in place doesn't also report an exit")
    func restartingStateIsStillUp() {
        let events = detect(
            from: [makeContainer("api", state: .running)],
            to: [makeContainer("api", state: .restarting)]
        )
        #expect(events.isEmpty)
    }

    @Test("an exited container coming back is a start")
    func start() throws {
        let events = detect(
            from: [makeContainer("plex", state: .exited, exitCode: 1)],
            to: [makeContainer("plex", startedAt: hours(0.5))]
        )
        let event = try #require(events.first)
        #expect(event.kind == .started)
        #expect(event.at == hours(0.5))
    }

    @Test("pausing and unpausing aren't exits or starts")
    func pause() {
        #expect(detect(from: [makeContainer("a")], to: [makeContainer("a", state: .paused)]).isEmpty)
        #expect(detect(from: [makeContainer("a", state: .paused)], to: [makeContainer("a")]).isEmpty)
    }

    @Test("a recreated container is still matched by name")
    func recreatedWithNewID() {
        // `docker compose up` gives the container a new id.
        let events = detect(
            from: [makeContainer("plex", id: "old")],
            to: [makeContainer("plex", id: "new", state: .exited, exitCode: 1)]
        )
        #expect(events.map(\.containerName) == ["plex"])
    }

    @Test("a container that was already stopped isn't reported again")
    func stillStopped() {
        let stopped = makeContainer("job", state: .exited, exitCode: 1)
        #expect(detect(from: [stopped], to: [stopped]).isEmpty)
    }

    @Test("a new container is not an event")
    func appearing() {
        #expect(detect(from: [makeContainer("a")], to: [makeContainer("a"), makeContainer("b")]).isEmpty)
    }
}

@Suite("Downtime event wording and pairing")
struct DowntimeEventTests {

    @Test("a fresh exit is worded plainly")
    func freshBody() {
        let event = DowntimeEvent(containerName: "plex", kind: .exited, at: now.addingTimeInterval(-30), exitCode: 137)
        #expect(event.notificationBody(now: now) == "Exited with code 137")
    }

    @Test("a stale exit says when it happened rather than implying it just did")
    func staleBody() {
        let event = DowntimeEvent(containerName: "plex", kind: .exited, at: hours(6), exitCode: 137)
        let body = event.notificationBody(now: now)
        #expect(body.hasPrefix("Exited with code 137, "))
        #expect(body.contains("ago"))
        #expect(body.contains("6"))
    }

    @Test("an exit is paired with the next start of the same container")
    func pairing() {
        let exit = DowntimeEvent(containerName: "a", kind: .exited, at: hours(3), exitCode: 1)
        let start = DowntimeEvent(containerName: "a", kind: .started, at: hours(3) + 240)
        let otherExit = DowntimeEvent(containerName: "b", kind: .exited, at: hours(2), exitCode: 1)

        let downtimes = DowntimeEvent.downtimes(in: [start, otherExit, exit])
        #expect(downtimes[exit.id] == 240)
        #expect(downtimes[otherExit.id] == nil, "no start observed, so no duration")
    }

    @Test("an exit followed by another exit has no duration")
    func unpairedExit() {
        let first = DowntimeEvent(containerName: "a", kind: .exited, at: hours(3), exitCode: 1)
        let second = DowntimeEvent(containerName: "a", kind: .exited, at: hours(2), exitCode: 1)
        #expect(DowntimeEvent.downtimes(in: [first, second]).isEmpty)
    }
}

@Suite("Downtime history storage")
struct DowntimeHistoryStoreTests {

    private func event(_ name: String = "a", at: Date) -> DowntimeEvent {
        DowntimeEvent(containerName: name, kind: .exited, at: at, exitCode: 1)
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "ballast-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "history.json")
    }

    @Test("retention keeps the newest 200")
    func countLimit() {
        let events = (0..<250).map { event(at: now.addingTimeInterval(-Double(250 - $0) * 60)) }
        let kept = DowntimeRetention.trim(events, now: now)
        #expect(kept.count == 200)
        #expect(kept.last?.at == events.last?.at)
        #expect(kept.first?.at == events[50].at)
    }

    @Test("a crash loop collapses into one counted entry instead of filling the log")
    func crashLoopCoalesces() {
        // One per poll for an hour, which is what a restart policy produces.
        let loop = (0..<120).map {
            DowntimeEvent(containerName: "sonarr", kind: .crashRestarted,
                          at: now.addingTimeInterval(-Double(120 - $0) * 30), exitCode: 1)
        }
        let other = event("plex", at: hours(2))

        let kept = DowntimeRetention.trim(loop + [other], now: now)

        #expect(kept.count == 2)
        #expect(kept.map(\.containerName).contains("plex"))
        let episode = try? #require(kept.first { $0.containerName == "sonarr" })
        #expect(episode?.occurrenceCount == 120)
        // Carries the latest restart's time, so the row reads as still going.
        #expect(episode?.at == loop.last?.at)
        #expect(episode?.summary.contains("120×") == true)
    }

    @Test("crashes an hour or more apart stay separate entries")
    func distantCrashesStaySeparate() {
        let first = DowntimeEvent(containerName: "sonarr", kind: .crashRestarted, at: hours(5), exitCode: 1)
        let later = DowntimeEvent(containerName: "sonarr", kind: .crashRestarted, at: hours(1), exitCode: 1)

        let kept = DowntimeRetention.trim([first, later], now: now)

        #expect(kept.count == 2)
        #expect(kept.allSatisfy { $0.occurrenceCount == 1 })
    }

    @Test("an exit between two crash-restarts breaks the run")
    func exitBreaksTheRun() {
        let before = DowntimeEvent(containerName: "sonarr", kind: .crashRestarted, at: hours(3), exitCode: 1)
        let exited = DowntimeEvent(containerName: "sonarr", kind: .exited, at: hours(2.5), exitCode: 1)
        let after = DowntimeEvent(containerName: "sonarr", kind: .crashRestarted, at: hours(2), exitCode: 1)

        let kept = DowntimeRetention.trim([before, exited, after], now: now)

        #expect(kept.map(\.kind) == [.crashRestarted, .exited, .crashRestarted])
    }

    @Test("coalescing is stable across reloads")
    func coalescingIsIdempotent() {
        let loop = (0..<10).map {
            DowntimeEvent(containerName: "sonarr", kind: .crashRestarted,
                          at: now.addingTimeInterval(-Double(10 - $0) * 60), exitCode: 1)
        }
        let once = DowntimeRetention.trim(loop, now: now)
        #expect(DowntimeRetention.trim(once, now: now) == once)
        #expect(once.first?.occurrenceCount == 10)
    }

    @Test("retention drops anything older than 30 days")
    func ageLimit() {
        let old = event("old", at: now.addingTimeInterval(-31 * 86_400))
        let recent = event("recent", at: now.addingTimeInterval(-29 * 86_400))
        #expect(DowntimeRetention.trim([old, recent], now: now).map(\.containerName) == ["recent"])
    }

    @Test("history survives a restart of the app")
    func roundTrip() {
        let url = temporaryURL()
        let original = event(at: hours(2))
        FileDowntimeHistoryStore(url: url, now: { now }).append([original])

        let reloaded = FileDowntimeHistoryStore(url: url, now: { now }).load()
        #expect(reloaded == [original])
    }

    @Test("retention applies on every append")
    func appendTrims() {
        let store = FileDowntimeHistoryStore(url: temporaryURL(), now: { now })
        store.append([event("old", at: now.addingTimeInterval(-40 * 86_400))])
        store.append([event("new", at: hours(1))])
        #expect(store.load().map(\.containerName) == ["new"])
    }

    @Test("a corrupt file loads as empty instead of crashing")
    func corruptFile() throws {
        let url = temporaryURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json {".utf8).write(to: url)

        let store = FileDowntimeHistoryStore(url: url, now: { now })
        #expect(store.load().isEmpty)

        store.append([event(at: hours(1))])
        #expect(store.load().count == 1, "and the log recovers on the next write")
    }

    @Test("a missing file loads as empty")
    func missingFile() {
        #expect(FileDowntimeHistoryStore(url: temporaryURL()).load().isEmpty)
    }

    @Test("clearing removes the log")
    func clear() {
        let store = FileDowntimeHistoryStore(url: temporaryURL(), now: { now })
        store.append([event(at: hours(1))])
        store.clear()
        #expect(store.load().isEmpty)
    }
}

@MainActor
@Suite("Downtime wiring in the store")
struct DowntimeStoreTests {

    private func makeStore(
        _ containers: [Container],
        notify: Bool = true
    ) -> (ContainerStore, StubSource, AppSettings, InMemoryDowntimeHistoryStore, StubNotifier) {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "ballast-tests-\(UUID().uuidString)")!)
        settings.sshDestination = "test@nas"
        settings.lanHost = "nas.local"
        settings.notifyOnUnexpectedExit = notify
        let source = StubSource(containers: containers)
        let history = InMemoryDowntimeHistoryStore()
        let notifier = StubNotifier()
        let store = ContainerStore(settings: settings, historyStore: history, notifier: notifier) { _ in source }
        return (store, source, settings, history, notifier)
    }

    private func set(_ source: StubSource, _ containers: [Container]) {
        source.result = .success(AgentListOutput(protocolVersion: 1, containers: containers))
    }

    @Test("the first poll records and notifies nothing, even for stopped containers")
    func firstPoll() async {
        let (store, _, _, history, notifier) = makeStore([makeContainer("job", state: .exited, exitCode: 1)])
        await store.refresh()
        #expect(history.load().isEmpty)
        #expect(notifier.posted.isEmpty)
    }

    @Test("a crash is recorded and notified")
    func crash() async {
        let (store, source, _, history, notifier) = makeStore([makeContainer("plex")])
        await store.refresh()

        set(source, [makeContainer("plex", state: .exited, exitCode: 137, finishedAt: Date())])
        await store.refresh()

        #expect(history.load().map(\.kind) == [.exited])
        #expect(notifier.posted.map(\.containerName) == ["plex"])
        #expect(store.history.count == 1)
        #expect(store.lastExit(for: "plex")?.exitCode == 137)
    }

    @Test("a clean exit is recorded but doesn't notify")
    func cleanExit() async {
        let (store, source, _, history, notifier) = makeStore([makeContainer("job")])
        await store.refresh()

        set(source, [makeContainer("job", state: .exited, exitCode: 0)])
        await store.refresh()

        #expect(history.load().count == 1)
        #expect(notifier.posted.isEmpty)
    }

    @Test("a crash-restart is recorded but doesn't notify")
    func crashRestart() async {
        let (store, source, _, history, notifier) = makeStore([makeContainer("api")])
        await store.refresh()

        set(source, [makeContainer("api", restartCount: 3)])
        await store.refresh()

        #expect(history.load().map(\.kind) == [.crashRestarted])
        #expect(notifier.posted.isEmpty)
    }

    @Test("stopping a container from Ballast doesn't notify")
    func userStop() async {
        let (store, source, _, history, notifier) = makeStore([makeContainer("plex")])
        await store.refresh()
        let plex = store.containers[0]

        // The stop lands as a SIGKILL exit, as `docker stop` does when slow.
        set(source, [makeContainer("plex", state: .exited, exitCode: 137, finishedAt: Date())])
        await store.perform(.stop, on: plex)

        #expect(history.load().count == 1, "still part of the history")
        #expect(history.load()[0].userInitiated)
        #expect(notifier.posted.isEmpty)
    }

    @Test("an exit nobody asked for still notifies after the user acted on another container")
    func suppressionIsPerContainer() async {
        let (store, source, _, _, notifier) = makeStore([makeContainer("a"), makeContainer("b")])
        await store.refresh()
        let a = store.containers.first { $0.name == "a" }!

        set(source, [makeContainer("a"), makeContainer("b", state: .exited, exitCode: 1)])
        await store.perform(.restart, on: a)

        #expect(notifier.posted.map(\.containerName) == ["b"])
    }

    @Test("failed polls never look like exits")
    func failedPollsEmitNothing() async {
        let (store, source, _, history, notifier) = makeStore([makeContainer("plex")])
        await store.refresh()

        source.result = .failure(.timedOut)
        await store.refresh()
        await store.refresh()
        await store.refresh()
        #expect(history.load().isEmpty)
        #expect(notifier.posted.isEmpty)

        // The snapshot survived the outage, so the same state afterwards is
        // still not a transition.
        set(source, [makeContainer("plex")])
        await store.refresh()
        #expect(history.load().isEmpty)
    }

    @Test("an exit during an outage is reported once the NAS is back, worded from finishedAt")
    func exitDuringOutage() async {
        let (store, source, _, history, notifier) = makeStore([makeContainer("plex")])
        await store.refresh()

        source.result = .failure(.timedOut)
        await store.refresh()
        await store.refresh()
        #expect(store.dataIsFresh == false)

        let finished = Date().addingTimeInterval(-6 * 3_600)
        set(source, [makeContainer("plex", state: .exited, exitCode: 137, finishedAt: finished)])
        await store.refresh()

        let event = history.load().first
        #expect(event?.at == finished)
        #expect(notifier.posted.count == 1)
        #expect(notifier.posted[0].notificationBody().contains("ago"))
    }

    @Test("notifications stay quiet while the setting is off")
    func settingOff() async {
        let (store, source, _, history, notifier) = makeStore([makeContainer("plex")], notify: false)
        await store.refresh()

        set(source, [makeContainer("plex", state: .exited, exitCode: 1)])
        await store.refresh()

        #expect(history.load().count == 1)
        #expect(notifier.posted.isEmpty)
    }

    @Test("a muted container doesn't notify")
    func muted() async {
        let (store, source, _, history, notifier) = makeStore([makeContainer("plex")])
        await store.refresh()
        store.mute(store.containers[0])
        #expect(store.mutedContainerNames == ["plex"])

        set(source, [makeContainer("plex", state: .exited, exitCode: 1)])
        await store.refresh()

        #expect(history.load().count == 1)
        #expect(notifier.posted.isEmpty)
    }

    @Test("ballast.notify=false opts a container out")
    func labelOptOut() async {
        let (store, source, _, history, notifier) = makeStore([makeContainer("plex")])
        await store.refresh()

        set(source, [makeContainer("plex", state: .exited, exitCode: 1, labels: ["ballast.notify": "false"])])
        await store.refresh()

        #expect(history.load().count == 1)
        #expect(notifier.posted.isEmpty)
    }

    @Test("clearing history empties the log and the view of it")
    func clearing() async {
        let (store, source, _, history, _) = makeStore([makeContainer("plex")])
        await store.refresh()
        set(source, [makeContainer("plex", state: .exited, exitCode: 1)])
        await store.refresh()
        #expect(store.history.count == 1)

        store.clearHistory()
        #expect(store.history.isEmpty)
        #expect(history.load().isEmpty)
    }

    @Test("muting and notification settings persist")
    func settingsPersist() {
        let suite = "ballast-tests-\(UUID().uuidString)"
        let first = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        #expect(first.notifyOnUnexpectedExit == false, "opt-in")
        first.notifyOnUnexpectedExit = true
        first.mutedContainers = ["plex"]

        let second = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        #expect(second.notifyOnUnexpectedExit)
        #expect(second.mutedContainers == ["plex"])
    }
}
