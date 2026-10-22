import AppKit
import SwiftUI

/// First-run setup: what Ballast is, what has to be on in DSM, the account,
/// where to connect, a key and its authorisation, the agent, and a test that
/// ends by listing what it found.
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
        case welcome, prerequisites, account, access, key, authorise, agent, test
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                Group {
                    switch page {
                    case .welcome: WelcomePage()
                    case .prerequisites: PrerequisitesPage()
                    case .account: AccountPage()
                    case .access: AccessPage(settings: settings) { turn(to: .key) }
                    case .key:
                        CommandPage(
                            title: "Make a key",
                            command: BundledScripts.command(.keygen, destination: settings.sshDestination),
                            note: "Leave the passphrase empty when it asks."
                        )
                    case .authorise:
                        CommandPage(
                            title: "Authorise the key",
                            command: BundledScripts.command(.deployKey, destination: settings.sshDestination),
                            note: "Keep another SSH session open while it runs."
                        )
                    case .agent:
                        // The command carries the script's full path, so it
                        // does not matter where Terminal happens to be — which
                        // is the first thing anyone wonders when handed a
                        // script to run.
                        CommandPage(
                            title: "Install the agent",
                            command: BundledScripts.command(.installAgent, destination: settings.sshDestination),
                            note: "It works from any folder. DSM asks for your password once."
                        )
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
            // What it needs on the NAS is the next page, where it's something
            // to act on rather than a footnote to remember.
            MenuPreview()
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

/// The two switches in DSM that everything after this depends on. A page of
/// their own rather than a caption on the welcome: each is something to go and
/// do, so each gets a row that says where to find it.
private struct PrerequisitesPage: View {
    var body: some View {
        PageLayout(title: "Before you start", subtitle: "Two things need to be on in DSM.") {
            VStack(spacing: 8) {
                PrerequisiteRow(
                    symbol: "terminal.fill",
                    tint: .teal,
                    title: "SSH service",
                    location: "Control Panel → Terminal & SNMP → Enable SSH service"
                )
                .stagger(1)
                PrerequisiteRow(
                    symbol: "shippingbox.fill",
                    tint: .blue,
                    title: "Container Manager",
                    location: "Installed and running, from Package Center"
                )
                .stagger(2)
            }
            .frame(width: 380)
        }
    }
}

private struct PrerequisiteRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let location: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(tint.gradient, in: .rect(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(location)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.leading)

            Spacer(minLength: 8)

            // A checkmark, not a switch: a switch is a control, and one that
            // doesn't flip reads as broken. This only says what's needed.
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(.green)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.06))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) needs to be on. \(location)")
    }
}

/// Making the account is the one step that happens in DSM rather than in
/// Terminal, so it gets a recording instead of a command: there is no line to
/// paste, only a path through a wizard.
private struct AccountPage: View {
    var body: some View {
        PageLayout(
            title: "Create an administrator account",
            // A name chosen for them, so the next page can fill it in rather
            // than ask them to remember and retype it exactly.
            subtitle: "In DSM: Control Panel → User & Group → Create. Name it \(BundledScripts.placeholderUser)."
        ) {
            LoopingVideo(
                resource: "create-dsm-account",
                width: 420,
                aspectRatio: 940.0 / 604.0,
                title: "Creating the account in DSM"
            )
            .stagger(1)
        }
    }
}

private struct AccessPage: View {
    @Bindable var settings: AppSettings
    /// The fields take focus on this page, which swallows Return from the
    /// default button — so Return has to mean "continue" here too, or typing
    /// a destination and pressing it does nothing at all.
    let onSubmit: () -> Void

    /// Asked for as two halves rather than one `user@host`: a DSM username on
    /// its own is the natural thing to type, and it fails a page later as an
    /// unreachable host named after the account.
    @State private var username: String
    @State private var host: String
    @FocusState private var focus: Half?

    private enum Half { case username, host }

    init(settings: AppSettings, onSubmit: @escaping () -> Void) {
        self.settings = settings
        self.onSubmit = onSubmit
        let destination = settings.sshDestination.trimmingCharacters(in: .whitespaces)
        if destination.isEmpty {
            // The name the account page asked for, so only the address is
            // left to type.
            _username = State(initialValue: BundledScripts.placeholderUser)
            _host = State(initialValue: "")
        } else if let at = destination.lastIndex(of: "@") {
            _username = State(initialValue: String(destination[..<at]))
            _host = State(initialValue: String(destination[destination.index(after: at)...]))
        } else {
            // No account named: an ssh config alias, or a bare host.
            _username = State(initialValue: "")
            _host = State(initialValue: destination)
        }
    }

    var body: some View {
        // "Exact" because a DSM username is what it is, and a near miss fails
        // as an authentication error later, a page away from the cause.
        PageLayout(
            title: "Connect over SSH",
            subtitle: "Type your NAS's IP or name. The username is the account you just created."
        ) {
            HStack(spacing: 6) {
                HalfField(text: $username, prompt: BundledScripts.placeholderUser)
                    .focused($focus, equals: .username)
                    .onSubmit { focus = .host }
                Text(verbatim: "@")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                HalfField(text: $host, prompt: BundledScripts.placeholderHost)
                    .focused($focus, equals: .host)
                    .onSubmit(onSubmit)
            }
            .stagger(1)
        }
        // Straight to the half that's still empty, which on a first run is
        // the address: the username arrives filled in.
        .onAppear {
            if !trimmedUsername.isEmpty && trimmedHost.isEmpty { focus = .host }
        }
        .onChange(of: username) { save() }
        .onChange(of: host) { save() }
    }

    private var trimmedUsername: String { username.trimmingCharacters(in: .whitespaces) }
    private var trimmedHost: String { host.trimmingCharacters(in: .whitespaces) }

    /// Only a whole destination is saved. A username with no host yet is
    /// saved as nothing, rather than as a host named after the account.
    private func save() {
        settings.sshDestination = switch (trimmedUsername.isEmpty, trimmedHost.isEmpty) {
        case (false, false): "\(trimmedUsername)@\(trimmedHost)"
        case (true, _): trimmedHost
        case (false, true): ""
        }
    }
}

/// One command per page: a title for what it does, the one instruction every
/// command shares, and the caveat that matters underneath — where it's read
/// after the copy, not instead of it.
private struct CommandPage: View {
    let title: String
    let command: String
    let note: String

    var body: some View {
        PageLayout(title: title, subtitle: "Copy and paste this into Terminal.") {
            VStack(spacing: 7) {
                CommandBlock(command: command)
                Caption(note)
            }
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
    /// Once there's been one attempt, retrying is the refresh arrow rather
    /// than a second button with a different word on it.
    @State private var hasTested = false
    /// Kept so a retry mid-cascade stops the old one rather than racing it.
    @State private var revealTask: Task<Void, Never>?
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
        PageLayout(
            title: "Check it works",
            subtitle: "Ballast connects to your NAS and lists what's running."
        ) {
            HStack(spacing: 8) {
                TextField("", text: $settings.sshDestination, prompt: Text(BundledScripts.placeholderDestination))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .multilineTextAlignment(.center)
                    .frame(width: 180)
                    .onSubmit { Task { await runTest() } }

                if hasTested {
                    RefreshButton(help: "Test again") { await runTest() }
                        .disabled(!settings.isConfigured)
                } else if case .running = phase {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Test") { Task { await runTest() } }
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

        VStack(alignment: .leading, spacing: 6) {
            // The glyph sits in the status column and the count over the
            // names, so the heading reads as the top of the list it counts.
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .frame(width: 14)
                Text("\(containers.count) running")
                    .monospacedDigit()
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.green)
            .accessibilityElement(children: .combine)

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
                // Room for the scroller, so it doesn't crowd the ports.
                .padding(.trailing, 14)
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

    /// Returns whether it connected, which is what the refresh arrow turns
    /// into a checkmark.
    @discardableResult
    private func runTest() async -> Bool {
        revealTask?.cancel()
        phase = .running
        revealed = 0
        defer { hasTested = true }
        switch await store.testConnection() {
        case .failure(let error):
            withAnimation(.easeOut(duration: 0.2)) { phase = .failed(error) }
            return false
        case .success:
            // The list has to exist before it can be revealed.
            await store.refresh()
            // Getting this far is the whole point of the window, so don't
            // make pressing Done the thing that records setup as finished:
            // closing from here shouldn't bring it back.
            settings.hasCompletedOnboarding = true
            withAnimation(.easeOut(duration: 0.2)) { phase = .connected }
            // Not awaited: the checkmark belongs to the answer, not to the
            // end of the cascade.
            revealTask = Task { await reveal(store.activeContainers.count) }
            return true
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
            guard !Task.isCancelled else { return }
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
                BallastMark(size: 56)
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

/// One half of the destination, for the one thing that is typed rather than run.
private struct HalfField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        TextField("", text: $text, prompt: Text(prompt))
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12))
            .multilineTextAlignment(.center)
            .frame(width: 150)
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

/// How far through setup you are, one dot per page.
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
