import AppKit

/// Draws the black notch (hardware-style: flared top corners, rounded bottom),
/// hosts the horizontal thumbnail rail, accepts drops from anywhere.
final class NotchView: NSView {
    weak var controller: NotchController?
    var expanded = false { didSet { needsDisplay = true } }

    private let topHeight: CGFloat
    private let railScroll = NSScrollView()
    private let railStack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "⇧⌘3 to capture  ·  drop images here")
    private var highlight = false { didSet { needsDisplay = true } }
    private var trackingArea: NSTrackingArea?

    init(frame: NSRect, topHeight: CGFloat) {
        self.topHeight = topHeight
        super.init(frame: frame)
        wantsLayer = true
        var types = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        types += [.fileURL, .png, .tiff]
        registerForDraggedTypes(types)
        setupRail()
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

    override func mouseEntered(with event: NSEvent) { controller?.expand() }
    override func mouseExited(with event: NSEvent) { controller?.scheduleCollapse() }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        let path = notchPath(in: bounds)
        NSColor.black.setFill()
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
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 14
        let railH = max(0, bounds.height - topHeight - pad - 8)
        railScroll.frame = NSRect(x: pad + 8, y: pad,
                                  width: max(0, bounds.width - 2 * (pad + 8)), height: railH)
        emptyLabel.sizeToFit()
        emptyLabel.frame.origin = NSPoint(x: bounds.midX - emptyLabel.frame.width / 2,
                                          y: pad + railH / 2 - emptyLabel.frame.height / 2)
    }

    /// Called inside the controller's animation group.
    func setRailVisible(_ visible: Bool) {
        railScroll.animator().alphaValue = visible ? 1 : 0
        emptyLabel.animator().alphaValue = (visible && ShelfStore.shared.items.isEmpty) ? 1 : 0
    }

    func reloadRail() {
        railStack.arrangedSubviews.forEach {
            railStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for item in ShelfStore.shared.items {
            railStack.addArrangedSubview(ShelfItemView(item: item))
        }
        if expanded {
            emptyLabel.alphaValue = ShelfStore.shared.items.isEmpty ? 1 : 0
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
        m.addItem(withTitle: "Clear All", action: #selector(clearAll), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Quit Ledge", action: #selector(quit), keyEquivalent: "").target = self
        return m
    }

    @objc private func openFolder() { NSWorkspace.shared.activateFileViewerSelecting([ShelfStore.shared.dir]) }
    @objc private func clearAll() { ShelfStore.shared.clear() }
    @objc private func quit() { NSApp.terminate(nil) }
}

/// One thumbnail in the rail. Click = copy to clipboard, drag = drag the file
/// out (Terminal gets the path, image apps get the image), right-click = menu.
final class ShelfItemView: NSView, NSDraggingSource {
    private let item: ShelfItem
    private let imageView = NSImageView()
    private var mouseDownEvent: NSEvent?
    private var widthConstraint: NSLayoutConstraint?

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

    // MARK: click vs drag

    override func mouseDown(with event: NSEvent) { mouseDownEvent = event }

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
        if mouseDownEvent != nil {
            ShelfStore.shared.copyToPasteboard(item)
            flashCopied()
        }
        mouseDownEvent = nil
    }

    private func flashCopied() {
        guard let layer else { return }
        let anim = CABasicAnimation(keyPath: "borderColor")
        anim.fromValue = NSColor(calibratedRed: 0.3, green: 0.85, blue: 1.0, alpha: 0.9).cgColor
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
        let m = NSMenu()
        m.addItem(withTitle: "Copy", action: #selector(copyItem), keyEquivalent: "").target = self
        m.addItem(withTitle: "Reveal in Finder", action: #selector(reveal), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Delete", action: #selector(deleteItem), keyEquivalent: "").target = self
        return m
    }

    @objc private func copyItem() { ShelfStore.shared.copyToPasteboard(item); flashCopied() }
    @objc private func reveal() { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
    @objc private func deleteItem() { ShelfStore.shared.delete(item) }
}
