import Foundation

/// What happened when the Mac tried to reach a service's URL.
enum ProbeOutcome: Sendable, Hashable {
    /// Not worth probing: no endpoint, a non-HTTP port, or opted out.
    case skipped(reason: String)
    case responded(statusCode: Int)
    /// Answered TLS but with a certificate we don't trust. The service is
    /// alive, which is all a probe is trying to establish.
    case tlsUntrusted
    case refused
    case timedOut
    case failed(String)

    var isAlive: Bool {
        switch self {
        case .responded, .tlsUntrusted: true
        case .skipped, .refused, .timedOut, .failed: false
        }
    }

    var wasAttempted: Bool {
        if case .skipped = self { return false }
        return true
    }
}

/// The single state shown per row. Ordered by severity so aggregating a list
/// is just `max()`.
enum ServiceStatus: Int, Comparable, Sendable, CaseIterable {
    case healthy = 0
    /// We can't tell — usually because the NAS itself isn't answering.
    case unknown = 1
    /// Up, but not fully: failing healthcheck, restarting, or not responding
    /// on its port.
    case degraded = 2
    case down = 3

    static func < (lhs: ServiceStatus, rhs: ServiceStatus) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct StatusAssessment: Sendable, Hashable {
    var status: ServiceStatus
    /// Short human explanation, shown as the row's tooltip.
    var reason: String
}

enum StatusResolver {

    /// Why a container that isn't running stopped. Shared with the downtime
    /// history so a row and its history entry always say the same thing.
    static func exitReason(exitCode: Int, oomKilled: Bool) -> String {
        if oomKilled { return "Killed — out of memory" }
        if exitCode == 0 { return "Stopped" }
        return "Exited with code \(exitCode)"
    }

    /// Merges the three independent facts — Docker's state, the image's
    /// healthcheck, and our own HTTP probe — into one displayed status.
    ///
    /// Docker state dominates: a stopped container is down regardless of what
    /// any probe says. A probe only ever downgrades a running container,
    /// never promotes a stopped one.
    ///
    /// `dataIsFresh` is false once we've stopped being able to read the NAS.
    /// Reporting a remembered "healthy" in that situation would be the single
    /// most misleading thing this app could do, so everything becomes unknown
    /// instead and the banner explains why.
    static func assess(
        container: Container,
        probe: ProbeOutcome?,
        dataIsFresh: Bool
    ) -> StatusAssessment {
        guard dataIsFresh else {
            return StatusAssessment(status: .unknown, reason: "Status unknown")
        }

        switch container.state {
        case .running:
            return assessRunning(container: container, probe: probe)

        case .restarting:
            return StatusAssessment(
                status: .degraded,
                reason: container.restartCount > 0
                    ? "Restarting (\(container.restartCount) restarts)"
                    : "Restarting"
            )

        case .paused:
            return StatusAssessment(status: .down, reason: "Paused")

        case .created:
            return StatusAssessment(status: .down, reason: "Created but never started")

        case .removing:
            return StatusAssessment(status: .down, reason: "Being removed")

        case .dead:
            return StatusAssessment(status: .down, reason: "Dead")

        case .exited:
            return StatusAssessment(
                status: .down,
                reason: exitReason(exitCode: container.exitCode, oomKilled: container.oomKilled)
            )

        case .unknown:
            return StatusAssessment(status: .unknown, reason: "Unrecognised state")
        }
    }

    private static func assessRunning(container: Container, probe: ProbeOutcome?) -> StatusAssessment {
        // The image's own healthcheck is a stronger signal than our external
        // probe, because it knows what healthy means for this service.
        switch container.health {
        case .unhealthy:
            return StatusAssessment(status: .degraded, reason: "Running, healthcheck failing")
        case .starting:
            return StatusAssessment(status: .degraded, reason: "Starting up")
        case .healthy, .undefined:
            break
        }

        guard let probe, probe.wasAttempted else {
            return StatusAssessment(status: .healthy, reason: runningReason(container))
        }

        switch probe {
        case .responded(let code):
            return StatusAssessment(status: .healthy, reason: "Running, responding (HTTP \(code))")
        case .tlsUntrusted:
            return StatusAssessment(status: .healthy, reason: "Running, responding (untrusted certificate)")
        case .refused:
            return StatusAssessment(status: .degraded, reason: "Running, but connection refused")
        case .timedOut:
            return StatusAssessment(status: .degraded, reason: "Running, but not answering")
        case .failed(let message):
            return StatusAssessment(status: .degraded, reason: "Running, but unreachable: \(message)")
        case .skipped:
            return StatusAssessment(status: .healthy, reason: runningReason(container))
        }
    }

    private static func runningReason(_ container: Container) -> String {
        container.health == .healthy ? "Running, healthy" : "Running"
    }

    /// Worst status across a set, for the menu bar icon.
    static func aggregate(_ assessments: [StatusAssessment]) -> ServiceStatus {
        assessments.map(\.status).max() ?? .unknown
    }
}
