import Foundation
import Network

/// Which hostname to build service URLs from.
struct HostSelection: Sendable, Equatable {
    var host: String
    /// True when we fell back to the away-from-home hostname.
    var isRemote: Bool
}

/// Chooses between the LAN hostname and a remote one (typically a Tailscale
/// name) based on what actually answers, so the same menu works at home and
/// away without the user switching anything.
struct HostResolver: Sendable {
    var lanHost: String
    var remoteHost: String
    /// Port used purely as a reachability test. SSH's port is the safest
    /// choice: Ballast needs it anyway, so it's guaranteed to be open.
    var port: Int = 22
    var timeout: Duration = .seconds(1)

    func resolve() async -> HostSelection? {
        let lan = lanHost.trimmingCharacters(in: .whitespaces)
        let remote = remoteHost.trimmingCharacters(in: .whitespaces)

        if lan.isEmpty { return remote.isEmpty ? nil : HostSelection(host: remote, isRemote: true) }
        // With no remote host configured there is nothing to choose between,
        // so skip the probe entirely.
        if remote.isEmpty { return HostSelection(host: lan, isRemote: false) }

        if await TCPProbe.canConnect(host: lan, port: port, timeout: timeout) {
            return HostSelection(host: lan, isRemote: false)
        }
        if await TCPProbe.canConnect(host: remote, port: port, timeout: timeout) {
            return HostSelection(host: remote, isRemote: true)
        }
        // Nothing answered. Keep the LAN name so rows still render a URL;
        // reachability is reported separately from the SSH fetch.
        return HostSelection(host: lan, isRemote: false)
    }
}

enum TCPProbe {
    /// True if a TCP connection can be established within `timeout`.
    static func canConnect(host: String, port: Int, timeout: Duration) async -> Bool {
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return false }

        let connection = NWConnection(
            to: .hostPort(host: NWEndpoint.Host(host), port: port),
            using: .tcp
        )

        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    let resumed = Resumer(continuation)
                    connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            resumed.finish(true)
                        case .failed, .cancelled:
                            resumed.finish(false)
                        case .waiting:
                            // Connection refused or unroutable; NWConnection
                            // keeps retrying, but for a liveness check one
                            // rejection is answer enough.
                            resumed.finish(false)
                        case .setup, .preparing:
                            break
                        @unknown default:
                            break
                        }
                    }
                    connection.start(queue: .global(qos: .userInitiated))
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }

            let result = await group.next() ?? false
            group.cancelAll()
            connection.cancel()
            return result
        }
    }

    /// Guards a continuation against the multiple state callbacks NWConnection
    /// can deliver; resuming twice would trap.
    private final class Resumer: @unchecked Sendable {
        private var continuation: CheckedContinuation<Bool, Never>?
        private let lock = NSLock()

        init(_ continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }

        func finish(_ value: Bool) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }
}
