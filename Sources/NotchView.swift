import AppKit

/// Draws the black notch (hardware-style: flared top corners, rounded bottom),
/// hosts the horizontal thumbnail rail, accepts drops from anywhere.
final class NotchView: NSView {
    weak var controller: NotchController?
    var expanded = false { didSet { needsDisplay = true } }

    /// Live notch fill. Default is the hardware black; a spoken "notch <color>"
    /// command (via NotchController → AppDelegate) sets this and redraws instantly.
    var notchColor: NSColor = .black { didSet { needsDisplay = true } }

    private let topHeight: CGFloat
    private let railScroll = NSScrollView()
    private let railStack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "⇧⌘3 to capture  ·  drop images here")
    private let countLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "click copy · 2× open · ⌥ grab text · drag out")
    private var highlight = false { didSet { needsDisplay = true } }
    private var trackingArea: NSTrackingArea?

    // Dictation HUD: lives in the notch strip itself (no gallery expand).
    private let statusSpinner = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private var statusActive = false

    // Search/filter
    private let searchField = NSSearchField()
    private var searchTimer: Timer?
    private let filterSeg = NSSegmentedControl(labels: ["All", "Today", "Pinned"],
                                               trackingMode: .selectOne, target: nil, action: nil)

    init(frame: NSRect, topHeight: CGFloat) {
        self.topHeight = topHeight
        super.init(frame: frame)
        wantsLayer = true
        var types = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        types += [.fileURL, .png, .tiff]
        registerForDraggedTypes(types)
        setupRail()
        setupStatus()
        setupSearch()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero,
                               options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    override func mouseEntered(with event: NSEvent) { controller?.hoverBegan() }
    override func mouseExited(with event: NSEvent) { controller?.scheduleCollapse() }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        let path = notchPath(in: bounds)
        notchColor.setFill()
        path.fill()
        if highlight {
            NSColor(calibratedRed: 0.3, green: 0.85, blue: 1.0, alpha: 0.16).setFill()
            path.fill()
        }
        NSColor(calibratedWhite: 1, alpha: expanded ? 0.10 : 0.06).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    /// Hardware-notch silhouette: concave flares where it meets the top edge,
    /// rounded corners at the bottom.
    private func notchPath(in rect: NSRect) -> NSBezierPath {
        let t: CGFloat = 8
        let r: CGFloat = expanded ? 16 : 10
        let W = rect.width, H = rect.height
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 0, y: H))
        p.curve(to: NSPoint(x: t, y: H - t),
                controlPoint1: NSPoint(x: t, y: H), controlPoint2: NSPoint(x: t, y: H))
        p.line(to: NSPoint(x: t, y: r))
        p.curve(to: NSPoint(x: t + r, y: 0),
                controlPoint1: NSPoint(x: t, y: 0), controlPoint2: NSPoint(x: t, y: 0))
        p.line(to: NSPoint(x: W - t - r, y: 0))
        p.curve(to: NSPoint(x: W - t, y: r),
                controlPoint1: NSPoint(x: W - t, y: 0), controlPoint2: NSPoint(x: W - t, y: 0))
        p.line(to: NSPoint(x: W - t, y: H - t))
        p.curve(to: NSPoint(x: W, y: H),
                controlPoint1: NSPoint(x: W - t, y: H), controlPoint2: NSPoint(x: W - t, y: H))
        p.close()
        return p
    }

    // MARK: rail

    private func setupRail() {
        railScroll.drawsBackground = false
        railScroll.hasHorizontalScroller = true
        railScroll.hasVerticalScroller = false
        railScroll.horizontalScrollElasticity = .allowed
        railScroll.verticalScrollElasticity = .none
        railScroll.scrollerStyle = .overlay
        railScroll.autohidesScrollers = true
        railScroll.alphaValue = 0

        railStack.orientation = .horizontal
        railStack.alignment = .centerY
        railStack.spacing = 10
        railStack.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        railStack.translatesAutoresizingMaskIntoConstraints = false

        railScroll.documentView = railStack
        let clip = railScroll.contentView
        NSLayoutConstraint.activate([
            railStack.topAnchor.constraint(equalTo: clip.topAnchor),
            railStack.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
            railStack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
        ])
        addSubview(railScroll)

        emptyLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.35)
        emptyLabel.font = .systemFont(ofSize: 12, weight: .medium)
        emptyLabel.alphaValue = 0
        addSubview(emptyLabel)

        // expanded-only chrome in the notch strip band: count (right), hints (left)
        countLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        countLabel.textColor = NSColor(calibratedRed: 0.3, green: 0.85, blue: 1.0, alpha: 0.8)
        countLabel.alphaValue = 0
        addSubview(countLabel)

        hintLabel.font = .systemFont(ofSize: 9, weight: .medium)
        hintLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.28)
        hintLabel.alphaValue = 0
        addSubview(hintLabel)
    }

    // MARK: dictation status HUD (driven by com.casterly.ledge.status)

    private func setupStatus() {
        statusSpinner.style = .spinning
        statusSpinner.controlSize = .small
        statusSpinner.isIndeterminate = true
        statusSpinner.isDisplayedWhenStopped = false
        statusSpinner.appearance = NSAppearance(named: .darkAqua)  // light spinner on black
        statusSpinner.alphaValue = 0
        addSubview(statusSpinner)

        statusLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        statusLabel.textColor = NSColor(calibratedRed: 0.3, green: 0.85, blue: 1.0, alpha: 1)  // cyan
        statusLabel.alphaValue = 0
        addSubview(statusLabel)
    }

    // MARK: search field

    private func setupSearch() {
        searchField.placeholderString = "Search shelf"
        searchField.font = .systemFont(ofSize: 11)
        searchField.bezelStyle = .roundedBezel
        searchField.alphaValue = 0
        searchField.target = self
        searchField.action = #selector(updateSearch)
        addSubview(searchField)

        filterSeg.segmentStyle = .rounded
        filterSeg.font = .systemFont(ofSize: 10)
        filterSeg.selectedSegment = 0
        filterSeg.alphaValue = 0
        filterSeg.target = self
        filterSeg.action = #selector(updateFilter)
        addSubview(filterSeg)
    }

    @objc private func updateSearch() {
        ShelfStore.shared.searchText = searchField.stringValue
        reloadRail()
    }

    @objc private func updateFilter() {
        let store = ShelfStore.shared
        switch filterSeg.selectedSegment {
        case 1:  store.dateFilter = .today; store.showPinnedOnly = false
        case 2:  store.dateFilter = .all;   store.showPinnedOnly = true
        default: store.dateFilter = .all;   store.showPinnedOnly = false
        }
        reloadRail()
    }

    /// Show a one-word HUD in the notch strip: "listening" → spinner + "Listening",
    /// "transcribing" → "Transcribing…", anything else → hide. Never expands the gallery.
    func setStatus(_ state: String) {
        let text: String?
        switch state {
        case "listening":    text = "Listening"
        case "transcribing": text = "Transcribing…"
        default:             text = nil
        }
        statusActive = (text != nil)
        needsLayout = true
        if let text {
            statusLabel.stringValue = text
            statusSpinner.startAnimation(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                statusSpinner.animator().alphaValue = 1
                statusLabel.animator().alphaValue = 1
            }
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.18
                statusSpinner.animator().alphaValue = 0
                statusLabel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                if self?.statusActive == false { self?.statusSpinner.stopAnimation(nil) }
            })
        }
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 14
        let searchH: CGFloat = expanded && ShelfStore.shared.items.count > 0 ? 24 : 0
        let railH = max(0, bounds.height - topHeight - pad - 8 - searchH)
        railScroll.frame = NSRect(x: pad + 8, y: pad + searchH,
                                  width: max(0, bounds.width - 2 * (pad + 8)), height: railH)
        let rowY = bounds.height - topHeight - 18
        let rowW = bounds.width - 2 * (pad + 8)
        let segW: CGFloat = 168, segGap: CGFloat = 8
        searchField.frame = NSRect(x: pad + 8, y: rowY,
                                   width: max(0, rowW - segW - segGap), height: 20)
        filterSeg.frame = NSRect(x: pad + 8 + rowW - segW, y: rowY, width: segW, height: 20)
        emptyLabel.sizeToFit()
        emptyLabel.frame.origin = NSPoint(x: bounds.midX - emptyLabel.frame.width / 2,
                                          y: pad + railH / 2 - emptyLabel.frame.height / 2)

        // status HUD: centered in the top notch-strip band (works collapsed or expanded)
        statusLabel.sizeToFit()
        let sp: CGFloat = 14, gap: CGFloat = 6
        let groupW = sp + gap + statusLabel.frame.width
        let originX = bounds.midX - groupW / 2
        let bandMidY = bounds.maxY - topHeight / 2
        statusSpinner.frame = NSRect(x: originX, y: bandMidY - sp / 2, width: sp, height: sp)
        statusLabel.frame.origin = NSPoint(x: originX + sp + gap,
                                           y: bandMidY - statusLabel.frame.height / 2)

        countLabel.sizeToFit()
        countLabel.frame.origin = NSPoint(x: bounds.maxX - countLabel.frame.width - 24,
                                          y: bandMidY - countLabel.frame.height / 2)
        hintLabel.sizeToFit()
        hintLabel.frame.origin = NSPoint(x: 24, y: bandMidY - hintLabel.frame.height / 2)
    }

    /// Called inside the controller's animation group.
    func setRailVisible(_ visible: Bool) {
        let empty = ShelfStore.shared.items.isEmpty
        railScroll.animator().alphaValue = visible ? 1 : 0
        emptyLabel.animator().alphaValue = (visible && empty) ? 1 : 0
        countLabel.animator().alphaValue = (visible && !empty) ? 1 : 0
        hintLabel.animator().alphaValue = (visible && !empty) ? 1 : 0
        searchField.animator().alphaValue = visible ? 1 : 0
        filterSeg.animator().alphaValue = (visible && !empty) ? 1 : 0
        if visible { searchField.becomeFirstResponder() }
    }

    func reloadRail() {
        railStack.arrangedSubviews.forEach {
            railStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let filtered = ShelfStore.shared.filteredItems
        for item in filtered {
            railStack.addArrangedSubview(ShelfItemView(item: item))
        }
        let n = ShelfStore.shared.items.count
        let f = filtered.count
        let pins = ShelfStore.shared.pinnedCount
        let hasFilter = !ShelfStore.shared.searchText.isEmpty || ShelfStore.shared.showPinnedOnly
            || ShelfStore.shared.dateFilter != .all
        countLabel.stringValue = n == 0 ? "" :
            (hasFilter ? "\(f)/\(n)" : (pins > 0 ? "\(n) · \(pins) pinned" : "\(n) item\(n == 1 ? "" : "s")"))
        needsLayout = true
        if expanded {
            emptyLabel.alphaValue = (n == 0 || f == 0) ? 1 : 0
            countLabel.alphaValue = (n == 0 || f == 0) ? 0 : 1
            hintLabel.alphaValue = (n == 0 || f == 0) ? 0 : 1
        }
        railScroll.contentView.scroll(to: .zero)
        railScroll.reflectScrolledClipView(railScroll.contentView)
    }

    // MARK: drop target

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        controller?.dragActive = true
        controller?.expand()
        highlight = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        highlight = false
        controller?.dragActive = false
        controller?.scheduleCollapse()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        highlight = false
        controller?.dragActive = false
        controller?.scheduleCollapse(after: 1.2)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlight = false
        let pb = sender.draggingPasteboard

        // 1. real files (Finder, screenshots dragged off Desktop, etc.)
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            var ok = false
            for u in urls where ShelfStore.imageExts.contains(u.pathExtension.lowercased()) {
                if ShelfStore.shared.importFile(u, toClipboard: true) != nil { ok = true }
            }
            return ok
        }

        // 2. file promises (browser images, Photos, mail attachments)
        if let promises = pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil)
            as? [NSFilePromiseReceiver], !promises.isEmpty {
            for p in promises {
                p.receivePromisedFiles(atDestination: ShelfStore.shared.dir, options: [:],
                                       operationQueue: .main) { url, error in
                    guard error == nil else { return }
                    // brief grace: some providers signal before the last flush
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        ShelfStore.shared.registerExisting(url, toClipboard: true)
                    }
                }
            }
            return true
        }

        // 3. raw image data
        if let png = pb.data(forType: .png) {
            return ShelfStore.shared.importImageData(png, toClipboard: true) != nil
        }
        if let tiff = pb.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return ShelfStore.shared.importImageData(png, toClipboard: true) != nil
        }
        return false
    }

    // MARK: context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        m.addItem(withTitle: "Open Shelf Folder", action: #selector(openFolder), keyEquivalent: "").target = self
        m.addItem(withTitle: "Clear All (keeps pinned)", action: #selector(clearAll), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Quit Ledge", action: #selector(quit), keyEquivalent: "").target = self
        return m
    }

    @objc private func openFolder() { NSWorkspace.shared.activateFileViewerSelecting([ShelfStore.shared.dir]) }
    @objc private func clearAll() { ShelfStore.shared.clear() }
    @objc private func quit() { NSApp.terminate(nil) }
}

/// One thumbnail in the rail. Click = copy to clipboard, double-click = open,
/// ⌥-click = OCR text to clipboard, drag = drag the file out (Terminal gets the
/// path, image apps get the image), dwell = full-size preview, right-click = menu.
final class ShelfItemView: NSView, NSDraggingSource {
    private let item: ShelfItem
    private let imageView = NSImageView()
    private let pinBadge = NSImageView()
    private var mouseDownEvent: NSEvent?
    private var widthConstraint: NSLayoutConstraint?
    private var previewTimer: Timer?
    private var preview: NSPopover?
    private static weak var activePreview: NSPopover?
    private var tileTrackingArea: NSTrackingArea?

    init(item: ShelfItem) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.12).cgColor
        toolTip = item.url.lastPathComponent

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.isEditable = false
        imageView.unregisterDraggedTypes()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        pinBadge.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "pinned")
        pinBadge.symbolConfiguration = .init(pointSize: 9, weight: .bold)
        pinBadge.contentTintColor = NSColor(calibratedRed: 0.3, green: 0.85, blue: 1.0, alpha: 1)
        pinBadge.wantsLayer = true
        pinBadge.layer?.backgroundColor = NSColor(calibratedWhite: 0, alpha: 0.65).cgColor
        pinBadge.layer?.cornerRadius = 8
        pinBadge.translatesAutoresizingMaskIntoConstraints = false
        pinBadge.isHidden = !ShelfStore.shared.isPinned(item)
        addSubview(pinBadge)

        translatesAutoresizingMaskIntoConstraints = false
        let h: CGFloat = 104
        let wc = widthAnchor.constraint(equalToConstant: 130)
        widthConstraint = wc
        NSLayoutConstraint.activate([
            wc,
            heightAnchor.constraint(equalToConstant: h),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            pinBadge.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            pinBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            pinBadge.widthAnchor.constraint(equalToConstant: 16),
            pinBadge.heightAnchor.constraint(equalToConstant: 16),
        ])

        // cache hit completes synchronously; cold decode lands a beat later
        ShelfStore.shared.loadThumbnail(for: item) { [weak self] thumb in
            guard let self, let thumb else { return }
            self.imageView.image = thumb
            if thumb.size.height > 0 {
                self.widthConstraint?.constant =
                    min(190, max(64, (h * thumb.size.width / thumb.size.height).rounded()))
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Route all events to self (NSImageView must not swallow clicks/drags).
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        return bounds.contains(p) ? self : nil
    }

    // MARK: hover preview (dwell 0.45s → full-size popover)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tileTrackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero,
                               options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tileTrackingArea = t
    }

    override func mouseEntered(with event: NSEvent) {
        previewTimer?.invalidate()
        previewTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            self?.showPreview()
        }
    }

    override func mouseExited(with event: NSEvent) {
        previewTimer?.invalidate()
        closePreview()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { previewTimer?.invalidate(); closePreview() }
    }

    private func showPreview() {
        guard preview == nil, window != nil, notchController?.isExpanded == true,
              let img = NSImage(contentsOf: item.url) else { return }
        let maxW: CGFloat = 480, maxH: CGFloat = 300
        let scale = min(maxW / max(img.size.width, 1), maxH / max(img.size.height, 1), 1)
        let w = max(140, img.size.width * scale), h = max(90, img.size.height * scale)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: w + 16, height: h + 36))
        let iv = NSImageView(frame: NSRect(x: 8, y: 28, width: w, height: h))
        iv.image = img
        iv.imageScaling = .scaleProportionallyUpOrDown
        container.addSubview(iv)
        let caption = NSTextField(labelWithString: previewCaption(for: img))
        caption.font = .systemFont(ofSize: 10, weight: .medium)
        caption.textColor = .secondaryLabelColor
        caption.lineBreakMode = .byTruncatingMiddle
        caption.frame = NSRect(x: 8, y: 7, width: w, height: 14)
        caption.alignment = .center
        container.addSubview(caption)

        let vc = NSViewController()
        vc.view = container
        let p = NSPopover()
        p.contentViewController = vc
        p.behavior = .semitransient
        p.animates = false
        p.appearance = NSAppearance(named: .vibrantDark)
        Self.activePreview?.close()
        p.show(relativeTo: bounds, of: self, preferredEdge: .minY)
        Self.activePreview = p
        preview = p
    }

    private func closePreview() {
        preview?.close()
        preview = nil
    }

    private func previewCaption(for img: NSImage) -> String {
        var dims = ""
        if let rep = img.representations.first {
            dims = "\(rep.pixelsWide)×\(rep.pixelsHigh)"
        }
        let bytes = (try? item.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        return [item.url.lastPathComponent, dims, size].filter { !$0.isEmpty }.joined(separator: "  ·  ")
    }

    // MARK: click vs drag

    override func mouseDown(with event: NSEvent) {
        previewTimer?.invalidate()
        closePreview()
        mouseDownEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent else { return }
        let dx = abs(event.locationInWindow.x - down.locationInWindow.x)
        let dy = abs(event.locationInWindow.y - down.locationInWindow.y)
        guard dx > 3 || dy > 3 else { return }
        mouseDownEvent = nil
        let di = NSDraggingItem(pasteboardWriter: item.url as NSURL)
        di.setDraggingFrame(bounds, contents: imageView.image)
        beginDraggingSession(with: [di], event: down, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownEvent = nil }
        guard mouseDownEvent != nil else { return }
        if event.clickCount == 2 {                       // double-click = open
            NSWorkspace.shared.open(item.url)
            return
        }
        if event.modifierFlags.contains(.option) {       // ⌥-click = OCR text
            copyText()
            return
        }
        ShelfStore.shared.copyToPasteboard(item)
        flashCopied()
    }

    private func flashCopied() {
        flash(NSColor(calibratedRed: 0.3, green: 0.85, blue: 1.0, alpha: 0.9))
    }

    private func flash(_ color: NSColor) {
        guard let layer else { return }
        let anim = CABasicAnimation(keyPath: "borderColor")
        anim.fromValue = color.cgColor
        anim.toValue = layer.borderColor
        anim.duration = 0.7
        layer.add(anim, forKey: "copiedFlash")
    }

    // MARK: drag source

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        notchController?.dragActive = true
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        notchController?.dragActive = false
        notchController?.scheduleCollapse(after: 0.8)
    }

    private var notchController: NotchController? {
        (window?.contentView as? NotchView)?.controller
    }

    // MARK: context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        previewTimer?.invalidate()
        closePreview()
        let m = NSMenu()
        m.addItem(withTitle: "Copy", action: #selector(copyItem), keyEquivalent: "").target = self
        m.addItem(withTitle: "Copy Text (OCR)", action: #selector(copyTextAction), keyEquivalent: "").target = self
        m.addItem(withTitle: "Open", action: #selector(openItem), keyEquivalent: "").target = self
        m.addItem(.separator())
        let pinTitle = ShelfStore.shared.isPinned(item) ? "Unpin" : "Pin"
        m.addItem(withTitle: pinTitle, action: #selector(togglePin), keyEquivalent: "").target = self
        m.addItem(withTitle: "Share…", action: #selector(share), keyEquivalent: "").target = self
        m.addItem(withTitle: "Reveal in Finder", action: #selector(reveal), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Delete", action: #selector(deleteItem), keyEquivalent: "").target = self
        return m
    }

    @objc private func copyItem() { ShelfStore.shared.copyToPasteboard(item); flashCopied() }
    @objc private func copyTextAction() { copyText() }
    @objc private func openItem() { NSWorkspace.shared.open(item.url) }
    @objc private func togglePin() { ShelfStore.shared.togglePin(item) }
    @objc private func reveal() { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
    @objc private func deleteItem() { ShelfStore.shared.delete(item) }

    @objc private func share() {
        let picker = NSSharingServicePicker(items: [item.url])
        picker.show(relativeTo: bounds, of: self, preferredEdge: .minY)
    }

    /// OCR the image, put recognized text on the clipboard. Green flash = got
    /// text, red flash = none found.
    private func copyText() {
        ShelfStore.shared.copyText(of: item) { [weak self] ok in
            self?.flash(ok ? NSColor(calibratedRed: 0.35, green: 0.95, blue: 0.55, alpha: 0.95)
                           : NSColor(calibratedRed: 0.95, green: 0.35, blue: 0.35, alpha: 0.95))
        }
    }
}
