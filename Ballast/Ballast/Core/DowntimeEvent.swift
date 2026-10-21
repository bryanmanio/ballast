import Foundation

/// Something that happened to a container between two polls.
///
/// These are discrete events rather than open/closed outage intervals, because
/// polling has gaps: the Mac sleeps, the NAS is unreachable. An interval would
/// need an end we may never observe, whereas an exit and a later start can each
/// be recorded on their own and paired up afterwards.
struct DowntimeEvent: Codable, Sendable, Identifiable, Hashable {
    enum Kind: String, Codable, Sendable {
        case exited
        /// Still up, but the restart count rose: Docker's restart policy
        /// brought it back between two polls.
        case crashRestarted
        case started
        /// Recreated onto a different image under the same name — what
        /// Watchtower, or `docker compose pull` and `up`, leaves behind.
        case updated
    }

    var id: UUID
    /// The name, not the container id — an id changes every time a container
    /// is recreated, which would orphan its history.
    var containerName: String
    var kind: Kind
    /// When it happened according to Docker, not when we noticed.
    var at: Date
    var exitCode: Int?
    var oomKilled: Bool
    var image: String?
    /// The user asked for this stop from Ballast. `docker stop` ends in a
    /// SIGKILL (exit 137) if the container is slow to quit, which would
    /// otherwise look exactly like a crash.
    var userInitiated: Bool
    /// How many restarts this entry stands for. A crash loop is collapsed
    /// into one counted entry rather than an entry per poll. Optional so a
    /// log written before the field existed still decodes.
    var occurrences: Int?
    /// For `.updated`: the image version before and after, where the image
    /// labels one. Optional so older logs still decode.
    var fromVersion: String?
    var toVersion: String?

    init(
        id: UUID = UUID(),
        containerName: String,
        kind: Kind,
        at: Date,
        exitCode: Int? = nil,
        oomKilled: Bool = false,
        image: String? = nil,
        userInitiated: Bool = false,
        occurrences: Int? = nil,
        fromVersion: String? = nil,
        toVersion: String? = nil
    ) {
        self.id = id
        self.containerName = containerName
        self.kind = kind
        self.at = at
        self.exitCode = exitCode
        self.oomKilled = oomKilled
        self.image = image
        self.userInitiated = userInitiated
        self.occurrences = occurrences
        self.fromVersion = fromVersion
        self.toVersion = toVersion
    }

    /// Whether this is the container going down, rather than coming back or
    /// being updated.
    var isExit: Bool { kind == .exited || kind == .crashRestarted }

    var occurrenceCount: Int { max(1, occurrences ?? 1) }

    /// Worth interrupting someone for. A clean exit is recorded but never
    /// notified, and neither is a crash that Docker already recovered from.
    var isNotifiable: Bool {
        kind == .exited && !userInitiated && (oomKilled || (exitCode ?? 0) != 0)
    }

    var summary: String {
        switch kind {
        case .started:
            return "Started"
        case .exited:
            if userInitiated { return "Stopped" }
            return StatusResolver.exitReason(exitCode: exitCode ?? 0, oomKilled: oomKilled)
        case .updated:
            let from = fromVersion.map(ImageUpdateResolver.appVersion)
            let to = toVersion.map(ImageUpdateResolver.appVersion)
            switch (from, to) {
            case let (from?, to?) where from != to: return "Updated \(from) → \(to)"
            // Same release, new build: a LinuxServer rebuild.
            case let (_?, to?): return "Updated to a new build of \(to)"
            case let (nil, to?): return "Updated to \(to)"
            case (_, nil): return "Updated to a new image"
            }
        case .crashRestarted:
            let reason = oomKilled || (exitCode ?? 0) != 0
                ? StatusResolver.exitReason(exitCode: exitCode ?? 0, oomKilled: oomKilled) + ", then restarted"
                : "Crashed and restarted"
            return occurrenceCount > 1 ? "\(reason) · \(occurrenceCount)×" : reason
        }
    }

    /// "6 hours ago", relative to `now`.
    func relativeTime(relativeTo now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: at, relativeTo: now)
    }

    /// How recent an exit has to be for the notification to read as "just now".
    static let freshWindow: TimeInterval = 120

    /// Worded from when the exit actually happened. After the Mac has slept
    /// we may find out hours late, and "Exited with code 137" alone would
    /// read as though it had just happened.
    func notificationBody(now: Date = Date()) -> String {
        now.timeIntervalSince(at) > Self.freshWindow
            ? "\(summary), \(relativeTime(relativeTo: now))"
            : summary
    }
}

extension DowntimeEvent {
    /// For each exit that was followed by a start of the same container, how
    /// long it was down. An exit with no later start (still down, or the start
    /// went unobserved) has no entry.
    static func downtimes(in events: [DowntimeEvent]) -> [UUID: TimeInterval] {
        var result: [UUID: TimeInterval] = [:]
        // Updates are left out: the new container's start is what ends an exit.
        for (_, own) in Dictionary(grouping: events.filter { $0.kind != .updated }, by: \.containerName) {
            let ordered = own.sorted { $0.at < $1.at }
            for (event, next) in zip(ordered, ordered.dropFirst())
            where event.kind == .exited && next.kind == .started {
                result[event.id] = max(0, next.at.timeIntervalSince(event.at))
            }
        }
        return result
    }

    /// "4m", "1h 5m", "2d 3h".
    static func format(duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.maximumUnitCount = 2
        return formatter.string(from: duration) ?? ""
    }
}
