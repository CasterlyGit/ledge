import AppKit
import ImageIO
import Vision

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

    private(set) var items: [ShelfItem] = []   // pinned first, then newest first
    private var thumbCache: [URL: NSImage] = [:]
    private var pinnedNames: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "LedgePinned") ?? [])

    // OCR text cache (filename → recognized text), for full-text search. Persisted.
    private var ocrCache: [String: String] = (UserDefaults.standard.dictionary(forKey: "LedgeOCRText") as? [String: String]) ?? [:]
    private var ocrInFlight: Set<String> = []

    // Search & filter state
    var searchText: String = "" { didSet { notifyFilterChanged(); ensureOCRForSearch() } }
    enum DateFilter { case all, today, week }
    var dateFilter: DateFilter = .all { didSet { notifyFilterChanged() } }
    var showPinnedOnly: Bool = false { didSet { notifyFilterChanged() } }
    var tagFilter: String? { didSet { notifyFilterChanged() } }  // nil = all, "error" = only errors, etc.

    var filteredItems: [ShelfItem] {
        var result = items
        if showPinnedOnly { result = result.filter { isPinned($0) } }
        if dateFilter != .all { result = filterByDate(result, filter: dateFilter) }
        if let tag = tagFilter { result = result.filter { item in
            ImageAnalyzer.shared.cachedTag(for: item)?.tags.contains(tag) == true
        } }
        if !searchText.isEmpty { result = result.filter { searchMatches($0) } }
        return result
    }

    private func filterByDate(_ items: [ShelfItem], filter: DateFilter) -> [ShelfItem] {
        let now = Date()
        let cal = Calendar.current
        return items.filter { item in
            switch filter {
            case .all: return true
            case .today: return cal.isDateInToday(item.date)
            case .week: return now.timeIntervalSince(item.date) < 7 * 86400
            }
        }
    }

    private func searchMatches(_ item: ShelfItem) -> Bool {
        let search = searchText.lowercased()
        let name = item.url.lastPathComponent
        if name.lowercased().contains(search) { return true }
        // Full-text: match against cached OCR text if we've recognized it.
        if let text = ocrCache[name], text.lowercased().contains(search) { return true }
        return false
    }

    /// Lazily OCR any shelf items we haven't recognized yet, so full-text search
    /// can match their contents. Runs off-main, caches, and re-notifies as results
    /// land (only while a search is still active).
    private func ensureOCRForSearch() {
        guard !searchText.isEmpty else { return }
        for item in items {
            let name = item.url.lastPathComponent
            if ocrCache[name] != nil || ocrInFlight.contains(name) { continue }
            ocrInFlight.insert(name)
            recognizeText(at: item.url) { [weak self] text in
                guard let self else { return }
                self.ocrInFlight.remove(name)
                self.ocrCache[name] = text
                UserDefaults.standard.set(self.ocrCache, forKey: "LedgeOCRText")
                if !self.searchText.isEmpty { self.notifyFilterChanged() }
            }
        }
    }

    /// Vision text recognition for an image URL. Completion on main with the
    /// recognized text (empty string if none / unreadable).
    private func recognizeText(at url: URL, completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                DispatchQueue.main.async { completion("") }; return
            }
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = true
            try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
            let text = (req.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
            DispatchQueue.main.async { completion(text) }
        }
    }

    private func notifyFilterChanged() {
        NotificationCenter.default.post(name: .shelfChanged, object: nil)
    }

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
        }
        // drop pins whose files are gone (deleted outside Ledge)
        pinnedNames.formIntersection(Set(items.map { $0.url.lastPathComponent }))
        persistPins()
        sortItems()
        prune()
        NSLog("Ledge: loaded \(items.count) shelf item(s), \(pinnedNames.count) pinned")
    }

    // MARK: pinning — pinned items sort first, survive prune and Clear

    func isPinned(_ item: ShelfItem) -> Bool { pinnedNames.contains(item.url.lastPathComponent) }

    var pinnedCount: Int { items.filter { isPinned($0) }.count }

    func togglePin(_ item: ShelfItem) {
        let name = item.url.lastPathComponent
        if pinnedNames.remove(name) == nil { pinnedNames.insert(name) }
        persistPins()
        sortItems()
        NotificationCenter.default.post(name: .shelfChanged, object: nil)
    }

    private func persistPins() {
        UserDefaults.standard.set(Array(pinnedNames), forKey: "LedgePinned")
    }

    private func sortItems() {
        items.sort { a, b in
            let pa = isPinned(a), pb = isPinned(b)
            if pa != pb { return pa }
            return a.date > b.date
        }
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
        sortItems()
        prune()
        if toClipboard { copyToPasteboard(item) }
        NSLog("Ledge: shelved \(url.lastPathComponent)")
        // Auto-analyze for tags (off-main, cached)
        ImageAnalyzer.shared.analyzeImage(item) { _ in }
        NotificationCenter.default.post(name: .shelfChanged, object: nil, userInfo: ["added": true])
        return item
    }

    func delete(_ item: ShelfItem) {
        try? FileManager.default.removeItem(at: item.url)
        thumbCache[item.url] = nil
        items.removeAll { $0 == item }
        if pinnedNames.remove(item.url.lastPathComponent) != nil { persistPins() }
        NotificationCenter.default.post(name: .shelfChanged, object: nil)
    }

    /// Clear everything except pinned items.
    func clear() {
        for it in items where !isPinned(it) {
            try? FileManager.default.removeItem(at: it.url)
            thumbCache[it.url] = nil
        }
        items = items.filter { isPinned($0) }
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
        var overflow = items.count - Self.maxItems
        var idx = items.count - 1
        while overflow > 0 && idx >= 0 {
            let it = items[idx]
            if !isPinned(it) {   // pinned items never age out
                try? FileManager.default.removeItem(at: it.url)
                thumbCache[it.url] = nil
                items.remove(at: idx)
                overflow -= 1
            }
            idx -= 1
        }
    }

    // MARK: OCR — recognize text in an image and put it on the clipboard

    func copyText(of item: ShelfItem, completion: @escaping (Bool) -> Void) {
        let url = item.url
        recognizeText(at: url) { [weak self] text in
            // Warm the search cache while we're here.
            self?.ocrCache[url.lastPathComponent] = text
            UserDefaults.standard.set(self?.ocrCache, forKey: "LedgeOCRText")
            guard !text.isEmpty else { completion(false); return }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            ClipboardWatcher.shared.ignoreChange(pb.changeCount)
            NSLog("Ledge: OCR copied \(text.count) chars from \(url.lastPathComponent)")
            completion(true)
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

    // MARK: Smart search — voice-triggered quick actions

    /// Apply a smart filter based on a voice query. "find errors", "show charts", etc.
    func smartFilter(query: String) {
        let q = query.lowercased()
        if q.contains("error") || q.contains("fail") { tagFilter = "error"; searchText = "" }
        else if q.contains("chart") || q.contains("graph") { tagFilter = "chart"; searchText = "" }
        else if q.contains("code") { tagFilter = "code"; searchText = "" }
        else if q.contains("message") || q.contains("chat") { tagFilter = "message"; searchText = "" }
        else if q.contains("clear") || q.contains("reset") { tagFilter = nil; searchText = "" }
        else { searchText = q; tagFilter = nil }
    }

    /// Get the latest screenshot of a given type.
    func latestWithTag(_ tag: String) -> ShelfItem? {
        items.first { item in
            ImageAnalyzer.shared.cachedTag(for: item)?.tags.contains(tag) == true
        }
    }
}
