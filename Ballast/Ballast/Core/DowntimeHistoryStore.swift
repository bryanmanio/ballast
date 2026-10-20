import Foundation

protocol DowntimeHistoryStoring: Sendable {
    /// Oldest first, with retention already applied.
    func load() -> [DowntimeEvent]
    func append(_ events: [DowntimeEvent])
    func clear()
}

enum DowntimeRetention {
    static let maxEvents = 200
    static let maxAge: TimeInterval = 30 * 24 * 3_600
    /// How close two crash-restarts have to be to count as the same episode.
    static let coalesceWindow: TimeInterval = 3_600

    /// Drops anything past the age limit, collapses crash loops, then keeps
    /// only the newest `maxEvents`. Returned oldest first.
    static func trim(
        _ events: [DowntimeEvent],
        now: Date,
        maxEvents: Int = maxEvents,
        maxAge: TimeInterval = maxAge
    ) -> [DowntimeEvent] {
        let cutoff = now.addingTimeInterval(-maxAge)
        let recent = events.filter { $0.at >= cutoff }.sorted { $0.at < $1.at }
        return Array(coalesce(recent).suffix(maxEvents))
    }

    /// Collapses a run of crash-restarts of one container into a single
    /// counted entry.
    ///
    /// A container stuck in a restart loop produces one of these on every
    /// poll — hundreds a night — which would push every other container's
    /// history out of the log entirely. Restarts an hour or more apart stay
    /// separate, so an occasional crash is still its own line.
    ///
    /// Takes events oldest first and returns them the same way.
    static func coalesce(_ events: [DowntimeEvent]) -> [DowntimeEvent] {
        var result: [DowntimeEvent] = []
        for event in events {
            guard event.kind == .crashRestarted,
                  let last = result.lastIndex(where: { $0.containerName == event.containerName }),
                  result[last].kind == .crashRestarted,
                  event.at.timeIntervalSince(result[last].at) <= coalesceWindow
            else {
                result.append(event)
                continue
            }

            // The episode keeps its own identity but takes on the latest
            // restart's time and reason, so the row reads as "still going".
            var merged = result[last]
            merged.at = event.at
            merged.exitCode = event.exitCode
            merged.oomKilled = event.oomKilled
            merged.occurrences = merged.occurrenceCount + event.occurrenceCount
            // Moved to the end rather than updated in place: its time is now
            // the newest in the run, and the result stays oldest first.
            result.remove(at: last)
            result.append(merged)
        }
        return result
    }
}

/// An append-only log in a JSON file, rather than UserDefaults, which in this
/// app holds settings. A few hundred small records is more than a preference.
struct FileDowntimeHistoryStore: DowntimeHistoryStoring {
    let url: URL
    var now: @Sendable () -> Date = { Date() }

    /// Fixture mode gets its own file, like its own defaults suite, so
    /// developing against sample data can't touch the real log.
    static func defaultURL(fixtures: Bool) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appending(path: fixtures ? "Ballast/fixtures" : "Ballast", directoryHint: .isDirectory)
            .appending(path: "history.json")
    }

    func load() -> [DowntimeEvent] {
        // A missing or unreadable log is an empty history, never a crash:
        // this is a convenience record, not something worth refusing to launch over.
        guard let data = try? Data(contentsOf: url),
              let events = try? Self.decoder.decode([DowntimeEvent].self, from: data)
        else { return [] }
        return DowntimeRetention.trim(events, now: now())
    }

    func append(_ events: [DowntimeEvent]) {
        write(DowntimeRetention.trim(load() + events, now: now()))
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
    }

    private func write(_ events: [DowntimeEvent]) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Self.encoder.encode(events).write(to: url, options: .atomic)
        } catch {
            // Losing a history entry is better than interrupting polling.
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Keeps history for the life of the process only. The default for anything
/// that isn't the real app, so tests and previews never write to disk.
final class InMemoryDowntimeHistoryStore: DowntimeHistoryStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [DowntimeEvent]
    private let now: @Sendable () -> Date

    init(events: [DowntimeEvent] = [], now: @escaping @Sendable () -> Date = { Date() }) {
        self.events = events
        self.now = now
    }

    func load() -> [DowntimeEvent] {
        lock.withLock { DowntimeRetention.trim(events, now: now()) }
    }

    func append(_ new: [DowntimeEvent]) {
        lock.withLock { events = DowntimeRetention.trim(events + new, now: now()) }
    }

    func clear() {
        lock.withLock { events = [] }
    }
}
