import Foundation

/// Everything that can go wrong between the menu bar and the NAS, kept as
/// distinct cases rather than one opaque failure.
///
/// This matters more than it looks: the common failures here have completely
/// different fixes ("turn the NAS on", "re-run the installer", "start
/// Container Manager"), and a single "connection failed" message would leave
/// the user guessing which one they're looking at.
enum BallastError: Error, Equatable, Sendable {
    /// No SSH destination configured yet.
    case notConfigured
    case hostUnreachable(detail: String)
    case hostKeyUnverified
    case sshAuthFailed(detail: String)
    /// SSH itself failed in a way we couldn't attribute.
    case sshFailed(exitCode: Int32, detail: String)
    case timedOut
    /// The agent script isn't where we expect it on the NAS.
    case agentMissing
    /// The agent predates a subcommand the app now uses.
    case agentOutdated
    /// Passwordless sudo for the agent isn't in place.
    case sudoDenied
    /// The agent ran but couldn't find a docker binary.
    case dockerNotFound
    /// Docker is installed but not answering — Container Manager stopped.
    case dockerUnavailable
    case agentFailed(exitCode: Int32, detail: String)
    case parse(AgentParseError)

    /// Classifies a finished SSH invocation.
    ///
    /// Checked most specific first: the agent's own sentinels, then sudo, then
    /// SSH's own diagnostics. The agent writes `ballast: <reason>` precisely
    /// so this doesn't have to guess from English error text.
    static func classify(exitCode: Int32, stderr: String, timedOut: Bool) -> BallastError {
        if timedOut { return .timedOut }

        let lower = stderr.lowercased()

        // The agent reached the point of running and told us what was wrong.
        if lower.contains("ballast: docker-not-found") { return .dockerNotFound }
        if lower.contains("ballast: usage:") { return .agentOutdated }
        if lower.contains("ballast: docker-unavailable") || lower.contains("ballast: inspect-failed") {
            return .dockerUnavailable
        }

        // sudo refused before the agent ran.
        if lower.contains("password is required") || lower.contains("no tty present")
            || lower.contains("terminal is required") || lower.contains("sudo: a password") {
            return .sudoDenied
        }

        // The agent isn't installed, or isn't where we think it is.
        if lower.contains("command not found") || lower.contains("no such file or directory")
            || exitCode == 127 {
            return .agentMissing
        }

        // SSH-level problems.
        if lower.contains("host key verification failed") { return .hostKeyUnverified }
        if lower.contains("permission denied") || lower.contains("too many authentication failures") {
            return .sshAuthFailed(detail: firstLine(stderr))
        }
        if lower.contains("could not resolve hostname") || lower.contains("name or service not known")
            || lower.contains("no route to host") || lower.contains("connection refused")
            || lower.contains("connection timed out") || lower.contains("operation timed out")
            || lower.contains("network is unreachable") || lower.contains("connection closed") {
            return .hostUnreachable(detail: firstLine(stderr))
        }

        if exitCode == 255 { return .sshFailed(exitCode: exitCode, detail: firstLine(stderr)) }
        return .agentFailed(exitCode: exitCode, detail: firstLine(stderr))
    }

    private static func firstLine(_ text: String) -> String {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
    }

    var title: String {
        switch self {
        case .notConfigured: "Not set up yet"
        case .hostUnreachable: "Can't reach the NAS"
        case .hostKeyUnverified: "Unrecognised SSH host key"
        case .sshAuthFailed: "SSH login refused"
        case .sshFailed: "SSH failed"
        case .timedOut: "The NAS didn't respond in time"
        case .agentMissing: "Agent not installed"
        case .agentOutdated: "Agent needs updating"
        case .sudoDenied: "Agent can't run without a password"
        case .dockerNotFound: "No Docker on the NAS"
        case .dockerUnavailable: "Docker isn't responding"
        case .agentFailed: "The agent returned an error"
        case .parse: "Couldn't read the agent's output"
        }
    }

    /// The actionable half of the message.
    var hint: String {
        switch self {
        case .notConfigured:
            "Add your NAS's SSH destination in Settings."
        case .hostUnreachable(let detail):
            detail.isEmpty ? "Check that the NAS is powered on and reachable." : detail
        case .hostKeyUnverified:
            "Connect once with ssh in Terminal to accept the host key."
        case .sshAuthFailed:
            "Check that your SSH key is authorised for this user on the NAS."
        case .sshFailed(_, let detail):
            detail.isEmpty ? "Try the same ssh command in Terminal to see the error." : detail
        case .timedOut:
            "The NAS may be asleep or under heavy load."
        case .agentMissing:
            "Run nas/deploy.sh again — a DSM update can clear /usr/local/bin."
        case .agentOutdated:
            "Run nas/deploy.sh again to update the agent on the NAS."
        case .sudoDenied:
            "Re-run nas/deploy.sh to reinstall the sudoers rule."
        case .dockerNotFound:
            "Install Container Manager on the NAS."
        case .dockerUnavailable:
            "Start Container Manager on the NAS."
        case .agentFailed(let code, let detail):
            detail.isEmpty ? "The agent exited with code \(code)." : detail
        case .parse(let error):
            "\(error)"
        }
    }
}
