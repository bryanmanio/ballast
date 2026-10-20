import Foundation
import Testing
@testable import BallastCore

private func loadFixture(_ name: String) throws -> String {
    let url = try #require(
        Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures"),
        "fixture \(name).txt not found in test bundle"
    )
    return try String(contentsOf: url, encoding: .utf8)
}

@Suite("Agent output parsing")
struct AgentOutputParserTests {

    @Test("parses every record in a realistic capture")
    func parsesFixture() throws {
        let output = try AgentOutputParser.parseList(try loadFixture("list-sample"))

        #expect(output.protocolVersion == 1)
        #expect(output.containers.count == 6)
        #expect(output.containers.map(\.name) == [
            "plex", "immich-server", "immich-postgres", "jellyfin", "transmission", "watchtower",
        ])
    }

    @Test("strips the leading slash Docker puts on names")
    func stripsNameSlash() throws {
        let plex = try firstContainer(named: "plex")
        #expect(plex.name == "plex")
    }

    @Test("reads state, health, exit code and OOM flag")
    func readsStateFields() throws {
        let immich = try firstContainer(named: "immich-server")
        #expect(immich.state == .running)
        #expect(immich.health == .healthy)
        #expect(immich.restartCount == 2)

        let postgres = try firstContainer(named: "immich-postgres")
        #expect(postgres.health == .unhealthy)

        let transmission = try firstContainer(named: "transmission")
        #expect(transmission.state == .exited)
        #expect(transmission.state.isUp == false)
        #expect(transmission.exitCode == 137)
        #expect(transmission.oomKilled)
    }

    @Test("treats a missing healthcheck as undefined, not unhealthy")
    func missingHealthcheckIsUndefined() throws {
        let jellyfin = try firstContainer(named: "jellyfin")
        #expect(jellyfin.health == .undefined)
    }

    @Test("decodes the port map including transport and host IP")
    func decodesPorts() throws {
        let jellyfin = try firstContainer(named: "jellyfin")
        #expect(jellyfin.publishedPorts.count == 3)
        #expect(jellyfin.publishedPorts.contains {
            $0.hostPort == 8096 && $0.containerPort == 8096 && $0.transport == "tcp"
        })
        #expect(jellyfin.publishedPorts.contains { $0.hostPort == 7359 && $0.transport == "udp" })
    }

    @Test("marks loopback-only bindings so they never become a URL")
    func detectsLoopbackBinding() throws {
        let postgres = try firstContainer(named: "immich-postgres")
        let binding = try #require(postgres.publishedPorts.first)
        #expect(binding.isLoopbackOnly)
        #expect(postgres.candidateHostPorts.isEmpty)
    }

    @Test("prefers TCP over UDP when ordering candidate ports")
    func ordersCandidatePorts() throws {
        let jellyfin = try firstContainer(named: "jellyfin")
        #expect(jellyfin.candidateHostPorts.prefix(2).allSatisfy { $0 == 8096 || $0 == 8920 })
        #expect(jellyfin.candidateHostPorts.contains(7359))
    }

    @Test("keeps exposed ports for host-network containers")
    func readsExposedPorts() throws {
        let plex = try firstContainer(named: "plex")
        #expect(plex.usesHostNetwork)
        #expect(plex.publishedPorts.isEmpty)
        #expect(plex.exposedPorts == [32400])
        #expect(plex.labelPort == 32400)
    }

    @Test("tolerates null labels and null exposed ports")
    func tolerateNulls() throws {
        let transmission = try firstContainer(named: "transmission")
        #expect(transmission.labels.isEmpty)

        let watchtower = try firstContainer(named: "watchtower")
        #expect(watchtower.exposedPorts.isEmpty)
        #expect(watchtower.health == .starting)
    }

    @Test("reads compose project and ballast labels")
    func readsLabels() throws {
        #expect(try firstContainer(named: "immich-server").composeProject == "immich")
        #expect(try firstContainer(named: "jellyfin").labelURL == "https://jellyfin.example.com")
        #expect(try firstContainer(named: "transmission").composeProject == nil)
    }

    @Test("parses fractional and whole-second timestamps, and treats year 1 as never")
    func parsesTimestamps() throws {
        let plex = try firstContainer(named: "plex")
        #expect(plex.startedAt != nil)
        #expect(plex.finishedAt == nil, "year 0001 means never, not a real date")

        let immich = try firstContainer(named: "immich-server")
        #expect(immich.startedAt != nil, "fractional seconds with one digit must parse")

        let postgres = try firstContainer(named: "immich-postgres")
        #expect(postgres.startedAt != nil, "whole-second timestamps must parse")

        let transmission = try firstContainer(named: "transmission")
        #expect(transmission.finishedAt != nil)
    }

    // MARK: Malformed input

    @Test("rejects output with no header")
    func rejectsMissingHeader() {
        #expect(throws: AgentParseError.missingHeader) {
            try AgentOutputParser.parseList("some junk\n#end 0\n")
        }
    }

    @Test("rejects a protocol version it does not understand")
    func rejectsFutureProtocol() {
        #expect(throws: AgentParseError.unsupportedProtocol(found: 99, supported: 1)) {
            try AgentOutputParser.parseList("#ballast 99\n#end 0\n")
        }
    }

    @Test("detects output truncated by a dropped connection")
    func detectsTruncation() throws {
        let full = try loadFixture("list-sample")
        // Keep the header and two records, drop the rest including #end.
        let cut = full.split(separator: "\n").prefix(3).joined(separator: "\n") + "\n"
        #expect(throws: AgentParseError.missingTerminator) {
            try AgentOutputParser.parseList(cut)
        }
    }

    @Test("detects a record count that disagrees with the terminator")
    func detectsCountMismatch() throws {
        let full = try loadFixture("list-sample")
        let tampered = full.replacingOccurrences(of: "#end 6", with: "#end 9")
        #expect(throws: AgentParseError.truncated(declared: 9, received: 6)) {
            try AgentOutputParser.parseList(tampered)
        }
    }

    @Test("reports which record and field failed")
    func reportsBadRecord() {
        let input = "#ballast 1\n\"id\"\t\"/name\"\n#end 1\n"
        #expect(throws: AgentParseError.badRecord(line: 1, reason: "expected 14 fields, found 2")) {
            try AgentOutputParser.parseList(input)
        }
    }

    @Test("accepts a NAS with no containers")
    func acceptsEmptyList() throws {
        let output = try AgentOutputParser.parseList("#ballast 1\n#end 0\n")
        #expect(output.containers.isEmpty)
    }

    // MARK: Helper

    private func firstContainer(named name: String) throws -> Container {
        let output = try AgentOutputParser.parseList(try loadFixture("list-sample"))
        return try #require(output.containers.first { $0.name == name })
    }
}

@Suite("Agent directive lines")
struct AgentDirectiveTests {

    @Test("a #warn line is collected, not parsed as a container")
    func collectsWarnings() throws {
        let input = """
        #ballast 1
        #warn skipped 1 of 3 containers: Error: No such object: abc123
        #end 0
        """
        let output = try AgentOutputParser.parseList(input)
        #expect(output.containers.isEmpty)
        #expect(output.warnings == ["skipped 1 of 3 containers: Error: No such object: abc123"])
    }

    @Test("the record count ignores directive lines")
    func countExcludesDirectives() throws {
        // #end counts containers, so a warning line must not make the parser
        // think the output was truncated.
        let full = try String(
            contentsOf: #require(Bundle.module.url(forResource: "list-sample", withExtension: "txt", subdirectory: "Fixtures")),
            encoding: .utf8
        )
        let withWarning = full.replacingOccurrences(of: "#end 6", with: "#warn skipped 1 container\n#end 6")
        let output = try AgentOutputParser.parseList(withWarning)
        #expect(output.containers.count == 6)
        #expect(output.warnings.count == 1)
    }

    @Test("an unknown directive is ignored rather than fatal")
    func ignoresUnknownDirectives() throws {
        // Lets the agent gain new directives without breaking older clients.
        let output = try AgentOutputParser.parseList("#ballast 1\n#future something\n#end 0\n")
        #expect(output.containers.isEmpty)
        #expect(output.warnings.isEmpty)
    }
}

@Suite("Containers missing optional fields")
struct MinimalRecordTests {

    /// Most containers have no healthcheck, no exposed ports and no labels.
    /// Docker reports those as absent, and an early version of the agent
    /// failed on exactly this shape, so it is pinned here.
    @Test("a container with every optional field null still parses")
    func parsesMinimalRecord() throws {
        let url = try #require(Bundle.module.url(
            forResource: "list-minimal", withExtension: "txt", subdirectory: "Fixtures"
        ))
        let output = try AgentOutputParser.parseList(try String(contentsOf: url, encoding: .utf8))

        let container = try #require(output.containers.first)
        #expect(container.name == "bare")
        #expect(container.state == .running)
        #expect(container.health == .undefined)
        #expect(container.publishedPorts.isEmpty)
        #expect(container.exposedPorts.isEmpty)
        #expect(container.labels.isEmpty)
        #expect(container.networkMode == "")
        #expect(container.composeProject == nil)
        #expect(container.finishedAt == nil)
    }
}
