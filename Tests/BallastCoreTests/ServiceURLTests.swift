import Foundation
import Testing
@testable import BallastCore

private func container(
    name: String = "svc",
    state: DockerState = .running,
    health: HealthState = .undefined,
    exitCode: Int = 0,
    oomKilled: Bool = false,
    restartCount: Int = 0,
    published: [PortBinding] = [],
    exposed: [Int] = [],
    networkMode: String = "bridge",
    labels: [String: String] = [:]
) -> Container {
    Container(
        id: name, name: name, state: state, health: health, exitCode: exitCode,
        oomKilled: oomKilled, restartCount: restartCount, image: "img",
        publishedPorts: published, exposedPorts: exposed, networkMode: networkMode,
        labels: labels, startedAt: nil, finishedAt: nil
    )
}

private func binding(_ hostPort: Int, _ containerPort: Int? = nil, ip: String = "0.0.0.0", transport: String = "tcp") -> PortBinding {
    PortBinding(containerPort: containerPort ?? hostPort, transport: transport, hostIP: ip, hostPort: hostPort)
}

@Suite("Service URL resolution")
struct ServiceURLTests {
    let host = "nas.local"

    @Test("an explicit ballast.url label wins and is used verbatim")
    func explicitURLWins() throws {
        let c = container(published: [binding(8096)], labels: ["ballast.url": "https://jellyfin.example.com/web"])
        let endpoints = ServiceURLResolver.endpoints(for: c, host: host)
        #expect(endpoints.count == 1)
        #expect(endpoints[0].url.absoluteString == "https://jellyfin.example.com/web")
    }

    @Test("a malformed ballast.url falls through to published ports")
    func malformedURLFallsThrough() throws {
        let c = container(published: [binding(8096)], labels: ["ballast.url": "not a url"])
        let primary = try #require(ServiceURLResolver.primaryEndpoint(for: c, host: host))
        #expect(primary.url.absoluteString == "http://nas.local:8096")
    }

    @Test("ballast.port names the web port")
    func explicitPort() throws {
        let c = container(published: [binding(9091), binding(51413)], labels: ["ballast.port": "9091"])
        let endpoints = ServiceURLResolver.endpoints(for: c, host: host)
        #expect(endpoints.count == 1)
        #expect(endpoints[0].url.absoluteString == "http://nas.local:9091")
    }

    @Test("a single published port is used directly")
    func singlePublishedPort() throws {
        let primary = try #require(
            ServiceURLResolver.primaryEndpoint(for: container(published: [binding(2283)]), host: host)
        )
        #expect(primary.url.absoluteString == "http://nas.local:2283")
        #expect(primary.hostPort == 2283)
        #expect(primary.isProbeable)
    }

    @Test("loopback-only bindings never produce a URL")
    func loopbackExcluded() {
        let c = container(published: [binding(5432, ip: "127.0.0.1")])
        #expect(ServiceURLResolver.endpoints(for: c, host: host).isEmpty)
    }

    @Test("a container with no ports at all has no endpoints")
    func noPorts() {
        #expect(ServiceURLResolver.endpoints(for: container(), host: host).isEmpty)
    }

    @Test("host-network containers fall back to exposed ports")
    func hostNetworkUsesExposedPorts() throws {
        let c = container(exposed: [32400], networkMode: "host")
        let primary = try #require(ServiceURLResolver.primaryEndpoint(for: c, host: host))
        #expect(primary.url.absoluteString == "http://nas.local:32400")
    }

    @Test("bridge containers do not guess from exposed ports")
    func bridgeIgnoresExposedPorts() {
        // Exposed-but-unpublished on a bridge network is not reachable from
        // the Mac, so guessing a URL would produce a permanently broken link.
        let c = container(exposed: [8080], networkMode: "bridge")
        #expect(ServiceURLResolver.endpoints(for: c, host: host).isEmpty)
    }

    @Test("web ports outrank service ports when several are published")
    func ranksWebPortsFirst() throws {
        let c = container(published: [binding(51413), binding(9091)])
        let endpoints = ServiceURLResolver.endpoints(for: c, host: host)
        #expect(endpoints.first?.hostPort == 9091, "51413 is a known non-HTTP port")
        #expect(endpoints.count == 2, "the other port stays available as a secondary")
    }

    @Test("the preference table breaks ties between plausible web ports")
    func preferenceTableOrdering() {
        #expect(ServiceURLResolver.rank([32400, 80, 8080]) == [80, 8080, 32400])
        #expect(ServiceURLResolver.rank([7777, 2283]) == [2283, 7777], "unlisted ports sort numerically")
    }

    @Test("443 and 8443 get an https scheme")
    func httpsPorts() throws {
        let c = container(published: [binding(8443)])
        let primary = try #require(ServiceURLResolver.primaryEndpoint(for: c, host: host))
        #expect(primary.url.scheme == "https")
    }

    @Test("ballast.scheme overrides the scheme guess")
    func schemeOverride() throws {
        let c = container(published: [binding(8080)], labels: ["ballast.scheme": "https"])
        let primary = try #require(ServiceURLResolver.primaryEndpoint(for: c, host: host))
        #expect(primary.url.absoluteString == "https://nas.local:8080")
    }

    @Test("ballast.path appends a path, with or without a leading slash")
    func pathLabel() throws {
        for value in ["/web", "web"] {
            let c = container(published: [binding(8096)], labels: ["ballast.path": value])
            let primary = try #require(ServiceURLResolver.primaryEndpoint(for: c, host: host))
            #expect(primary.url.absoluteString == "http://nas.local:8096/web")
        }
    }

    @Test("non-HTTP ports are offered as links but not probed")
    func nonHTTPPortsNotProbeable() throws {
        let c = container(published: [binding(5433)])
        let primary = try #require(ServiceURLResolver.primaryEndpoint(for: c, host: host))
        #expect(primary.isProbeable == false)
    }

    @Test("ballast.probe=false opts out of probing")
    func probeOptOut() throws {
        let c = container(published: [binding(8080)], labels: ["ballast.probe": "false"])
        let primary = try #require(ServiceURLResolver.primaryEndpoint(for: c, host: host))
        #expect(primary.isProbeable == false)
    }

    @Test("an empty host yields no endpoints rather than a broken URL")
    func emptyHost() {
        #expect(ServiceURLResolver.endpoints(for: container(published: [binding(80)]), host: "").isEmpty)
    }
}

@Suite("Status assessment")
struct StatusResolverTests {

    @Test("a running container with no healthcheck and no probe is healthy")
    func plainRunning() {
        let result = StatusResolver.assess(container: container(), probe: nil, dataIsFresh: true)
        #expect(result.status == .healthy)
        #expect(result.reason == "Running")
    }

    @Test("an unhealthy healthcheck degrades a running container")
    func unhealthyIsDegraded() {
        let result = StatusResolver.assess(
            container: container(health: .unhealthy), probe: .responded(statusCode: 200), dataIsFresh: true
        )
        #expect(result.status == .degraded)
        #expect(result.reason.contains("healthcheck"))
    }

    @Test("a starting healthcheck is degraded, not down")
    func startingIsDegraded() {
        let result = StatusResolver.assess(container: container(health: .starting), probe: nil, dataIsFresh: true)
        #expect(result.status == .degraded)
    }

    @Test("running but not answering its port is degraded")
    func runningButUnreachable() {
        for probe in [ProbeOutcome.timedOut, .refused, .failed("dns")] {
            let result = StatusResolver.assess(container: container(), probe: probe, dataIsFresh: true)
            #expect(result.status == .degraded, "\(probe) should degrade")
        }
    }

    @Test("any HTTP response counts as alive, including 401 and 500")
    func anyResponseIsAlive() {
        for code in [200, 302, 401, 403, 500] {
            let result = StatusResolver.assess(
                container: container(), probe: .responded(statusCode: code), dataIsFresh: true
            )
            #expect(result.status == .healthy, "HTTP \(code) means something is listening")
        }
    }

    @Test("an untrusted certificate still means the service is alive")
    func tlsUntrustedIsAlive() {
        let result = StatusResolver.assess(container: container(), probe: .tlsUntrusted, dataIsFresh: true)
        #expect(result.status == .healthy)
        #expect(result.reason.contains("certificate"))
    }

    @Test("a skipped probe does not degrade a running container")
    func skippedProbeIsNeutral() {
        let result = StatusResolver.assess(
            container: container(), probe: .skipped(reason: "no endpoint"), dataIsFresh: true
        )
        #expect(result.status == .healthy)
    }

    @Test("stopped containers are down, and the reason distinguishes why")
    func stoppedVariants() {
        let clean = StatusResolver.assess(
            container: container(state: .exited, exitCode: 0), probe: nil, dataIsFresh: true
        )
        #expect(clean.status == .down)
        #expect(clean.reason == "Stopped")

        let crashed = StatusResolver.assess(
            container: container(state: .exited, exitCode: 137), probe: nil, dataIsFresh: true
        )
        #expect(crashed.reason.contains("137"))

        let oom = StatusResolver.assess(
            container: container(state: .exited, exitCode: 137, oomKilled: true), probe: nil, dataIsFresh: true
        )
        #expect(oom.reason.contains("out of memory"))
    }

    @Test("a probe never promotes a stopped container to healthy")
    func probeCannotRescueStoppedContainer() {
        // Something else answering on that port must not make a stopped
        // container look fine.
        let result = StatusResolver.assess(
            container: container(state: .exited, exitCode: 1),
            probe: .responded(statusCode: 200),
            dataIsFresh: true
        )
        #expect(result.status == .down)
    }

    @Test("restarting reports the restart count")
    func restarting() {
        let result = StatusResolver.assess(
            container: container(state: .restarting, restartCount: 12), probe: nil, dataIsFresh: true
        )
        #expect(result.status == .degraded)
        #expect(result.reason.contains("12"))
    }

    @Test("stale data makes every container unknown rather than remembered")
    func staleDataYieldsUnknown() {
        // Reporting a remembered "healthy" after losing contact with the NAS
        // would be worse than reporting nothing.
        for state in DockerState.allCases {
            let result = StatusResolver.assess(
                container: container(state: state), probe: nil, dataIsFresh: false
            )
            #expect(result.status == .unknown, "\(state) should be unknown when data is stale")
            #expect(result.reason == "Status unknown")
        }
    }

    @Test("aggregation reports the worst status, with down outranking degraded")
    func aggregation() {
        #expect(StatusResolver.aggregate([]) == .unknown)
        #expect(StatusResolver.aggregate([.init(status: .healthy, reason: "")]) == .healthy)
        #expect(StatusResolver.aggregate([
            .init(status: .healthy, reason: ""), .init(status: .unknown, reason: ""),
        ]) == .unknown)
        #expect(StatusResolver.aggregate([
            .init(status: .healthy, reason: ""), .init(status: .degraded, reason: ""),
        ]) == .degraded)
        #expect(StatusResolver.aggregate([
            .init(status: .degraded, reason: ""), .init(status: .down, reason: ""),
        ]) == .down)
    }
}

@Suite("Ports for containers with no published ports")
struct IndirectPortTests {
    let host = "nas.local"

    /// AdGuard Home on the host network: the image declares DNS, DHCP,
    /// DNS-over-TLS, DNSCrypt and a debug port alongside its web UI, and both
    /// TCP and UDP variants of several.
    private var adguard: Container {
        container(
            name: "adguardhome-host",
            exposed: [53, 67, 68, 80, 443, 853, 3000, 5443, 6060],
            networkMode: "host"
        )
    }

    @Test("non-HTTP exposed ports are never offered as links")
    func filtersNonHTTPExposedPorts() {
        let ports = ServiceURLResolver.endpoints(for: adguard, host: host).compactMap(\.hostPort)
        // Opening a browser against DNS or DHCP achieves nothing.
        #expect(ports.contains(53) == false)
        #expect(ports.contains(67) == false)
        #expect(ports.contains(68) == false)
        #expect(ports.contains(853) == false)
        #expect(ports.contains(5443) == false)
    }

    @Test("the web UI is still offered, and comes first")
    func keepsWebPorts() throws {
        let endpoints = ServiceURLResolver.endpoints(for: adguard, host: host)
        #expect(endpoints.first?.hostPort == 80)
        #expect(endpoints.compactMap(\.hostPort) == [80, 443, 3000, 6060])
    }

    @Test("a port exposed as both TCP and UDP is offered once")
    func deduplicatesExposedPorts() {
        // The parser deduplicates, but guard the resolver too: a menu with
        // "Open port 443" twice is the symptom users actually see.
        let c = container(exposed: [443, 443, 80], networkMode: "host")
        let ports = ServiceURLResolver.endpoints(for: c, host: host).compactMap(\.hostPort)
        #expect(ports == Array(Set(ports)).sorted(by: { ports.firstIndex(of: $0)! < ports.firstIndex(of: $1)! }))
        #expect(ports.filter { $0 == 443 }.count == 1)
    }

    @Test("a container sharing another's network uses the owner's matching binding")
    func resolvesThroughNetworkOwner() throws {
        // mousehole exposes 5010 and runs inside gluetun's network namespace;
        // gluetun publishes 5010 -> 5010, so that is mousehole's real URL.
        let gluetun = container(
            name: "gluetun",
            published: [binding(5010, 5010), binding(8888, 8888), binding(8090, 8090)]
        )
        let mousehole = container(
            name: "mousehole",
            exposed: [5010],
            networkMode: "container:\(gluetun.id)"
        )

        let endpoints = ServiceURLResolver.endpoints(for: mousehole, host: host, networkOwner: gluetun)
        #expect(endpoints.count == 1, "only the matching port, not all of the owner's ports")
        #expect(endpoints[0].url.absoluteString == "http://nas.local:5010")
    }

    @Test("the owner's binding is used even when the host port differs")
    func mapsRemappedPort() throws {
        let owner = container(name: "vpn", published: [binding(9999, 8080)])
        let rider = container(exposed: [8080], networkMode: "container:\(owner.id)")

        let primary = try #require(
            ServiceURLResolver.primaryEndpoint(for: rider, host: host, networkOwner: owner)
        )
        #expect(primary.hostPort == 9999, "the host port, not the container port")
    }

    @Test("with no exact match, the owner's unclaimed ports are offered")
    func noMatchFallsBackToOwnerPorts() throws {
        // A service told to listen on a port its image doesn't declare —
        // qBittorrent with WEBUI_PORT set — can't be matched exactly, and
        // Docker records nothing tying a namespace port to its container.
        let owner = container(name: "vpn", published: [binding(8888, 8888)])
        let rider = container(exposed: [5010], networkMode: "container:\(owner.id)")

        let primary = try #require(
            ServiceURLResolver.primaryEndpoint(for: rider, host: host, networkOwner: owner)
        )
        #expect(primary.hostPort == 8888)
    }

    @Test("ports a sibling matched exactly are not guessed at again")
    func claimedPortsAreExcluded() throws {
        // mousehole matches 5010 exactly, so qbittorrent should be offered
        // 8090 and 8888 rather than competing for a port already spoken for.
        let gluetun = container(
            name: "gluetun",
            published: [binding(5010, 5010), binding(8090, 8090), binding(8888, 8888)]
        )
        let qbit = container(exposed: [8080, 6881], networkMode: "container:\(gluetun.id)")

        let ports = ServiceURLResolver.endpoints(
            for: qbit, host: host, networkOwner: gluetun, claimedOwnerPorts: [5010]
        ).compactMap(\.hostPort)

        #expect(ports.contains(5010) == false, "already claimed by a sibling")
        #expect(ports.first == 8090)
    }

    @Test("an exact match still wins over the fallback")
    func exactMatchBeatsFallback() throws {
        let gluetun = container(
            name: "gluetun",
            published: [binding(5010, 5010), binding(8090, 8090)]
        )
        let mousehole = container(exposed: [5010], networkMode: "container:\(gluetun.id)")

        let endpoints = ServiceURLResolver.endpoints(for: mousehole, host: host, networkOwner: gluetun)
        #expect(endpoints.count == 1)
        #expect(endpoints[0].hostPort == 5010)
    }

    @Test("ballast.port overrides the guess entirely")
    func labelBeatsFallback() throws {
        let owner = container(name: "vpn", published: [binding(8888, 8888), binding(8090, 8090)])
        let rider = container(
            exposed: [8080],
            networkMode: "container:\(owner.id)",
            labels: ["ballast.port": "8090"]
        )

        let endpoints = ServiceURLResolver.endpoints(for: rider, host: host, networkOwner: owner)
        #expect(endpoints.count == 1)
        #expect(endpoints[0].hostPort == 8090)
    }

    @Test("the owner's loopback-only bindings are not used")
    func ignoresOwnerLoopbackBindings() {
        let owner = container(name: "vpn", published: [binding(5010, 5010, ip: "127.0.0.1")])
        let rider = container(exposed: [5010], networkMode: "container:\(owner.id)")
        #expect(ServiceURLResolver.endpoints(for: rider, host: host, networkOwner: owner).isEmpty)
    }

    @Test("networkOwnerID is parsed from the network mode")
    func parsesNetworkOwnerID() {
        #expect(container(networkMode: "container:abc123").networkOwnerID == "abc123")
        #expect(container(networkMode: "bridge").networkOwnerID == nil)
        #expect(container(networkMode: "host").networkOwnerID == nil)
        #expect(container(networkMode: "container:").networkOwnerID == nil)
    }
}
