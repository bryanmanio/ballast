import AVFoundation
import AVKit
import SwiftUI

/// A short screen recording that loops silently with no transport controls —
/// a moving diagram rather than a video to watch.
///
/// Click to pause, because a loop that can't be stopped is a loop you fight
/// when you're trying to follow it. It also starts paused under Reduce
/// Motion, where something moving on its own is the whole problem.
///
/// The button in the corner pops it out into a floating window at twice the
/// size, with real transport controls — which is what you want when you are
/// following the steps in DSM rather than glancing at the loop.
struct LoopingVideo: View {
    let resource: String
    let width: CGFloat
    /// The recording's own aspect ratio, so no letterboxing ever shows.
    var aspectRatio: CGFloat
    /// Titles the floating window.
    var title: String

    @State private var video = VideoModel()
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var height: CGFloat { (width / aspectRatio).rounded() }

    var body: some View {
        ZStack {
            if video.isDetached {
                detachedPlaceholder
            } else {
                PlayerHost(surface: video.surface)

                // Only when stopped: a control sitting over a playing loop is
                // one more moving thing to ignore.
                if !video.isPlaying {
                    Image(systemName: "play.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(.black.opacity(0.55), in: .circle)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
        }
        .frame(width: width, height: height)
        .background(Color.primary.opacity(0.06))
        .clipShape(.rect(cornerRadius: 10))
        // Pure black or pure white at 10%, never a tinted neutral — a tinted
        // edge picks up the surface behind it and reads as dirt.
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.1))
        }
        .contentShape(.rect(cornerRadius: 10))
        .onTapGesture { if !video.isDetached { video.toggle() } }
        .help(video.isDetached ? "" : (video.isPlaying ? "Pause" : "Play"))
        // Collapsed into one element before the button goes on top, so the
        // button stays its own control rather than being absorbed into the
        // recording's label.
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
        .overlay(alignment: .topTrailing) { pipButton }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: video.isPlaying)
        .animation(.easeOut(duration: 0.15), value: video.isDetached)
        .onAppear {
            video.prepare(resource: resource, autoplay: !reduceMotion)
        }
        .onDisappear {
            // The floating window belongs to this page; it shouldn't outlive it.
            video.reattach()
            video.pause()
        }
    }

    private var pipButton: some View {
        Button {
            if video.isDetached {
                video.reattach()
            } else {
                video.detach(title: title, size: CGSize(width: width * 2, height: height * 2))
            }
        } label: {
            Image(systemName: video.isDetached ? "pip.exit" : "pip.enter")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(.black.opacity(isHovering ? 0.6 : 0.4), in: .circle)
                // Visible target is 26pt; the hittable one is 40.
                .frame(width: 40, height: 40)
                .contentShape(.circle)
        }
        .buttonStyle(.pressable)
        .opacity(isHovering || video.isDetached ? 1 : 0.65)
        .help(video.isDetached ? "Put it back" : "Open at twice the size")
        .accessibilityLabel(video.isDetached ? "Close the floating window" : "Open in a floating window")
    }

    private var detachedPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "pip")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
            Text("Playing in its own window")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

/// Owns the player, its loop, and the window it can be popped out into.
@MainActor
@Observable
final class VideoModel {
    /// The view currently showing the recording in the page, if it's there.
    private(set) var surface: AVPlayerView?
    private(set) var isPlaying = false
    /// True while the recording is showing in its own window instead of inline.
    private(set) var isDetached = false

    private var resource: String?
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var panel: NSPanel?
    private var closeObserver: (any NSObjectProtocol)?

    func prepare(resource: String, autoplay: Bool) {
        guard self.resource == nil else { return }
        self.resource = resource
        show(in: makeSurface(controls: .none), playing: autoplay)
    }

    func toggle() {
        guard let player else { return }
        isPlaying ? player.pause() : player.play()
        isPlaying.toggle()
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    /// Moves the recording into a floating window at twice the size, with the
    /// controls a video window is expected to have.
    func detach(title: String, size: CGSize) {
        guard panel == nil else { return }

        let view = makeSurface(controls: .floating)
        view.videoGravity = .resizeAspect

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.contentView = view
        panel.isFloatingPanel = true
        // Above the setup window, and above the browser you're following it
        // in — the point of popping it out is to watch it while doing the
        // thing it shows.
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Resizable, but never into a shape the recording doesn't fit.
        panel.contentAspectRatio = size
        panel.contentMinSize = CGSize(width: size.width / 2, height: size.height / 2)
        panel.center()

        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reattach() }
        }

        self.panel = panel
        isDetached = true
        show(in: view, playing: true)
        panel.orderFront(nil)
    }

    /// Puts the recording back in the page and closes the window.
    func reattach() {
        guard let panel else { return }

        if let observer = closeObserver {
            NotificationCenter.default.removeObserver(observer)
            closeObserver = nil
        }
        panel.contentView = NSView()
        self.panel = nil
        panel.close()

        isDetached = false
        show(in: makeSurface(controls: .none), playing: true)
    }

    /// A fresh player and a fresh view for every move between the page and
    /// the window.
    ///
    /// Reusing either one doesn't survive the trip: handing a player to a
    /// second view leaves that view black, because a player's video output
    /// belongs to one layer and passing it back doesn't rebuild it — and
    /// reusing the view strands the floating transport controls on top of the
    /// recording, since an `AVPlayerView` with no window won't lay out a
    /// change of controls style. Rebuilding costs nothing: the file is local
    /// and under a megabyte.
    private func makeSurface(controls: AVPlayerViewControlsStyle) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = controls
        view.videoGravity = .resizeAspectFill
        return view
    }

    private func show(in view: AVPlayerView, playing: Bool) {
        teardown()

        guard let resource,
              let url = Bundle.main.url(forResource: resource, withExtension: "mp4")
        else { return }

        let item = AVPlayerItem(url: url)
        let queue = AVQueuePlayer(items: [item])
        // Nothing to hear, so it can't interrupt whatever is playing.
        queue.isMuted = true

        looper = AVPlayerLooper(player: queue, templateItem: item)
        player = queue
        view.player = queue
        // Only the page keeps a reference; the window holds its own view.
        surface = isDetached ? nil : view

        guard playing else { return }
        queue.play()
        isPlaying = true
    }

    private func teardown() {
        player?.pause()
        looper?.disableLooping()
        looper = nil
        surface?.player = nil
        surface = nil
        player = nil
        isPlaying = false
    }
}

/// Holds whichever `AVPlayerView` the model owns. (`VideoPlayer` can't hide
/// its controls on macOS; `AVPlayerView` can.)
private struct PlayerHost: NSViewRepresentable {
    let surface: AVPlayerView?

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ container: NSView, context: Context) {
        guard let surface else {
            container.subviews.forEach { $0.removeFromSuperview() }
            return
        }
        guard surface.superview !== container else { return }

        // The previous one, if this is a view that just came back from the
        // floating window.
        container.subviews.forEach { $0.removeFromSuperview() }
        surface.removeFromSuperview()
        surface.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            surface.topAnchor.constraint(equalTo: container.topAnchor),
            surface.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}
