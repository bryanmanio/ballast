import Foundation

/// A URL the menu can open for a container, plus whether it makes sense to
/// HTTP-probe it.
struct ServiceEndpoint: Hashable, Sendable, Identifiable {
    var url: URL
    var hostPort: Int?
    var isProbeable: Bool

    var id: String { url.absoluteString }
}

/// Turns a container into the URLs we can offer for it.
///
/// Priority order, highest first:
///  1. `ballast.url` label — an absolute URL, which also covers anyone
///     fronting services with a reverse proxy.
///  2. `ballast.port` label — names which host port is the web UI.
///  3. Published, non-loopback host ports, ranked by how likely each is to
///     be a web UI.
///  4. Exposed container ports, for containers on the host network, where
///     Docker reports no published ports but the service is still listening
///     on that port on the NAS itself.
///  5. For a container sharing another container's network namespace, the
///     owner's published binding for the port this container exposes.
enum ServiceURLResolver {

    /// Ports that are well known to speak something other than HTTP. Used to
    /// keep a database or a BitTorrent peer port from being probed and
    /// reported as a broken web service.
    static let nonHTTPPorts: Set<Int> = [
        // Mail, shell, file sharing, directory services
        22, 25, 110, 143, 137, 138, 139, 389, 445, 465, 548, 587, 636,
        873, 993, 995, 2049,
        // DNS and friends, including the encrypted variants an image like
        // AdGuard Home declares alongside its web UI
        53, 853, 5353, 5355, 5443,
        // DHCP, TFTP, NTP, RPC
        67, 68, 69, 111, 123,
        // VPN and NAT traversal
        500, 1194, 1723, 3478, 4500, 51820,
        // SIP, SSDP
        1900, 5060,
        // Databases and caches
        3306, 5432, 5433, 6379, 11211, 27017,
        // Media and torrent service ports
        7359, 32469, 51413,
    ]

    /// Soft hints for picking a primary port when a container publishes
    /// several. Earlier is preferred.
    static let preferredWebPorts: [Int] = [
        80, 443, 8080, 8443, 3000, 5000, 8000, 8081, 8096, 8123, 9000, 32400,
    ]

    private static let httpsPorts: Set<Int> = [443, 8443, 9443]

    static func endpoints(
        for container: Container,
        host: String,
        networkOwner: Container? = nil,
        /// Host ports of the network owner already claimed by a sibling that
        /// matched exactly, so they aren't guessed at twice.
        claimedOwnerPorts: Set<Int> = []
    ) -> [ServiceEndpoint] {
        // 1. An explicit URL wins outright, and ignores `host` by design:
        //    it may well point at a reverse proxy rather than the NAS.
        if let raw = container.labelURL,
           let url = URL(string: raw),
           url.scheme != nil, url.host != nil {
            return [ServiceEndpoint(
                url: url,
                hostPort: url.port,
                isProbeable: !container.probeOptOut
            )]
        }

        guard !host.isEmpty else { return [] }

        // 2. An explicitly nominated port.
        if let port = container.labelPort {
            return [endpoint(container: container, host: host, port: port)]
        }

        // 3. Published host ports.
        let published = container.candidateHostPorts
        if !published.isEmpty {
            return rank(published).map { endpoint(container: container, host: host, port: $0) }
        }

        // 4. Host-network containers have no published ports, but the
        //    container-side port is the NAS-side port.
        if container.usesHostNetwork, !container.exposedPorts.isEmpty {
            return linkableExposedPorts(container.exposedPorts)
                .map { endpoint(container: container, host: host, port: $0) }
        }

        // 5. Sharing another container's network: this container's exposed
        //    ports are published by the owner. Matching the two gives the
        //    real host port, rather than guessing from the owner's whole
        //    published set — which would often be a different service.
        if let networkOwner {
            let matched = matchedOwnerPorts(for: container, owner: networkOwner)
            if !matched.isEmpty {
                return rank(matched).map { endpoint(container: container, host: host, port: $0) }
            }

            // No exact match. That happens whenever a service was told to
            // listen on a different port than its image declares — qBittorrent
            // with WEBUI_PORT set, for instance — and Docker records nothing
            // that ties a namespace port to the container using it.
            //
            // So fall back to the owner's published ports that no sibling has
            // claimed. It is a guess, and `ballast.port` overrides it.
            let unclaimed = networkOwner.publishedPorts
                .filter { !$0.isLoopbackOnly && !claimedOwnerPorts.contains($0.hostPort) }
                .map(\.hostPort)
            if !unclaimed.isEmpty {
                return rank(Array(Set(unclaimed)))
                    .map { endpoint(container: container, host: host, port: $0) }
            }
        }

        return []
    }

    /// Host ports of `owner` that this container's exposed ports match exactly.
    static func matchedOwnerPorts(for container: Container, owner: Container) -> [Int] {
        Array(Set(container.exposedPorts.flatMap { exposed in
            owner.publishedPorts
                .filter { $0.containerPort == exposed && !$0.isLoopbackOnly }
                .map(\.hostPort)
        }))
    }

    /// Exposed ports come from the image rather than from anything the user
    /// chose, so an image like AdGuard Home declares DNS, DHCP, DNS-over-TLS
    /// and a debug endpoint alongside its web UI. Offering those as links
    /// is noise at best — a browser pointed at port 53 does nothing useful.
    private static func linkableExposedPorts(_ ports: [Int]) -> [Int] {
        let linkable = ports.filter { !nonHTTPPorts.contains($0) }
        return rank(Array(Set(linkable)))
    }

    static func primaryEndpoint(
        for container: Container,
        host: String,
        networkOwner: Container? = nil
    ) -> ServiceEndpoint? {
        endpoints(for: container, host: host, networkOwner: networkOwner).first
    }

    /// Likely web ports first, then everything else, each group ordered by
    /// the preference table and then numerically.
    static func rank(_ ports: [Int]) -> [Int] {
        func sortKey(_ port: Int) -> (Int, Int, Int) {
            let likelyWeb = nonHTTPPorts.contains(port) ? 1 : 0
            let preference = preferredWebPorts.firstIndex(of: port) ?? preferredWebPorts.count
            return (likelyWeb, preference, port)
        }
        return ports.sorted { sortKey($0) < sortKey($1) }
    }

    private static func endpoint(container: Container, host: String, port: Int) -> ServiceEndpoint {
        var components = URLComponents()
        components.scheme = container.labelScheme ?? (httpsPorts.contains(port) ? "https" : "http")
        components.host = host
        components.port = port
        if let path = container.labels["ballast.path"] {
            components.path = path.hasPrefix("/") ? path : "/" + path
        }
        let url = components.url ?? URL(string: "http://\(host):\(port)")!
        return ServiceEndpoint(
            url: url,
            hostPort: port,
            isProbeable: !container.probeOptOut && !nonHTTPPorts.contains(port)
        )
    }
}
