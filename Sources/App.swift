import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var insomnia: Insomnia!
    private var statusMenu: StatusMenu!
    private var updater: Updater!

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if let snapshot = Snapshot.requested {
            insomnia = Insomnia(defaults: snapshot.defaults)
            insomnia.demo = snapshot.demo
            statusMenu = StatusMenu(insomnia: insomnia, updater: nil)
            snapshot.run(statusMenu)
            return
        }
        #endif
        insomnia = Insomnia(defaults: .standard)
        updater = Updater()
        statusMenu = StatusMenu(insomnia: insomnia, updater: updater)
        // Never shown for a menu bar app, but gives the settings window its ⌘W.
        let file = NSMenuItem()
        file.submenu = NSMenu()
        file.submenu?.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        NSApp.mainMenu = NSMenu()
        NSApp.mainMenu?.addItem(file)
    }

    /// Opening Insomnia again from Finder or Launchpad shows its settings, since it has no other window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        statusMenu.openSettings()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        insomnia.shutDown()
    }
}
