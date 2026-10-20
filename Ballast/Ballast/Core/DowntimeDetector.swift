import Foundation

/// The part of a container's state that matters for spotting a transition,
/// kept from one successful poll to the next.
struct ContainerSnapshot: Sendable, Hashable {
    var state: DockerState
    var exitCode: Int
    var oomKilled: Bool
    var restartCount: Int
    var startedAt: Date?
    var finishedAt: Date?
}

/// Turns two consecutive views of the NAS into the events between them.
///
/// Pure and dependency-free so it is deterministic under test. Deciding what
/// to do about an event — record it, notify, suppress it — is the store's job.
enum DowntimeDetector {

    /// Keyed by name: the id changes whenever a container is recreated.
    static func snapshot(_ containers: [Container]) -> [String: ContainerSnapshot] {
        Dictionary(
            containers.map { container in
                (container.name, ContainerSnapshot(
                    state: container.state,
                    exitCode: container.exitCode,
                    oomKilled: container.oomKilled,
                    restartCount: container.restartCount,
                    startedAt: container.startedAt,
                    finishedAt: container.finishedAt
                ))
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// - Parameter suppressed: names the user has just acted on. Their exits
    ///   are still recorded, but flagged so they are never notified.
    static func events(
        previous: [String: ContainerSnapshot],
        current: [Container],
        suppressed: Set<String>,
        now: Date
    ) -> [DowntimeEvent] {
        // Nothing to compare against on the first poll, and reporting every
        // already-stopped container as a fresh exit would be wrong.
        guard !previous.isEmpty else { return [] }

        var events: [DowntimeEvent] = []
        for container in current {
            guard let before = previous[container.name] else { continue }

            let wasUp = before.state.isUp
            let isUp = container.state.isUp

            if wasUp, !isUp {
                // Paused, being removed and the like aren't exits.
                guard container.state == .exited || container.state == .dead else { continue }
                events.append(event(
                    for: container, kind: .exited,
                    at: container.finishedAt ?? now,
                    userInitiated: suppressed.contains(container.name)
                ))
            } else if wasUp, isUp, container.restartCount > before.restartCount {
                // A restart policy brought it back between two polls. A
                // `restarting` container counts as up, so flapping in place
                // reports through here rather than as exit and start.
                events.append(event(
                    for: container, kind: .crashRestarted,
                    at: container.finishedAt ?? now
                ))
            } else if !wasUp, isUp, before.state == .exited || before.state == .dead {
                events.append(event(
                    for: container, kind: .started,
                    at: container.startedAt ?? now
                ))
            }
        }
        return events
    }

    private static func event(
        for container: Container,
        kind: DowntimeEvent.Kind,
        at: Date,
        userInitiated: Bool = false
    ) -> DowntimeEvent {
        DowntimeEvent(
            containerName: container.name,
            kind: kind,
            at: at,
            exitCode: container.exitCode,
            oomKilled: container.oomKilled,
            image: container.image,
            userInitiated: userInitiated
        )
    }
}
