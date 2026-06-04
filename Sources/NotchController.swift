import AppKit

/// One per screen. Owns the always-on-top notch panel; anchored top-center,
/// resizes between collapsed (notch strip) and expanded (gallery rail).
final class NotchController: NSObject {
    private let screen: NSScreen
    private let panel: NSPanel
    private let notchView: NotchView
    private let collapsedSize: NSSize
    private let expandedSize: NSSize
    private(set) var isExpanded = false
    private var collapseTimer: Timer?
    var dragActive = false

    init(screen: NSScreen) {
        self.screen = screen
        let collapsed: NSSize
        let inset = screen.safeAreaInsets.top
        if inset > 0 {
            // built-in display with hardware notch: hug it, 12pt wings each side
            var notchW: CGFloat = 200
            if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
                notchW = screen.frame.width - l.width - r.width
            }
            collapsed = NSSize(width: notchW + 24, height: inset)
        } else {
            // external display: draw the notch ourselves
            collapsed = NSSize(width: 210, height: 30)
        }
        collapsedSize = collapsed
        expandedSize = NSSize(width: max(640, collapsed.width + 300), height: collapsed.height + 150)

        notchView = NotchView(frame: NSRect(origin: .zero, size: collapsed), topHeight: collapsed.height)
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: collapsed),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        super.init()

        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.contentView = notchView
        notchView.controller = self
        panel.setFrame(frame(for: collapsedSize), display: true)
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            self, selector: #selector(shelfChanged(_:)), name: .shelfChanged, object: nil)
        notchView.reloadRail()
    }

    func close() {
        NotificationCenter.default.removeObserver(self)
        collapseTimer?.invalidate()
        panel.orderOut(nil)
    }

    /// Re-resolve the live NSScreen by display ID — geometry can change
    /// between rebuilds (resolution switch) and stale frames park the panel
    /// off-screen.
    private var currentScreen: NSScreen {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let id = screen.deviceDescription[key] as? NSNumber,
           let live = NSScreen.screens.first(where: { ($0.deviceDescription[key] as? NSNumber) == id }) {
            return live
        }
        return screen
    }

    private func frame(for size: NSSize) -> NSRect {
        let f = currentScreen.frame
        return NSRect(x: (f.midX - size.width / 2).rounded(),
                      y: f.maxY - size.height,
                      width: size.width, height: size.height)
    }

    var mouseInside: Bool {
        panel.frame.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
    }

    func expand() {
        collapseTimer?.invalidate()
        guard !isExpanded else { return }
        isExpanded = true
        notchView.expanded = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.30
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame(for: expandedSize), display: true)
            notchView.setRailVisible(true)
        }
    }

    func collapse(force: Bool = false) {
        guard isExpanded else { return }
        if !force && (mouseInside || dragActive) { return }
        isExpanded = false
        notchView.expanded = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(frame(for: collapsedSize), display: true)
            notchView.setRailVisible(false)
        }
    }

    func scheduleCollapse(after delay: TimeInterval = 0.30) {
        collapseTimer?.invalidate()
        collapseTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.collapse()
        }
    }

    /// Auto-expand briefly (new capture landed), then retract unless hovered.
    func peek() {
        expand()
        scheduleCollapse(after: 2.6)
    }

    @objc private func shelfChanged(_ note: Notification) {
        notchView.reloadRail()
        if (note.userInfo?["added"] as? Bool) == true { peek() }
    }
}
