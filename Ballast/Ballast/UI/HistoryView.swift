import SwiftUI

/// Everything that has gone down, newest first and grouped by day.
struct HistoryView: View {
    let store: ContainerStore

    private var days: [(day: Date, events: [DowntimeEvent])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: store.history) { calendar.startOfDay(for: $0.at) }
        return grouped
            .sorted { $0.key > $1.key }
            .map { ($0.key, $0.value.sorted { $0.at > $1.at }) }
    }

    var body: some View {
        if store.history.isEmpty {
            EmptyStateView(
                symbol: "clock.arrow.circlepath",
                title: "No history yet",
                message: "Exits, restarts and image updates Ballast sees while it's running will appear here."
            )
        } else {
            // Paired up here rather than stored, so an exit whose start went
            // unobserved just has no duration instead of a wrong one.
            let downtimes = DowntimeEvent.downtimes(in: store.history)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(days, id: \.day) { day in
                        SectionHeader(title: Self.title(for: day.day), count: day.events.count)
                        ForEach(day.events) { event in
                            HistoryRow(event: event, downtime: downtimes[event.id])
                        }
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 460)
            .scrollIndicators(.never)
        }
    }

    private static func title(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }
}

private struct HistoryRow: View {
    let event: DowntimeEvent
    let downtime: TimeInterval?

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
                // The same 14pt column the container list gives its status
                // glyph, so names stay on one line down the popover when you
                // switch between the two panes.
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(event.containerName)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            Text(event.at.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .help("\(event.containerName) — \(event.summary)\n\(event.at.formatted(date: .abbreviated, time: .standard))")
    }

    private var detail: String {
        guard let downtime else { return event.summary }
        return "\(event.summary) · down for \(DowntimeEvent.format(duration: downtime))"
    }

    /// Matches the list: red for a failure, orange for something that
    /// recovered on its own, green for coming back, grey for a clean stop,
    /// blue for a new image.
    private var tint: Color {
        switch event.kind {
        case .started: .green
        case .updated: .blue
        case .crashRestarted: .orange
        case .exited:
            // `isNotifiable` is exactly "a failure nobody asked for".
            event.isNotifiable ? .red : .secondary
        }
    }
}
