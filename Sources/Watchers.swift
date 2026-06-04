import AppKit

/// Watches the macOS screenshot save directory and shelves every new capture.
/// Zero-TCC route: install step points com.apple.screencapture at ~/Pictures/Screenshots
/// (not Desktop, which is TCC-protected). If the user has a custom location set,
/// that directory is honored instead.
final class ScreenshotWatcher {
    static let shared = ScreenshotWatcher()
    private var source: DispatchSourceFileSystemObject?
    private var known = Set<String>()
    private var dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Pictures/Screenshots", isDirectory: true)

    func start() {
        source?.cancel()
        source = nil
        if let loc = CFPreferencesCopyAppValue("location" as CFString, "com.apple.screencapture" as CFString) as? String {
            let expanded = (loc as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
                dir = URL(fileURLWithPath: expanded, isDirectory: true)
            }
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        known = list()
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else {
            NSLog("Ledge: cannot watch \(dir.path)")
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write], queue: .main)
        src.setEventHandler { [weak self] in self?.scan() }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
        NSLog("Ledge: watching screenshots in \(dir.path)")
    }

    private func list() -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
    }

    private func scan() {
        let current = list()
        let added = current.subtracting(known)
        known = current
        for name in added {
            guard !name.hasPrefix("."),
                  ShelfStore.imageExts.contains((name as NSString).pathExtension.lowercased())
            else { continue }
            let url = dir.appendingPathComponent(name)
            // small delay: let screencapture finish writing
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                guard FileManager.default.fileExists(atPath: url.path) else { return }
                ShelfStore.shared.importFile(url)
            }
        }
    }
}

/// Polls the general pasteboard for raw image data (e.g. ⌃⇧⌘4 clipboard
/// screenshots, Copy Image in a browser) and shelves it.
final class ClipboardWatcher {
    static let shared = ClipboardWatcher()
    private var timer: Timer?
    private var lastChange = NSPasteboard.general.changeCount
    private var ignored = Set<Int>()
    private var lastHash = 0

    /// Skip a pasteboard generation we wrote ourselves.
    func ignoreChange(_ change: Int) { ignored.insert(change) }

    func start() {
        // .common mode so ticks keep firing during drag sessions and menu tracking
        let t = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let pb = NSPasteboard.general
        let change = pb.changeCount
        guard change != lastChange else { return }
        lastChange = change
        if ignored.remove(change) != nil { return }
        let types = pb.types ?? []
        // raw image data only — Finder file copies (fileURL) stay out of the shelf
        guard !types.contains(.fileURL), types.contains(.png) || types.contains(.tiff) else { return }
        var data = pb.data(forType: .png)
        if data == nil, let tiff = pb.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff) {
            data = rep.representation(using: .png, properties: [:])
        }
        guard let d = data, !d.isEmpty else { return }
        let h = d.hashValue
        guard h != lastHash else { return }
        lastHash = h
        ShelfStore.shared.importImageData(d)
    }
}
