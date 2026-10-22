import Foundation
import Testing
@testable import BallastCore

@Suite("Failure classification")
struct BallastErrorTests {

    private func classify(_ stderr: String, exitCode: Int32 = 1, timedOut: Bool = false) -> BallastError {
        BallastError.classify(exitCode: exitCode, stderr: stderr, timedOut: timedOut)
    }

    @Test("a timeout outranks whatever is on stderr")
    func timeoutWins() {
        #expect(classify("Permission denied (publickey).", timedOut: true) == .timedOut)
    }

    @Test("the agent's own sentinels are recognised")
    func agentSentinels() {
        #expect(classify("ballast: docker-not-found", exitCode: 3) == .dockerNotFound)
        #expect(classify("ballast: docker-unavailable", exitCode: 4) == .dockerUnavailable)
        #expect(classify("ballast: inspect-failed", exitCode: 5) == .dockerUnavailable)
    }

    @Test("sudo refusing to run without a password is its own case")
    func sudoDenied() {
        #expect(classify("sudo: a password is required") == .sudoDenied)
        #expect(classify("sudo: no tty present and no askpass program specified") == .sudoDenied)
    }

    @Test("a missing agent is distinguished from a broken one")
    func agentMissing() {
        #expect(classify("sudo: /usr/local/bin/ballast-agent: command not found") == .agentMissing)
        #expect(classify("bash: /usr/local/bin/ballast-agent: No such file or directory") == .agentMissing)
        #expect(classify("", exitCode: 127) == .agentMissing)
    }

    @Test("an agent that doesn't know a subcommand asks to be redeployed")
    func agentOutdated() {
        #expect(classify(
            "ballast: usage: ballast-agent {list|check|version|start|stop|restart <container>}",
            exitCode: 2
        ) == .agentOutdated)
    }

    @Test("SSH-level problems map to their own cases")
    func sshProblems() {
        #expect(classify("Host key verification failed.", exitCode: 255) == .hostKeyUnverified)

        if case .sshAuthFailed = classify("Permission denied (publickey).", exitCode: 255) {} else {
            Issue.record("publickey rejection should be an auth failure")
        }
        if case .hostUnreachable = classify("ssh: Could not resolve hostname nas: nodename nor servname provided", exitCode: 255) {} else {
            Issue.record("DNS failure should be unreachable")
        }
        if case .hostUnreachable = classify("ssh: connect to host nas port 22: No route to host", exitCode: 255) {} else {
            Issue.record("no route should be unreachable")
        }
        if case .hostUnreachable = classify("ssh: connect to host nas port 22: Operation timed out", exitCode: 255) {} else {
            Issue.record("connect timeout should be unreachable")
        }
    }

    @Test("an unattributable SSH failure is still reported as an SSH failure")
    func unknownSSHFailure() {
        #expect(classify("something weird happened", exitCode: 255)
            == .sshFailed(exitCode: 255, detail: "something weird happened"))
    }

    @Test("a nonzero exit we can't attribute is reported as an agent failure")
    func unknownAgentFailure() {
        #expect(classify("garbled", exitCode: 9) == .agentFailed(exitCode: 9, detail: "garbled"))
    }

    @Test("detail is the first non-empty line, not the whole dump")
    func detailIsFirstLine() {
        let error = classify("\n\n  ssh: connect to host nas port 22: No route to host\nmore noise\n", exitCode: 255)
        #expect(error == .hostUnreachable(detail: "ssh: connect to host nas port 22: No route to host"))
    }

    @Test("every case offers a title and an actionable hint")
    func allCasesExplainThemselves() {
        let all: [BallastError] = [
            .notConfigured, .hostUnreachable(detail: ""), .hostKeyUnverified,
            .sshAuthFailed(detail: ""), .sshFailed(exitCode: 255, detail: ""), .timedOut,
            .agentMissing, .agentOutdated, .sudoDenied, .dockerNotFound, .dockerUnavailable,
            .agentFailed(exitCode: 1, detail: ""), .parse(.missingHeader),
        ]
        for error in all {
            #expect(!error.title.isEmpty, "\(error) needs a title")
            #expect(!error.hint.isEmpty, "\(error) needs a hint")
        }
    }
}

@Suite("SSH invocation")
struct SSHContainerSourceTests {

    @Test("never prompts, so a background refresh can't hang invisibly")
    func neverPrompts() {
        let args = SSHContainerSource.sshArguments(
            destination: "bryan@nas", agentPath: "/usr/local/bin/ballast-agent", subcommand: "list"
        )
        #expect(args.contains("BatchMode=yes"))
        #expect(args.contains("ConnectTimeout=5"))
        // -n makes sudo fail outright instead of trying to read a password.
        #expect(args.contains("-n"))
    }

    @Test("reuses one connection on a socket of its own")
    func reusesConnection() {
        let args = SSHContainerSource.sshArguments(
            destination: "bryan@nas", agentPath: "/usr/local/bin/ballast-agent", subcommand: "list"
        )
        #expect(args.contains("ControlMaster=auto"))
        #expect(args.contains("ControlPersist=120"))
        // A dedicated path keeps Ballast out of the user's own ssh sessions.
        #expect(args.contains { $0.hasPrefix("ControlPath=") && $0.contains("ballast-") })
    }

    @Test("does not weaken host key checking")
    func doesNotWeakenHostKeyChecking() {
        let args = SSHContainerSource.sshArguments(
            destination: "bryan@nas", agentPath: "/usr/local/bin/ballast-agent", subcommand: "list"
        )
        #expect(args.contains { $0.contains("StrictHostKeyChecking") } == false)
        #expect(args.contains { $0.contains("accept-new") } == false)
    }

    @Test("offers setup's key ahead of ssh's defaults, before the destination")
    func offersSetupKey() throws {
        let args = SSHContainerSource.sshArguments(
            destination: "bryan@nas", agentPath: "/usr/local/bin/ballast-agent", subcommand: "list",
            identityFiles: ["~/.ssh/id_ballast", "~/.ssh/id_ed25519"]
        )
        let setupKey = try #require(args.firstIndex(of: "IdentityFile=~/.ssh/id_ballast"))
        let defaultKey = try #require(args.firstIndex(of: "IdentityFile=~/.ssh/id_ed25519"))
        let destination = try #require(args.firstIndex(of: "bryan@nas"))
        #expect(setupKey < defaultKey)
        #expect(defaultKey < destination)
        #expect(args[setupKey - 1] == "-o")
    }

    @Test("names no keys when setup's key is missing, leaving ssh its own defaults")
    func noSetupKey() throws {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "ballast-no-key-\(UUID().uuidString)").path
        #expect(SSHContainerSource.identityFiles(home: home).isEmpty)
    }

    @Test("names ssh's defaults alongside setup's key, so they keep working")
    func keepsDefaults() throws {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "ballast-key-\(UUID().uuidString)")
        let ssh = home.appending(path: ".ssh")
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        FileManager.default.createFile(atPath: ssh.appending(path: "id_ballast").path, contents: Data())

        let files = SSHContainerSource.identityFiles(home: home.path)
        #expect(files.first == "~/.ssh/id_ballast")
        #expect(files.contains("~/.ssh/id_ed25519"))
        #expect(files.contains("~/.ssh/id_rsa"))
    }

    @Test("the remote command is the agent, with the destination before it")
    func remoteCommandShape() throws {
        let args = SSHContainerSource.sshArguments(
            destination: "my-nas", agentPath: "/opt/ballast-agent", subcommand: "check"
        )
        let destinationIndex = try #require(args.firstIndex(of: "my-nas"))
        let agentIndex = try #require(args.firstIndex(of: "/opt/ballast-agent"))
        #expect(destinationIndex < agentIndex)
        #expect(args.last == "check")
    }

    @Test("an empty destination fails before launching ssh")
    func emptyDestinationIsRejected() async {
        let source = SSHContainerSource(destination: "   ")
        await #expect(throws: BallastError.notConfigured) { try await source.fetch() }
    }
}
