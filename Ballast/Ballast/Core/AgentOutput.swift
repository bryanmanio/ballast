import Foundation

/// Decodes the tab-separated, per-field-JSON records emitted by
/// `ballast-agent list`. See `nas/ballast-agent` for the producing side.
///
/// The wire format is deliberately boring: a `#ballast <version>` header,
/// one record per container with 14 tab-separated fields each of which is
/// valid JSON on its own, and an `#end <count>` terminator. Splitting on tabs
/// and decoding each field independently avoids having to parse Docker's
/// human-readable port and label strings, which are ambiguous whenever a
/// value contains the delimiter.
struct AgentListOutput: Sendable {
    var protocolVersion: Int
    var containers: [Container]
    /// Non-fatal problems the agent reported, e.g. a container that vanished
    /// between being listed and being inspected. Worth showing, not worth
    /// failing over.
    var warnings: [String] = []
}

/// The image a container was created from, as `ballast-agent images` reports it.
struct ContainerImage: Sendable, Equatable {
    /// Changes whenever the container is recreated onto a different image —
    /// which is what an update looks like from outside.
    var imageID: String
    /// Registry digests, without the repository name. Empty for an image
    /// built on the NAS rather than pulled.
    var digests: [String]
}

enum AgentParseError: Error, Equatable {
    case missingHeader
    case unsupportedProtocol(found: Int, supported: Int)
    case truncated(declared: Int, received: Int)
    case missingTerminator
    case badRecord(line: Int, reason: String)
}

enum AgentOutputParser {
    static let supportedProtocolVersion = 1
    private static let fieldCount = 14

    static func parseList(_ text: String) throws -> AgentListOutput {
        let (version, warnings, records) = try frame(text)

        var containers: [Container] = []
        containers.reserveCapacity(records.count)
        for (offset, line) in records.enumerated() {
            containers.append(try parseRecord(line, lineNumber: offset + 1))
        }
        return AgentListOutput(protocolVersion: version, containers: containers, warnings: warnings)
    }

    /// Decodes `ballast-agent images` into each container's image, keyed by
    /// container id. A container whose image couldn't be inspected is left
    /// out.
    static func parseImages(_ text: String) throws -> [String: ContainerImage] {
        let (_, _, records) = try frame(text)

        var imageOf: [String: String] = [:]
        var digestsOf: [String: [String]] = [:]
        for (offset, line) in records.enumerated() {
            let fields = line.components(separatedBy: "\t")
            guard fields.count == 3 else {
                throw AgentParseError.badRecord(line: offset + 1, reason: "expected 3 fields, found \(fields.count)")
            }
            do {
                let kind = try JSONFragment.decode(String.self, from: fields[0])
                let id = try JSONFragment.decode(String.self, from: fields[1])
                switch kind {
                case "container":
                    imageOf[id] = try JSONFragment.decode(String.self, from: fields[2])
                case "image":
                    // `name@sha256:…` — the name differs by registry, the
                    // digest doesn't, so only the digest is kept, once.
                    let references = try JSONFragment.decode([String]?.self, from: fields[2]) ?? []
                    var seen = Set<String>()
                    digestsOf[id] = references
                        .compactMap { $0.split(separator: "@", maxSplits: 1).last.map(String.init) }
                        .filter { seen.insert($0).inserted }
                default:
                    // Newer agents may add record kinds; skip what isn't ours.
                    continue
                }
            } catch {
                throw AgentParseError.badRecord(line: offset + 1, reason: "\(error)")
            }
        }

        return imageOf.compactMapValues { imageID in
            digestsOf[imageID].map { ContainerImage(imageID: imageID, digests: $0) }
        }
    }

    /// Checks the `#ballast` header and `#end` terminator every subcommand's
    /// output shares, and splits what's between them into directives and
    /// records.
    private static func frame(_ text: String) throws -> (version: Int, warnings: [String], records: [String]) {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)

        guard let header = lines.first, header.hasPrefix("#ballast ") else {
            throw AgentParseError.missingHeader
        }
        guard let version = Int(header.dropFirst("#ballast ".count).trimmingCharacters(in: .whitespaces)) else {
            throw AgentParseError.missingHeader
        }
        guard version == supportedProtocolVersion else {
            throw AgentParseError.unsupportedProtocol(found: version, supported: supportedProtocolVersion)
        }
        lines.removeFirst()

        // The terminator is how we tell "no containers" apart from output cut
        // short by a dropped SSH connection.
        guard let terminator = lines.last, terminator.hasPrefix("#end ") else {
            throw AgentParseError.missingTerminator
        }
        let declared = Int(terminator.dropFirst("#end ".count).trimmingCharacters(in: .whitespaces)) ?? -1
        lines.removeLast()

        // Directive lines are separated out so new ones can be added to the
        // agent without older clients failing to parse its output.
        let warnings = lines
            .filter { $0.hasPrefix("#warn ") }
            .map { String($0.dropFirst("#warn ".count)) }
        let records = lines.filter { !$0.hasPrefix("#") }

        guard declared == records.count else {
            throw AgentParseError.truncated(declared: declared, received: records.count)
        }
        return (version, warnings, records)
    }

    private static func parseRecord(_ line: String, lineNumber: Int) throws -> Container {
        let fields = line.components(separatedBy: "\t")
        guard fields.count == fieldCount else {
            throw AgentParseError.badRecord(
                line: lineNumber,
                reason: "expected \(fieldCount) fields, found \(fields.count)"
            )
        }

        func decode<T: Decodable>(_ index: Int, _ type: T.Type, _ label: String) throws -> T {
            do {
                return try JSONFragment.decode(type, from: fields[index])
            } catch {
                throw AgentParseError.badRecord(line: lineNumber, reason: "field \(index) (\(label)): \(error)")
            }
        }

        let rawName: String = try decode(1, String.self, "name")
        let rawState: String = try decode(2, String.self, "state")
        let rawHealth: String? = try decode(3, String?.self, "health")
        // The whole map can be null, not just individual entries.
        let portMap: [String: [HostBindingDTO]?]? = try decode(8, [String: [HostBindingDTO]?]?.self, "ports")
        let exposed: [String: EmptyObject]? = try decode(9, [String: EmptyObject]?.self, "exposedPorts")
        let labels: [String: String]? = try decode(11, [String: String]?.self, "labels")
        let networkMode: String? = try decode(10, String?.self, "networkMode")

        return Container(
            id: try decode(0, String.self, "id"),
            name: rawName.hasPrefix("/") ? String(rawName.dropFirst()) : rawName,
            state: DockerState(rawValueOrUnknown: rawState),
            health: HealthState(dockerValue: rawHealth),
            exitCode: try decode(4, Int.self, "exitCode"),
            oomKilled: try decode(5, Bool.self, "oomKilled"),
            restartCount: try decode(6, Int.self, "restartCount"),
            image: try decode(7, String.self, "image"),
            publishedPorts: Self.bindings(from: portMap),
            exposedPorts: Self.exposedPorts(from: exposed),
            networkMode: networkMode ?? "",
            labels: labels ?? [:],
            startedAt: DockerTimestamp.parse(try decode(12, String?.self, "startedAt")),
            finishedAt: DockerTimestamp.parse(try decode(13, String?.self, "finishedAt"))
        )
    }

    /// Docker's port map looks like `{"32400/tcp": [{"HostIp": "0.0.0.0", "HostPort": "32400"}]}`,
    /// with a null value for ports that are exposed but not published.
    private static func bindings(from map: [String: [HostBindingDTO]?]?) -> [PortBinding] {
        guard let map else { return [] }
        var result: [PortBinding] = []
        for (key, value) in map {
            guard let value else { continue }
            let (containerPort, transport) = splitPortKey(key)
            for dto in value {
                guard let hostPort = Int(dto.HostPort) else { continue }
                result.append(PortBinding(
                    containerPort: containerPort,
                    transport: transport,
                    hostIP: dto.HostIp.isEmpty ? nil : dto.HostIp,
                    hostPort: hostPort
                ))
            }
        }
        return result.sorted { ($0.hostPort, $0.transport) < ($1.hostPort, $1.transport) }
    }

    private static func exposedPorts(from map: [String: EmptyObject]?) -> [Int] {
        guard let map else { return [] }
        // Deduplicated: an image commonly declares both "53/tcp" and
        // "53/udp", which are one port as far as a link is concerned.
        return Set(map.keys.map { splitPortKey($0).0 }).sorted()
    }

    /// `"32400/tcp"` -> `(32400, "tcp")`
    private static func splitPortKey(_ key: String) -> (Int, String) {
        let parts = key.split(separator: "/", maxSplits: 1)
        let port = Int(parts.first ?? "") ?? 0
        let transport = parts.count > 1 ? String(parts[1]) : "tcp"
        return (port, transport)
    }

    private struct HostBindingDTO: Decodable {
        var HostIp: String
        var HostPort: String
    }

    /// Stands in for Docker's `{}` placeholder values in `ExposedPorts`.
    private struct EmptyObject: Decodable {}
}

/// Decodes a single JSON value that may be a top-level fragment such as
/// `"name"`, `3`, `true` or `null`. Wrapping in an array sidesteps any
/// question of whether the platform's decoder accepts bare fragments.
enum JSONFragment {
    static func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        let wrapped = "[\(json)]"
        let values = try JSONDecoder().decode([T].self, from: Data(wrapped.utf8))
        guard let first = values.first else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "empty fragment"))
        }
        return first
    }
}

enum DockerTimestamp {
    /// Docker uses RFC 3339 with variable fractional-second precision, and
    /// writes year 1 to mean "never".
    static func parse(_ value: String?) -> Date? {
        guard let value, !value.isEmpty, !value.hasPrefix("0001-01-01") else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }
}
