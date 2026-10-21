import Foundation

/// Result of `ballast-agent check`, used by Settings to prove the setup works.
struct AgentCheck: Sendable, Equatable {
    var protocolVersion: Int
    var dockerPath: String
    var dockerServerVersion: String
    var agentPath: String
    var effectiveUID: Int

    var runningAsRoot: Bool { effectiveUID == 0 }
}

/// Where container data comes from.
///
/// The app only ever talks to this protocol, so the SSH transport can later be
/// replaced by one speaking the Docker Engine API over `docker system
/// dial-stdio` — which would give real `/events` streaming instead of
/// poll-interval resolution — without the UI knowing.
/// The only operations that change anything on the NAS.
enum ContainerAction: String, Sendable, CaseIterable {
    case start, stop, restart

    var verb: String {
        switch self {
        case .start: "Start"
        case .stop: "Stop"
        case .restart: "Restart"
        }
    }

    var symbolName: String {
        switch self {
        case .start: "play.fill"
        case .stop: "stop.fill"
        case .restart: "arrow.clockwise"
        }
    }
}

protocol ContainerSource: Sendable {
    func fetch() async throws -> AgentListOutput
    func check() async throws -> AgentCheck
    /// The image each container was created from, keyed by container id.
    func images() async throws -> [String: ContainerImage]
    func perform(_ action: ContainerAction, on container: String) async throws
}
