import Foundation

/// Talks to `ballast-agent` on the NAS over SSH.
///
/// Deliberately shells out to `/usr/bin/ssh` rather than linking an SSH
/// library: that reuses the user's existing keys, agent, and `~/.ssh/config`
/// aliases, which means Ballast stores no credentials of its own.
struct SSHContainerSource: ContainerSource {
    /// An ssh destination: `user@host`, or an alias from `~/.ssh/config`.
    var destination: String
    var agentPath: String = SSHContainerSource.defaultAgentPath
    var timeout: Duration = .seconds(12)
    var sshExecutable = URL(fileURLWithPath: "/usr/bin/ssh")

    static let defaultAgentPath = "/usr/local/bin/ballast-agent"

    func fetch() async throws -> AgentListOutput {
        let output = try await runAgent(subcommand: "list")
        do {
            return try AgentOutputParser.parseList(output)
        } catch let error as AgentParseError {
            throw BallastError.parse(error)
        }
    }

    func check() async throws -> AgentCheck {
        let output = try await runAgent(subcommand: "check")
        return try parseCheck(output)
    }

    func images() async throws -> [String: ContainerImage] {
        let output = try await runAgent(subcommand: "images")
        do {
            return try AgentOutputParser.parseImages(output)
        } catch let error as AgentParseError {
            throw BallastError.parse(error)
        }
    }

    func perform(_ action: ContainerAction, on container: String) async throws {
        // Stopping can take up to Docker's grace period, so this waits
        // longer than a listing would.
        _ = try await runAgent(
            subcommand: action.rawValue,
            argument: container,
            timeout: .seconds(45)
        )
    }

    // MARK: - Invocation

    private func runAgent(
        subcommand: String,
        argument: String? = nil,
        timeout: Duration? = nil
    ) async throws -> String {
        guard !destination.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw BallastError.notConfigured
        }

        let result = await ProcessRunner.run(
            executable: sshExecutable,
            arguments: Self.sshArguments(
                destination: destination,
                agentPath: agentPath,
                subcommand: subcommand,
                argument: argument
            ),
            timeout: timeout ?? self.timeout
        )

        guard result.exitCode == 0, !result.timedOut else {
            throw BallastError.classify(
                exitCode: result.exitCode,
                stderr: result.stderr,
                timedOut: result.timedOut
            )
        }
        return result.stdout
    }

    /// Built as a static function so the exact flags are easy to assert on.
    static func sshArguments(
        destination: String,
        agentPath: String,
        subcommand: String,
        argument: String? = nil
    ) -> [String] {
        var arguments = [
            // Never prompt. A password or host-key prompt from a background
            // refresh would hang invisibly, so fail fast and report instead.
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            // Reuse one connection across refreshes: without this every poll
            // pays a full TCP and key exchange.
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=120",
            // A dedicated socket path so Ballast never disturbs, or is
            // disturbed by, the user's own ssh sessions.
            "-o", "ControlPath=~/.ssh/ballast-%r@%h:%p",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=2",
            "-o", "LogLevel=ERROR",
            destination,
            // -n makes sudo fail rather than try to prompt.
            "sudo", "-n", agentPath, subcommand,
        ]
        // Passed as its own argv entry, never interpolated into a command
        // string, so there is no shell for it to escape into.
        if let argument { arguments.append(argument) }
        return arguments
    }

    // MARK: - check parsing

    private func parseCheck(_ output: String) throws -> AgentCheck {
        var fields: [String: String] = [:]
        var version: Int?

        for line in output.split(separator: "\n") {
            if line.hasPrefix("#ballast ") {
                version = Int(line.dropFirst("#ballast ".count).trimmingCharacters(in: .whitespaces))
                continue
            }
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            fields[String(parts[0])] = String(parts[1]).trimmingCharacters(in: .whitespaces)
        }

        guard let version else {
            throw BallastError.parse(.missingHeader)
        }
        guard version == AgentOutputParser.supportedProtocolVersion else {
            throw BallastError.parse(.unsupportedProtocol(
                found: version,
                supported: AgentOutputParser.supportedProtocolVersion
            ))
        }

        return AgentCheck(
            protocolVersion: version,
            dockerPath: fields["docker-path"] ?? "",
            dockerServerVersion: fields["docker-server"] ?? "",
            agentPath: fields["agent-path"] ?? agentPath,
            effectiveUID: Int(fields["euid"] ?? "") ?? -1
        )
    }
}
