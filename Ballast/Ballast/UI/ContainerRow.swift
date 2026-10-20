import SwiftUI

/// One container: status, name, why it's in that state, and its port.
struct ContainerRow: View {
    let container: Container
    let assessment: StatusAssessment
    let endpoints: [ServiceEndpoint]
    var isBusy = false
    var lastExit: DowntimeEvent?
    var isMuted = false
    var perform: (ContainerAction) -> Void = { _ in }
    var onHide: () -> Void = {}
    var onToggleMute: () -> Void = {}

    @State private var isHovering = false
    @Environment(\.openURL) private var openURL

    private var primary: ServiceEndpoint? { endpoints.first }
    private var isOpenable: Bool { primary != nil }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                StatusIndicator(status: assessment.status)

                // The status is carried by the indicator; the full reason is
                // in the tooltip, so the row stays one line.
                Text(container.displayName)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .layoutPriority(1)

                // Revealed on hover, in the slack after the name, so no other
                // element moves when it appears.
                if isHovering, let version = container.version {
                    Text(version)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 6)

                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                        .frame(width: 34, alignment: .trailing)
                } else if isHovering {
                    // Lifecycle controls replace the port while hovering, so
                    // the row doesn't change width or reflow under the cursor.
                    HStack(spacing: 2) {
                        if container.state.isUp {
                            RowAction(action: .restart, container: container, perform: perform)
                            RowAction(action: .stop, container: container, perform: perform)
                        } else {
                            RowAction(action: .start, container: container, perform: perform)
                        }

                        if isOpenable {
                            RowIconButton(
                                symbol: "arrow.up.forward",
                                help: "Open \(primary?.url.absoluteString ?? "")",
                                action: open
                            )
                        }
                    }
                } else if let port = primary?.hostPort {
                    // verbatim: a port is an identifier, so it must not be
                    // localised into "32,400".
                    Text(verbatim: String(port))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    // Says "there is no URL for this one" rather than leaving
                    // a blank that reads as missing data.
                    Text(verbatim: "N/A")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(height: 20)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovering && isOpenable ? Color.primary.opacity(0.08) : .clear)
                    // Only the highlight fades. The controls it reveals stay
                    // instant, so the row never feels like it trails the
                    // cursor — and scrubbing down the list doesn't strobe.
                    .animation(.easeInOut(duration: 0.12), value: isHovering)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(helpText)
        .contextMenu { contextMenu }
    }

    private var helpText: String {
        var lines = ["\(container.displayName) — \(assessment.reason)", container.image]
        if let version = container.version { lines.append("Version \(version)") }
        if let url = primary?.url { lines.append(url.absoluteString) }
        if container.restartCount > 0 { lines.append("\(container.restartCount) restarts") }
        if let lastExit { lines.append("Last exit: \(lastExit.summary), \(lastExit.relativeTime())") }
        return lines.joined(separator: "\n")
    }

    @ViewBuilder
    private var contextMenu: some View {
        if let primary {
            Button("Open \(primary.url.absoluteString)") { openURL(primary.url) }
            Button("Copy URL") { copy(primary.url.absoluteString) }
        }
        // Containers that publish several ports often have a second UI worth
        // reaching, so don't hide the rest behind the primary guess.
        if endpoints.count > 1 {
            Divider()
            ForEach(endpoints.dropFirst()) { endpoint in
                Button("Open port \(endpoint.hostPort.map(String.init) ?? "—")") { openURL(endpoint.url) }
            }
        }
        Divider()
        if container.state.isUp {
            Button("Restart") { perform(.restart) }
            Button("Stop") { perform(.stop) }
        } else {
            Button("Start") { perform(.start) }
        }
        Divider()
        Button("Hide from menu") { onHide() }
        Button(isMuted ? "Unmute exit notifications" : "Mute exit notifications") { onToggleMute() }
        Divider()
        Button("Copy container name") { copy(container.name) }
        Button("Copy image") { copy(container.image) }
    }

    private func open() {
        guard let primary else { return }
        openURL(primary.url)
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}


/// One small round control in a row. Only visible on hover, so none of them
/// can be hit by accident while scrolling the list.
private struct RowIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .medium))
                .frame(width: 18, height: 18)
                .contentShape(.circle)
        }
        .buttonStyle(.pressable)
        .foregroundStyle(isHovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .glassEffect(.regular.interactive(), in: .circle)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

private struct RowAction: View {
    let action: ContainerAction
    let container: Container
    let perform: (ContainerAction) -> Void

    var body: some View {
        RowIconButton(
            symbol: action.symbolName,
            help: "\(action.verb) \(container.displayName)"
        ) {
            perform(action)
        }
    }
}
