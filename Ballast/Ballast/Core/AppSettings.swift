import Foundation
import Observation

/// User configuration, persisted in UserDefaults.
///
/// Note what isn't here: no password, token, or key material. The SSH
/// transport leans on the user's existing key and agent, so Ballast has no
/// secrets to store or leak.
@MainActor
@Observable
final class AppSettings {
    /// ssh destination — `user@host` or an alias from `~/.ssh/config`.
    var sshDestination: String { didSet { write(sshDestination, .sshDestination) } }
    /// Hostname used to build service URLs on the local network.
    var lanHost: String { didSet { write(lanHost, .lanHost) } }
    /// Hostname used when the LAN one doesn't answer — typically a Tailscale name.
    var remoteHost: String { didSet { write(remoteHost, .remoteHost) } }
    var agentPath: String { didSet { write(agentPath, .agentPath) } }
    /// Port used only to test which hostname is reachable.
    var reachabilityPort: Int { didSet { write(reachabilityPort, .reachabilityPort) } }
    var refreshInterval: TimeInterval { didSet { write(refreshInterval, .refreshInterval) } }
    var probeEnabled: Bool { didSet { write(probeEnabled, .probeEnabled) } }
    /// Compose stack names are noise when you already know what runs where,
    /// so the list is flat unless asked otherwise.
    var hideProjectNames: Bool { didSet { write(hideProjectNames, .hideProjectNames) } }
    var sortOrder: ContainerSortOrder { didSet { write(sortOrder.rawValue, .sortOrder) } }
    /// Containers hidden from the menu, keyed by name rather than id — an id
    /// changes every time a container is recreated, which `docker compose up`
    /// does routinely.
    var hiddenContainers: Set<String> {
        didSet { write(hiddenContainers.sorted(), .hiddenContainers) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sshDestination = defaults.string(forKey: Key.sshDestination.rawValue) ?? ""
        lanHost = defaults.string(forKey: Key.lanHost.rawValue) ?? ""
        remoteHost = defaults.string(forKey: Key.remoteHost.rawValue) ?? ""
        agentPath = defaults.string(forKey: Key.agentPath.rawValue) ?? SSHContainerSource.defaultAgentPath
        reachabilityPort = defaults.object(forKey: Key.reachabilityPort.rawValue) as? Int ?? 22
        refreshInterval = defaults.object(forKey: Key.refreshInterval.rawValue) as? TimeInterval ?? 30
        // Off by default: Docker's own view of a container is trustworthy,
        // whereas an HTTP probe reports a service as degraded for reasons
        // that have nothing to do with the service (our own network path,
        // timeouts, non-HTTP endpoints). A status you can't trust is worse
        // than no status.
        probeEnabled = defaults.object(forKey: Key.probeEnabled.rawValue) as? Bool ?? false
        hideProjectNames = defaults.object(forKey: Key.hideProjectNames.rawValue) as? Bool ?? true
        sortOrder = ContainerSortOrder(rawValue: defaults.string(forKey: Key.sortOrder.rawValue) ?? "")
            ?? .status
        hiddenContainers = Set(defaults.stringArray(forKey: Key.hiddenContainers.rawValue) ?? [])
    }

    var isConfigured: Bool {
        !sshDestination.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// If the user only gave an ssh destination, derive the LAN hostname from
    /// it rather than making them type the same host twice.
    var effectiveLANHost: String {
        if !lanHost.trimmingCharacters(in: .whitespaces).isEmpty { return lanHost }
        let destination = sshDestination.trimmingCharacters(in: .whitespaces)
        guard let host = destination.split(separator: "@").last, !host.isEmpty else { return "" }
        return String(host)
    }

    private enum Key: String {
        case sshDestination, lanHost, remoteHost, agentPath, reachabilityPort
        case refreshInterval, probeEnabled
        case hideProjectNames, sortOrder, hiddenContainers
    }

    private func write(_ value: Any, _ key: Key) {
        defaults.set(value, forKey: key.rawValue)
    }
}
