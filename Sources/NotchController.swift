import AppKit

/// One per screen. Owns the always-on-top notch panel; anchored top-center,
/// resizes between collapsed (notch strip) and expanded (gallery rail).
final class NotchController: NSObject {
    /// Three resting/hover stages. Mouse dwell promotes minimized → notch →
    /// expanded; each promotion is gated on a short dwell so a brushing-past
    /// hover never snaps the gallery open.
    enum Stage { case minimized, notch, expanded }

    private let screen: NSScreen
    private let panel: NSPanel
    private let notchView: NotchView
    private let minimizedSize: NSSize
    private let collapsedSize: NSSize
    private let expandedSize: NSSize
    private(set) var stage: Stage = .minimized
    private var collapseTimer: Timer?
    private var promoteTimer: Timer?
    var dragActive = false

    /// Back-compat for callers that only care whether the gallery is open.
    var isExpanded: Bool { stage == .expanded }

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
        // resting minimized: a thin, narrow sliver that hugs the top edge so it
        // stays out of the way until the cursor dwells over it.
        minimizedSize = NSSize(width: min(collapsed.width, 140),
                               height: max(6, min(collapsed.height, 8)))
        expandedSize = NSSize(width: max(640, collapsed.width + 300), height: collapsed.height + 150)

        notchView = NotchView(frame: NSRect(origin: .zero, size: minimizedSize), topHeight: collapsed.height)
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: minimizedSize),
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
        panel.setFrame(frame(for: minimizedSize), display: true)
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            self, selector: #selector(shelfChanged(_:)), name: .shelfChanged, object: nil)
        notchView.reloadRail()
    }

    func close() {
        NotificationCenter.default.removeObserver(self)
        collapseTimer?.invalidate()
        promoteTimer?.invalidate()
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

    private func size(for stage: Stage) -> NSSize {
        switch stage {
        case .minimized: return minimizedSize
        case .notch:     return collapsedSize
        case .expanded:  return expandedSize
        }
    }

    /// Animate to a given stage. Caller owns the dwell gating.
    func setStage(_ target: Stage, animated: Bool = true) {
        guard target != stage else { return }
        stage = target
        notchView.expanded = (target == .expanded)
        let dur = animated ? (target == .minimized ? 0.22 : 0.28) : 0
        let curve: CAMediaTimingFunctionName = target == .minimized ? .easeIn : .easeOut
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = dur
            ctx.timingFunction = CAMediaTimingFunction(name: curve)
            panel.animator().setFrame(frame(for: size(for: target)), display: true)
            notchView.setRailVisible(target == .expanded)
        }
    }

    /// Hover dwell entered. Promote one stage now, then schedule the next
    /// promotion after a short dwell so the gallery only opens on lingering.
    func hoverBegan() {
        collapseTimer?.invalidate()
        switch stage {
        case .minimized:
            setStage(.notch)
            schedulePromotion()
        case .notch:
            schedulePromotion()
        case .expanded:
            break
        }
    }

    private func schedulePromotion(after delay: TimeInterval = 0.45) {
        promoteTimer?.invalidate()
        promoteTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self, self.mouseInside, self.stage == .notch else { return }
            self.setStage(.expanded)
        }
    }

    /// Back-compat: jump straight to the gallery (used by peek / explicit opens).
    func expand() {
        collapseTimer?.invalidate()
        promoteTimer?.invalidate()
        setStage(.expanded)
    }

    func collapse(force: Bool = false) {
        guard stage != .minimized else { return }
        if !force && (mouseInside || dragActive) { return }
        promoteTimer?.invalidate()
        setStage(.minimized)
    }

    func scheduleCollapse(after delay: TimeInterval = 0.30) {
        promoteTimer?.invalidate()
        collapseTimer?.invalidate()
        collapseTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.collapse()
        }
    }

    /// Dictation HUD passthrough — renders in the notch strip, so lift to the
    /// notch stage while active and drop back to minimized when it clears.
    func setStatus(_ state: String) {
        let active = (state == "listening" || state == "transcribing")
        if active {
            collapseTimer?.invalidate()
            promoteTimer?.invalidate()
            if stage == .minimized { setStage(.notch) }
        } else if stage == .notch {
            scheduleCollapse(after: 0.6)
        }
        notchView.setStatus(state)
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
