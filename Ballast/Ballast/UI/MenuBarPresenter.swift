import AppKit

/// Opens and closes the menu from code, for the global shortcut.
///
/// `MenuBarExtra` keeps its status item to itself — there's no binding for
/// "is the menu showing" in window style — so the way in is the button the
/// system put in the menu bar, found by walking this app's own windows. A
/// miss simply does nothing, which is also what a dead shortcut would do.
@MainActor
enum MenuBarPresenter {
    static func toggle() {
        statusItemButton()?.performClick(nil)
    }

    private static func statusItemButton() -> NSStatusBarButton? {
        for window in NSApp.windows {
            if let contentView = window.contentView,
               let button = statusBarButton(in: contentView) {
                return button
            }
        }
        return nil
    }

    private static func statusBarButton(in view: NSView) -> NSStatusBarButton? {
        if let button = view as? NSStatusBarButton { return button }
        for subview in view.subviews {
            if let button = statusBarButton(in: subview) { return button }
        }
        return nil
    }
}
