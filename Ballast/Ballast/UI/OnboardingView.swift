import AppKit
import SwiftUI

/// First-run setup, as four pages: what Ballast is, SSH access, the agent, and
/// a test that ends by listing what it found.
///
/// The window exists because the commands do. Setup is three lines of shell,
/// and a line of shell that wraps twice in a 340pt popover is a line nobody
/// pastes correctly. Every command is built from the destination typed on page
/// two, so none of them have to be edited after copying.
///
/// One instruction per page, centred, with the command directly under it.
/// Anything that isn't needed to get to the next page was cut rather than
/// shrunk: a setup screen is read once, in a hurry.
struct OnboardingView: View {
    @Bindable var settings: AppSettings
    let store: ContainerStore

    @State private var page: Page = .welcome
    @Environment(\.dismiss) private var dismiss

    /// Tall enough for the longest page, and fixed: the window is sized to its
    /// content, so letting each page set its own height would resize the
    /// window on every turn.
    private static let contentHeight: CGFloat = 380
    /// Wide enough that the longest one-line command — `ssh-keygen …` —
    /// doesn't have to wrap, and no wider.
    static let width: CGFloat = 520

    enum Page: Int, CaseIterable {
        case welcome, account, access, agent, test
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                Group {
                    switch page {
                    case .welcome: WelcomePage()
                    case .account: AccountPage()
                    case .access: AccessPage(settings: settings) { turn(to: .agent) }
                    case .agent: AgentPage(destination: settings.sshDestination)
                    case .test: TestPage(settings: settings, store: store)
                    }
                }
                // Entering is the staggered appearance of the page's own
                // parts, so the container itself only has to leave: a short
                // lift, softer than the thing arriving behind it.
                .transition(
                    .asymmetric(
                        insertion: .identity,
                        removal: .opacity.combined(with: .offset(y: -8))
                    )
                )
            }
            .frame(width: Self.width, height: Self.contentHeight)
            .clipped()

            Divider()
            footer
        }
        .frame(width: Self.width)
        // Closing the window counts as having been offered setup, so it isn't
        // offered again at every launch. The menu's empty state is the way
        // back, which means no "skip" control has to earn its place here.
        .onDisappear { settings.hasCompletedOnboarding = true }
    }

    // MARK: Footer

    private var footer: some View {
        ZStack {
            PageDots(count: Page.allCases.count, current: page.rawValue)

            HStack(spacing: 10) {
                // Hidden rather than disabled: a dead control on the first
                // page is just something to wonder about.
                if page != .welcome {
                    Button("Back") { turn(to: Page(rawValue: page.rawValue - 1) ?? .welcome) }
                }

                Spacer(minLength: 0)

                Button(page == .test ? "Done" : "Continue") {
                    page == .test ? finish() : turn(to: Page(rawValue: page.rawValue + 1) ?? .test)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func turn(to next: Page) {
        withAnimation(.easeIn(duration: 0.15)) { page = next }
    }

    private func finish() {
        settings.hasCompletedOnboarding = true
        dismiss()
    }
}

// MARK: - Pages

private struct WelcomePage: View {
    var body: some View {
        // The preview shows what it looks like; the subtitle says what you
        // can do with it, which a still can't.
        PageLayout(
            mark: true,
            title: "Welcome to Ballast",
            subtitle: "The fastest way to view, stop, or restart the containers on your NAS."
        ) {
            MenuPreview()

            // The administrator account it needs is explained on the next
            // page, where it's something to act on rather than remember.
            Caption("You'll need SSH turned on and Container Manager running on the NAS.")
                .stagger(6)
        }
    }
}

/// A still of what the menu looks like once this is all done — four services,
/// up, with the ports they answer on.
///
/// The rows arrive one after another, which is both the first glimpse of the
/// product and a quiet rehearsal of the reveal on the last page.
private struct MenuPreview: View {
    private static let samples: [(name: String, port: Int, status: ServiceStatus)] = [
        ("jellyfin", 8096, .healthy),
        ("immich-server", 2283, .healthy),
        ("uptime-kuma", 3001, .healthy),
        ("vaultwarden", 8222, .healthy),
    ]

    var body: some View {
        VStack(spacing: 2) {
            ForEach(Array(Self.samples.enumerated()), id: \.element.name) { index, sample in
                HStack(spacing: 8) {
                    StatusIndicator(status: sample.status)
                    Text(sample.name)
                        .font(.system(size: 12))
                    Spacer(minLength: 10)
                    // verbatim: a port is an identifier, not a number to localise.
                    Text(verbatim: String(sample.port))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .frame(height: 20)
                .stagger(2 + index)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: 240)
        .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.06))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of the menu, showing four services running")
    }
}

/// Making the account is the one step that happens in DSM rather than in
/// Terminal, so it gets a recording instead of a command: there is no line to
/// paste, only a path through a wizard.
private struct AccountPage: View {
    var body: some View {
        PageLayout(title: "Create an administrator account") {
            VStack(spacing: 7) {
                StepLabel("In DSM: Control Panel → User & Group → Create")
                LoopingVideo(
                    resource: "create-dsm-account",
                    width: 420,
                    aspectRatio: 940.0 / 604.0,
                    title: "Creating the account in DSM"
                )
            }
            .stagger(1)
        }
    }
}

private struct AccessPage: View {
    @Bindable var settings: AppSettings
    /// The field takes focus on this page, which swallows Return from the
    /// default button — so Return has to mean "continue" here too, or typing
    /// a destination and pressing it does nothing at all.
    let onSubmit: () -> Void

    var body: some View {
        PageLayout(title: "Connect over SSH") {
            Field(
                // Not "sign in": nothing signs in here. The field records
                // where to connect, and both halves of that — which account,
                // and which machine — have to be spelled out or the format
                // is a guess. "Exact" because a DSM username is what it is,
                // and a near miss fails as an authentication error later,
                // a page away from the cause.
                label: "The exact username you made in DSM, at your NAS's IP or name",
                text: $settings.sshDestination,
                onSubmit: onSubmit
            )
            .stagger(1)

            Step(
                label: "Make a key — leave the passphrase empty",
                command: BundledScripts.command(.keygen, destination: settings.sshDestination)
            )
            .stagger(2)

            Step(
                label: "Authorise it — keep another SSH session open",
                command: BundledScripts.command(.deployKey, destination: settings.sshDestination)
            )
            .stagger(3)
        }
    }
}

private struct AgentPage: View {
    let destination: String

    var body: some View {
        PageLayout(title: "Install the agent") {
            Step(
                // The command carries the script's full path, so it does not
                // matter where Terminal happens to be — which is the first
                // thing anyone wonders when handed a script to run.
                label: "Paste into Terminal from any folder — DSM asks for your password once",
                command: BundledScripts.command(.installAgent, destination: destination)
            )
            .stagger(1)
        }
    }
}

// MARK: - Test page

private struct TestPage: View {
    @Bindable var settings: AppSettings
    let store: ContainerStore

    @State private var phase: Phase = .idle
    /// How many of the containers found have been let onto the screen so far.
    @State private var revealed = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Phase {
        case idle, running
        case failed(BallastError)
        case connected
    }

    private static let rowHeight: CGFloat = 23
    /// Six rows, which is what the page has room for under the heading.
    private static let maxListHeight: CGFloat = rowHeight * 6

    var body: some View {
        PageLayout(title: "Check it works") {
            HStack(spacing: 8) {
                TextField("", text: $settings.sshDestination, prompt: Text(BundledScripts.placeholderDestination))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .multilineTextAlignment(.center)
                    .frame(width: 180)
                    .onSubmit { runTest() }

                if case .running = phase {
                    ProgressView().controlSize(.small)
                } else {
                    Button(isFirstAttempt ? "Test" : "Again") { runTest() }
                        .disabled(!settings.isConfigured)
                }
            }
            .stagger(1)

            switch phase {
            case .idle, .running:
                EmptyView()
            case .failed(let error):
                VStack(spacing: 2) {
                    Label(error.title, systemImage: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.red)
                    Caption(error.hint)
                }
                .transition(.opacity)
            case .connected:
                found
            }
        }
    }

    @ViewBuilder
    private var found: some View {
        let containers = store.activeContainers

        VStack(spacing: 6) {
            Label("\(containers.count) running", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.green)
                .monospacedDigit()

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(containers.prefix(revealed))) { container in
                        FoundRow(
                            name: container.displayName,
                            status: store.assessment(for: container).status,
                            port: store.primaryEndpoint(for: container)?.hostPort
                        )
                        .transition(.opacity.combined(with: .offset(y: 8)))
                    }
                }
                .frame(width: 300)
            }
            // Shown, not hidden: a list that stops mid-row with no scroller
            // reads as broken rather than as scrollable.
            .scrollIndicators(.automatic)
            // Whole rows only, and never taller than the page: a row sliced
            // by the window edge looks like a rendering fault, not a list
            // that scrolls.
            .frame(height: min(CGFloat(containers.count) * Self.rowHeight, Self.maxListHeight))
        }
    }

    private var isFirstAttempt: Bool {
        if case .idle = phase { return true }
        return false
    }

    private func runTest() {
        phase = .running
        revealed = 0
        Task {
            switch await store.testConnection() {
            case .failure(let error):
                withAnimation(.easeOut(duration: 0.2)) { phase = .failed(error) }
            case .success:
                // The list has to exist before it can be revealed.
                await store.refresh()
                // Getting this far is the whole point of the window, so don't
                // make pressing Done the thing that records setup as finished:
                // closing from here shouldn't bring it back.
                settings.hasCompletedOnboarding = true
                withAnimation(.easeOut(duration: 0.2)) { phase = .connected }
                await reveal(store.activeContainers.count)
            }
        }
    }

    /// Lets each container in on its own, which is the one moment in setup
    /// worth a flourish: it's the first time the thing being set up is visible.
    private func reveal(_ count: Int) async {
        guard count > 0 else { return }

        guard !reduceMotion else {
            withAnimation(.easeOut(duration: 0.2)) { revealed = count }
            return
        }

        for index in 0..<count {
            withAnimation(.spring(duration: 0.3, bounce: 0)) { revealed = index + 1 }
            // Short enough to read as one cascade rather than a queue.
            try? await Task.sleep(for: .milliseconds(70))
        }
    }
}

private struct FoundRow: View {
    let name: String
    let status: ServiceStatus
    let port: Int?

    var body: some View {
        HStack(spacing: 8) {
            StatusIndicator(status: status)
            Text(name)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 6)
            if let port {
                // verbatim: a port is an identifier, not a number to localise.
                Text(verbatim: String(port))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 22)
    }
}

// MARK: - Building blocks

/// The frame every page shares: an optional glyph, a title, one line of why,
/// then the page's own content — all centred on one column.
private struct PageLayout<Content: View>: View {
    var mark = false
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    init(mark: Bool = false, title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.mark = mark
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        // Generous: each step is a heading and a command, and the two blocks
        // need to read as separate instructions rather than one wall.
        VStack(spacing: 18) {
            if mark {
                BallastMark()
                    .padding(.bottom, 2)
                    .stagger(0)
            }

            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .stagger(mark ? 1 : 0)

            content
        }
        .multilineTextAlignment(.center)
        // Centred rather than pinned to the top: the pages differ in length,
        // and a short one hanging under a tall band of nothing reads as a
        // page that failed to load.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
        .padding(.vertical, 20)
    }
}

/// One instruction and the command that carries it out. The instruction is
/// the only prose on the page, so it carries whatever caveat matters.
private struct Step: View {
    let label: String
    let command: String

    var body: some View {
        VStack(spacing: 7) {
            StepLabel(label)
            CommandBlock(command: command)
        }
    }
}

/// The same shape as a step, for the one thing that is typed rather than run.
private struct Field: View {
    let label: String
    @Binding var text: String
    var onSubmit: () -> Void = {}

    var body: some View {
        VStack(spacing: 7) {
            StepLabel(label)
            TextField("", text: $text, prompt: Text(BundledScripts.placeholderDestination))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .frame(width: 240)
                .onSubmit(onSubmit)
        }
    }
}

private struct StepLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A command, and a click anywhere on it to copy. The text can be truncated;
/// what gets copied never is.
private struct CommandBlock: View {
    let command: String

    @State private var copied = false
    @State private var isHovering = false

    var body: some View {
        Button(action: copy) {
            HStack(spacing: 8) {
                Text(command)
                    .font(.system(size: 11, design: .monospaced))
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                CopyIcon(copied: copied)
                    .foregroundStyle(copied ? AnyShapeStyle(.green) : AnyShapeStyle(isHovering ? .primary : .secondary))
            }
            .padding(.horizontal, 10)
            // The whole block is the target rather than the glyph alone, so
            // the thing you have to hit is 400×40 instead of 22×22.
            .frame(minHeight: 40)
            .frame(maxWidth: .infinity)
            .background(Color.primary.opacity(isHovering ? 0.09 : 0.06), in: .rect(cornerRadius: 8))
            .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.pressable)
        // Kept out of the key loop: focused, it would answer the Return the
        // user meant for Continue, and copy the command instead of moving on.
        .focusable(false)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .help(copied ? "Copied" : "Click to copy")
        .accessibilityLabel("Copy command: \(command)")
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)

        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

/// Both glyphs stay in place and cross-fade, so the swap animates in each
/// direction rather than only on the way in.
private struct CopyIcon: View {
    let copied: Bool

    var body: some View {
        ZStack {
            glyph("checkmark", visible: copied)
            glyph("doc.on.doc", visible: !copied)
        }
        .frame(width: 14, height: 14)
    }

    private func glyph(_ name: String, visible: Bool) -> some View {
        Image(systemName: name)
            .font(.system(size: 10, weight: .medium))
            .scaleEffect(visible ? 1 : 0.25)
            .opacity(visible ? 1 : 0)
            .blur(radius: visible ? 0 : 4)
            .animation(.spring(duration: 0.3, bounce: 0), value: visible)
    }
}

private struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// How far through setup you are, in four dots.
private struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(index == current ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.primary.opacity(0.2)))
                    .frame(width: 5, height: 5)
            }
        }
        .animation(.easeOut(duration: 0.2), value: current)
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}

// MARK: - Entrance

private extension View {
    /// Each part of a page arrives on its own, a beat after the one above it.
    /// A page that animates as a single block reads as a slide; one that
    /// arrives in pieces reads as being laid out for you.
    func stagger(_ index: Int) -> some View {
        modifier(StaggeredAppear(index: index))
    }
}

private struct StaggeredAppear: ViewModifier {
    let index: Int

    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .blur(radius: shown ? 0 : 4)
            .offset(y: shown ? 0 : 8)
            .onAppear {
                guard !reduceMotion else {
                    shown = true
                    return
                }
                withAnimation(.easeOut(duration: 0.34).delay(Double(index) * 0.06)) {
                    shown = true
                }
            }
    }
}
