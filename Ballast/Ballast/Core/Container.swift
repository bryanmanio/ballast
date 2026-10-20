import Foundation

/// A container port published to a port on the NAS.
struct PortBinding: Hashable, Sendable {
    var containerPort: Int
    var transport: String   // "tcp" or "udp"
    var hostIP: String?
    var hostPort: Int

    /// Bindings on loopback are reachable only from the NAS itself, so they
    /// are never candidates for a URL we open from the Mac.
    var isLoopbackOnly: Bool {
        hostIP == "127.0.0.1" || hostIP == "::1" || hostIP == "localhost"
    }
}

enum DockerState: String, Sendable, CaseIterable {
    case created, restarting, running, removing, paused, exited, dead
    case unknown

    init(rawValueOrUnknown raw: String) {
        self = DockerState(rawValue: raw) ?? .unknown
    }

    /// Whether Docker believes this container is supposed to be up right now.
    var isUp: Bool {
        switch self {
        case .running, .restarting: true
        case .created, .removing, .paused, .exited, .dead, .unknown: false
        }
    }
}

/// Result of the image's own HEALTHCHECK. `.undefined` means the image
/// declares no healthcheck, which is not the same as being unhealthy.
enum HealthState: String, Sendable {
    case healthy, unhealthy, starting
    case undefined

    init(dockerValue: String?) {
        guard let dockerValue else { self = .undefined; return }
        switch dockerValue {
        case "healthy": self = .healthy
        case "unhealthy": self = .unhealthy
        case "starting": self = .starting
        default: self = .undefined
        }
    }
}

struct Container: Identifiable, Hashable, Sendable {
    var id: String
    /// Docker reports names with a leading slash; this is stripped.
    var name: String
    var state: DockerState
    var health: HealthState
    var exitCode: Int
    var oomKilled: Bool
    var restartCount: Int
    var image: String
    var publishedPorts: [PortBinding]
    /// Container-side ports with no host binding. The only way to guess a URL
    /// for a container on the host network, which is common on Synology.
    var exposedPorts: [Int]
    var networkMode: String
    var labels: [String: String]
    var startedAt: Date?
    var finishedAt: Date?

    // MARK: Label-driven overrides
    //
    // These let a container describe itself to Ballast from its compose file,
    // so the Mac side needs no per-container configuration.

    /// Explicit URL, e.g. `ballast.url=https://plex.example.com`.
    var labelURL: String? { labels["ballast.url"] }
    /// Which published host port is the web UI, e.g. `ballast.port=8080`.
    var labelPort: Int? { labels["ballast.port"].flatMap(Int.init) }
    var labelScheme: String? { labels["ballast.scheme"] }
    /// `ballast.probe=false` opts out of HTTP probing.
    var probeOptOut: Bool { labels["ballast.probe"]?.lowercased() == "false" }
    /// `ballast.hide=true` keeps a container out of the menu entirely.
    var isHidden: Bool { labels["ballast.hide"]?.lowercased() == "true" }

    var displayName: String {
        labels["ballast.name"] ?? name
    }

    /// Tags that name a channel rather than a version, so they're worth
    /// looking past when something better is available.
    private static let channelTags: Set<String> = [
        "latest", "main", "master", "release", "stable", "edge",
        "develop", "development", "nightly", "rolling", "beta",
    ]

    /// The tag part of the image reference, if there is one.
    ///
    /// A registry host can carry a port (`registry:5000/img`) and an image can
    /// be pinned by digest (`img@sha256:…`), so the last colon isn't always a
    /// tag separator.
    var imageTag: String? {
        guard !image.contains("@"), let colon = image.lastIndex(of: ":") else { return nil }
        let tag = image[image.index(after: colon)...]
        // A slash after the colon means the colon belonged to the host.
        guard !tag.contains("/"), !tag.isEmpty else { return nil }
        return String(tag)
    }

    /// Best available version for display: the image tag when it names a
    /// version, otherwise the image's own OCI version label, otherwise
    /// whatever the tag was.
    var version: String? {
        let tag = imageTag
        if let tag, !Self.channelTags.contains(tag.lowercased()) { return tag }

        if let labelled = labels["org.opencontainers.image.version"],
           !labelled.isEmpty, !Self.channelTags.contains(labelled.lowercased()) {
            return labelled
        }
        return tag
    }

    /// Compose stack this container belongs to, used for grouping.
    var composeProject: String? {
        labels["com.docker.compose.project"] ?? labels["ballast.group"]
    }

    var usesHostNetwork: Bool { networkMode == "host" }

    /// Containers can share another container's network namespace — the
    /// standard pattern for routing a service through a VPN sidecar. Docker
    /// then reports no ports for this container, because its ports are
    /// published by the container that owns the network.
    var networkOwnerID: String? {
        let prefix = "container:"
        guard networkMode.hasPrefix(prefix) else { return nil }
        let id = String(networkMode.dropFirst(prefix.count))
        return id.isEmpty ? nil : id
    }

    /// Host ports that could plausibly serve a UI, deduplicated and ordered.
    var candidateHostPorts: [Int] {
        var seen = Set<Int>()
        var result: [Int] = []
        // TCP first: a UDP-only binding is never a web UI.
        for binding in publishedPorts.sorted(by: { ($0.transport == "tcp" ? 0 : 1) < ($1.transport == "tcp" ? 0 : 1) })
        where !binding.isLoopbackOnly {
            if seen.insert(binding.hostPort).inserted { result.append(binding.hostPort) }
        }
        return result
    }
}
