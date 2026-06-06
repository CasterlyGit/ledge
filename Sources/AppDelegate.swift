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
        // dictation bridge: laptop-dictation posts listening/transcribing/idle here.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(statusCommand(_:)),
            name: NSNotification.Name("com.casterly.ledge.status"), object: nil)
    }

    @objc private func statusCommand(_ note: Notification) {
        let state = (note.object as? String) ?? "idle"
        DispatchQueue.main.async { self.controllers.forEach { $0.setStatus(state) } }
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
        // Color command: "notch:<color>" or "color:<color>" — set live, no rebuild.
        for prefix in ["notch:", "color:"] where cmd.hasPrefix(prefix) {
            let name = String(cmd.dropFirst(prefix.count))
            if let color = NamedColor.parse(name) {
                DispatchQueue.main.async { self.controllers.forEach { $0.setNotchColor(color) } }
            }
            return
        }
        switch cmd {
        case "expand":   controllers.forEach { $0.expand() }
        case "collapse": controllers.forEach { $0.collapse(force: true) }
        case "peek":     controllers.forEach { $0.peek() }
        default: break
        }
    }
}

/// Resolve a spoken/typed color word (or #hex) to an NSColor. Generous on
/// phrasing because the source is dictation: "electric blue", "reset", "#0af".
enum NamedColor {
    static func parse(_ raw: String) -> NSColor? {
        var s = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // drop filler words a dictation might leave in ("the", "color", "to")
        for noise in ["the ", "color ", "colour ", "to ", "a "] where s.hasPrefix(noise) {
            s = String(s.dropFirst(noise.count))
        }
        s = s.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return nil }
        if s == "reset" || s == "default" || s == "normal" { return .black }
        if let hex = parseHex(s) { return hex }
        return table[s] ?? table[s.replacingOccurrences(of: " ", with: "")]
    }

    private static func parseHex(_ s: String) -> NSColor? {
        guard s.hasPrefix("#") else { return nil }
        var h = String(s.dropFirst())
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return NSColor(calibratedRed: CGFloat((v >> 16) & 0xff) / 255,
                       green: CGFloat((v >> 8) & 0xff) / 255,
                       blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }

    private static let table: [String: NSColor] = [
        "black": .black, "white": .white,
        "red": rgb(0xE5484D), "green": rgb(0x46A758), "blue": rgb(0x3E63DD),
        "cyan": rgb(0x4CC3FF), "electricblue": rgb(0x4CC3FF), "neon": rgb(0x4CC3FF),
        "teal": rgb(0x12A594), "yellow": rgb(0xF5D90A), "orange": rgb(0xF76B15),
        "purple": rgb(0x8E4EC6), "violet": rgb(0x8E4EC6), "magenta": rgb(0xD6409F),
        "pink": rgb(0xE93D82), "gray": rgb(0x8B8D98), "grey": rgb(0x8B8D98),
    ]

    private static func rgb(_ v: UInt32) -> NSColor {
        NSColor(calibratedRed: CGFloat((v >> 16) & 0xff) / 255,
                green: CGFloat((v >> 8) & 0xff) / 255,
                blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
}
