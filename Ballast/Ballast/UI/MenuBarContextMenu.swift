import AppKit

/// Right-click on the menu bar icon.
///
/// SwiftUI's `.contextMenu` is ignored on a `MenuBarExtra` label in window
/// style — a right-click just toggles the popover, which is why the Quit item
/// that modifier declared never appeared. So the event is intercepted before
/// it reaches the status item and answered with a real menu.
///
/// A local monitor only ever sees events delivered to this app, so a
/// right-click on somebody else's status item is none of our business and is
/// passed straight through.
@MainActor
final class MenuBarContextMenu: NSObject {
    /// Set by the menu bar label once SwiftUI can hand us a way to open a
    /// window; AppKit has no route to a Scene on its own.
    var openSettings: () -> Void = {}

    private var monitor: Any?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] event in
            guard let self, Self.isStatusBar(event.window) else { return event }
            self.present()
            // Swallowed: left unconsumed, the popover opens behind the menu.
            return nil
        }
    }

    /// The status item lives in a window of AppKit's own making. Matching on
    /// the class name keeps this to a read of public metadata — and a miss
    /// only means the event passes through untouched, which is what would
    /// have happened anyway.
    private static func isStatusBar(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return String(describing: type(of: window)).contains("StatusBar")
    }

    private func present() {
        let menu = NSMenu()

        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Ballast", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        // `in: nil` places the menu in screen coordinates, which is where the
        // pointer already is — no view to position against up here.
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func showSettings() {
        // An agent app isn't frontmost when its menu bar icon is clicked, so
        // the window would open behind whatever the user was looking at.
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
