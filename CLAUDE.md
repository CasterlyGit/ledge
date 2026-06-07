# ledge — notch screenshot shelf

Native AppKit (no Xcode project). Build: `./build.sh` → `build/Ledge.app`. Runs via
LaunchAgent `com.casterly.ledge` (`launchctl kickstart -k gui/$UID/com.casterly.ledge`
after rebuild). Logs: `/tmp/com.casterly.ledge.err.log`.

## Architecture (Sources/)

- `main.swift` — entry, `.accessory` activation
- `AppDelegate.swift` — one `NotchController` per `NSScreen`, rebuilt on
  `didChangeScreenParameters`; debug hooks via DistributedNotificationCenter
  `com.casterly.ledge.debug` object `expand|collapse|peek`
- `NotchController.swift` — per-screen borderless non-activating NSPanel at
  `mainMenu+3`, anchored top-center; animates frame between collapsedSize
  (hardware-notch-hugging or 210×30) and expandedSize; `peek()` = expand + 2.6s
  auto-collapse
- `NotchView.swift` — draws notch silhouette (flared top corners via bezier,
  control points at the corner), hosts horizontal NSStackView rail in NSScrollView,
  drop target (file URLs → promises → raw data), context menus; expanded band shows
  hint text (left) + item/pin count (right). `ShelfItemView` = thumbnail tile:
  click=copy / 2×click=open / ⌥click=OCR-copy-text / drag=NSDraggingSource file-URL /
  dwell 0.45s=full-size NSPopover preview (semitransient, vibrantDark, caption with
  dims+size) / right-click menu (Copy, Copy Text OCR, Open, Pin/Unpin, Share…,
  Reveal, Delete); cyan pin.fill badge top-right when pinned
- `ShelfStore.swift` — singleton; shelf dir `~/Library/Application Support/Ledge/shelf`,
  pinned-first then newest-first, cap 40 (pinned never pruned, Clear keeps pinned),
  pins persist as filenames in UserDefaults `LedgePinned` (stale pins dropped on load),
  off-main thumbnail decode cached on main; `copyText(of:)` = Vision
  VNRecognizeTextRequest off-main → string to pasteboard (self-echo guarded)
- `Watchers.swift` — `ScreenshotWatcher` (DispatchSource on screencapture location dir,
  resolved from `com.apple.screencapture location` pref, default `~/Pictures/Screenshots`)
  + `ClipboardWatcher` (0.6s timer in `.common` mode, raw-image-only, `ignoreChange`
  suppresses self-echo)

## Invariants

- Zero TCC: never watch ~/Desktop; screenshot location stays on a non-protected dir
- Window expand/collapse = frame resize, never a big transparent window (click-through)
- Clipboard writes always go through `ShelfStore.copyToPasteboard` (self-echo guard)
- UI changes: rebuild + kickstart + screencapture-verify (debug hooks above), per
  verify-ui-real-app
