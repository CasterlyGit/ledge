import AppKit
import ImageIO

struct ShelfItem: Equatable {
    let url: URL
    let date: Date
    static func == (lhs: ShelfItem, rhs: ShelfItem) -> Bool { lhs.url == rhs.url }
}

extension Notification.Name {
    static let shelfChanged = Notification.Name("LedgeShelfChanged")
}

final class ShelfStore {
    static let shared = ShelfStore()
    static let maxItems = 40
    static let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "tiff", "heic", "webp", "bmp"]

    let dir: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Ledge/shelf", isDirectory: true)

    private(set) var items: [ShelfItem] = []   // newest first
    private var thumbCache: [URL: NSImage] = [:]

    private let nameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()

    func load() {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let urls = (try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        items = urls.compactMap { url in
            guard Self.imageExts.contains(url.pathExtension.lowercased()) else { return nil }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return ShelfItem(url: url, date: date)
        }.sorted { $0.date > $1.date }
        prune()
        NSLog("Ledge: loaded \(items.count) shelf item(s)")
    }

    /// Copy an external file into the shelf.
    @discardableResult
    func importFile(_ src: URL, toClipboard: Bool = false) -> ShelfItem? {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = uniqueURL(for: src.lastPathComponent)
        do { try fm.copyItem(at: src, to: dest) } catch {
            NSLog("Ledge: import failed for \(src.path): \(error.localizedDescription)")
            return nil
        }
        return add(dest, toClipboard: toClipboard)
    }

    /// Persist raw image data (clipboard captures, raw-data drops).
    @discardableResult
    func importImageData(_ data: Data, toClipboard: Bool = false) -> ShelfItem? {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = uniqueURL(for: "Clip \(nameFormatter.string(from: Date())).png")
        do { try data.write(to: dest) } catch { return nil }
        return add(dest, toClipboard: toClipboard)
    }

    /// Register a file that already lives in the shelf dir (file-promise drops).
    @discardableResult
    func registerExisting(_ url: URL, toClipboard: Bool = false) -> ShelfItem? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return add(url, toClipboard: toClipboard)
    }

    @discardableResult
    private func add(_ url: URL, toClipboard: Bool) -> ShelfItem {
        let item = ShelfItem(url: url, date: Date())
        items.removeAll { $0.url == url }
        items.insert(item, at: 0)
        prune()
        if toClipboard { copyToPasteboard(item) }
        NSLog("Ledge: shelved \(url.lastPathComponent)")
        NotificationCenter.default.post(name: .shelfChanged, object: nil, userInfo: ["added": true])
        return item
    }

    func delete(_ item: ShelfItem) {
        try? FileManager.default.removeItem(at: item.url)
        thumbCache[item.url] = nil
        items.removeAll { $0 == item }
        NotificationCenter.default.post(name: .shelfChanged, object: nil)
    }

    func clear() {
        for it in items { try? FileManager.default.removeItem(at: it.url) }
        items = []
        thumbCache = [:]
        NotificationCenter.default.post(name: .shelfChanged, object: nil)
    }

    func copyToPasteboard(_ item: ShelfItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        var objs: [NSPasteboardWriting] = [item.url as NSURL]
        if let img = NSImage(contentsOf: item.url) { objs.append(img) }
        pb.writeObjects(objs)
        ClipboardWatcher.shared.ignoreChange(pb.changeCount)
    }

    /// Downscaled thumbnail, cached. Decode happens off the main thread so a
    /// cold rail of 40 items never stalls hover animation; cache hits complete
    /// synchronously. Cache is only touched on main.
    func loadThumbnail(for item: ShelfItem, completion: @escaping (NSImage?) -> Void) {
        if let t = thumbCache[item.url] { completion(t); return }
        let url = item.url
        DispatchQueue.global(qos: .userInitiated).async {
            var img: NSImage?
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
                let opts: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 380,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ]
                if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
                    img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                }
            }
            DispatchQueue.main.async {
                if let img { self.thumbCache[url] = img }
                completion(img)
            }
        }
    }

    private func prune() {
        while items.count > Self.maxItems {
            let last = items.removeLast()
            thumbCache[last.url] = nil
            try? FileManager.default.removeItem(at: last.url)
        }
    }

    private func uniqueURL(for name: String) -> URL {
        var candidate = dir.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var i = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) \(i)" + (ext.isEmpty ? "" : ".\(ext)"))
            i += 1
        }
        return candidate
    }
}
