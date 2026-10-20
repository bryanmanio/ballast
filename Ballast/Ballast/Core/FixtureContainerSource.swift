import Foundation

/// A stand-in source with a realistic container set, so the menu can be built
/// and inspected without a NAS on the other end. Selected by launching with
/// `-BallastUseFixtures YES`.
struct FixtureContainerSource: ContainerSource {
    var delay: Duration = .milliseconds(120)

    func check() async throws -> AgentCheck {
        AgentCheck(
            protocolVersion: 1,
            dockerPath: "/usr/local/bin/docker",
            dockerServerVersion: "24.0.2",
            agentPath: SSHContainerSource.defaultAgentPath,
            effectiveUID: 0
        )
    }

    func perform(_ action: ContainerAction, on container: String) async throws {
        try? await Task.sleep(for: .milliseconds(400))
    }

    func fetch() async throws -> AgentListOutput {
        try? await Task.sleep(for: delay)
        return AgentListOutput(
            protocolVersion: 1,
            containers: Self.containers,
            warnings: ["skipped 1 of 13 containers: Error: No such object: 3f8a1c"]
        )
    }

    static let containers: [Container] = [
        make(
            name: "plex", state: .running, health: .healthy,
            image: "plexinc/pms-docker:latest",
            exposed: [32400], networkMode: "host",
            labels: ["ballast.port": "32400"],
            startedDaysAgo: 18
        ),
        make(
            name: "immich-server", state: .running, health: .healthy,
            image: "ghcr.io/immich-app/immich-server:release",
            published: [binding(2283)],
            labels: ["com.docker.compose.project": "immich"],
            startedDaysAgo: 4
        ),
        make(
            name: "immich-machine-learning", state: .running, health: .healthy,
            image: "ghcr.io/immich-app/immich-machine-learning:release",
            labels: ["com.docker.compose.project": "immich"],
            startedDaysAgo: 4
        ),
        make(
            name: "immich-postgres", state: .running, health: .unhealthy,
            image: "tensorchord/pgvecto-rs:pg14-v0.2.0",
            published: [binding(5432, ip: "127.0.0.1")], restartCount: 7,
            labels: ["com.docker.compose.project": "immich"],
            startedDaysAgo: 4
        ),
        make(
            name: "paperless-webserver", state: .running, health: .healthy,
            image: "ghcr.io/paperless-ngx/paperless-ngx:latest",
            published: [binding(8000)],
            labels: ["com.docker.compose.project": "paperless"],
            startedDaysAgo: 31
        ),
        make(
            name: "paperless-redis", state: .running,
            image: "redis:7",
            published: [binding(6379, ip: "127.0.0.1")],
            labels: ["com.docker.compose.project": "paperless"],
            startedDaysAgo: 31
        ),
        make(
            name: "jellyfin", state: .running,
            image: "jellyfin/jellyfin:10.9.11",
            published: [binding(8096), binding(8920), binding(7359, transport: "udp")],
            startedDaysAgo: 9
        ),
        make(
            name: "vaultwarden", state: .running, health: .starting,
            image: "vaultwarden/server:latest",
            published: [binding(8222)],
            startedMinutesAgo: 1
        ),
        make(
            name: "uptime-kuma", state: .restarting,
            image: "louislam/uptime-kuma:1",
            published: [binding(3001)], restartCount: 23,
            startedMinutesAgo: 2
        ),
        make(
            name: "transmission", state: .exited, exitCode: 137, oomKilled: true,
            image: "linuxserver/transmission:latest",
            published: [binding(9091), binding(51413)],
            startedDaysAgo: 2, finishedHoursAgo: 11
        ),
        make(
            name: "scrutiny", state: .exited, exitCode: 0,
            image: "analogj/scrutiny:master-omnibus",
            published: [binding(8085)],
            startedDaysAgo: 40, finishedHoursAgo: 72
        ),
        make(
            name: "watchtower", state: .running,
            image: "containrrr/watchtower:latest",
            labels: ["ballast.hide": "false"],
            startedDaysAgo: 18
        ),
    ]

    private static func binding(_ port: Int, ip: String = "0.0.0.0", transport: String = "tcp") -> PortBinding {
        PortBinding(containerPort: port, transport: transport, hostIP: ip, hostPort: port)
    }

    private static func make(
        name: String,
        state: DockerState,
        health: HealthState = .undefined,
        exitCode: Int = 0,
        oomKilled: Bool = false,
        image: String,
        published: [PortBinding] = [],
        exposed: [Int] = [],
        networkMode: String = "bridge",
        restartCount: Int = 0,
        labels: [String: String] = [:],
        startedDaysAgo: Int? = nil,
        startedMinutesAgo: Int? = nil,
        finishedHoursAgo: Int? = nil
    ) -> Container {
        var started: Date?
        if let startedDaysAgo { started = Date(timeIntervalSinceNow: -Double(startedDaysAgo) * 86_400) }
        if let startedMinutesAgo { started = Date(timeIntervalSinceNow: -Double(startedMinutesAgo) * 60) }
        return Container(
            id: name + String(repeating: "0", count: 24),
            name: name, state: state, health: health, exitCode: exitCode,
            oomKilled: oomKilled, restartCount: restartCount, image: image,
            publishedPorts: published, exposedPorts: exposed, networkMode: networkMode,
            labels: labels, startedAt: started,
            finishedAt: finishedHoursAgo.map { Date(timeIntervalSinceNow: -Double($0) * 3_600) }
        )
    }
}

/// Canned probe results so fixture mode shows a realistic mix of states
/// without making real network requests to a host that doesn't exist.
struct FixtureProbe: ServiceProbing {
    func probe(_ targets: [String: URL]) async -> [String: ProbeOutcome] {
        targets.mapValues { url in
            switch url.port {
            // Pretend this one is running but wedged — the case Docker's own
            // state can't tell you about.
            case 8222: .timedOut
            case 8085: .refused
            default: .responded(statusCode: 200)
            }
        }
    }
}
