import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [NotchController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("Ledge 0.1.0 starting")
        ShelfStore.shared.load()
        ScreenshotWatcher.shared.start()
        ClipboardWatcher.shared.start()
        rebuild()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(debugCommand(_:)),
            name: NSNotification.Name("com.casterly.ledge.debug"), object: nil)
    }

    @objc private func screensChanged() { rebuild() }

    private func rebuild() {
        controllers.forEach { $0.close() }
        controllers = NSScreen.screens.map { NotchController(screen: $0) }
        NSLog("Ledge: notch on \(controllers.count) screen(s)")
    }

    // debug hooks for headless verification:
    //   echo '...' | swift -  → DistributedNotificationCenter post "com.casterly.ledge.debug" object "expand"|"collapse"|"peek"
    @objc private func debugCommand(_ note: Notification) {
        guard let cmd = note.object as? String else { return }
        switch cmd {
        case "expand":   controllers.forEach { $0.expand() }
        case "collapse": controllers.forEach { $0.collapse(force: true) }
        case "peek":     controllers.forEach { $0.peek() }
        default: break
        }
    }
}
