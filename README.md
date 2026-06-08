# ledge — Level Up Edition

A sleek, Apple-style black notch that lives at the top of every display — and holds your screenshots. Now with voice integration, smart search, and AI-powered tagging.

![macOS 12+](https://img.shields.io/badge/macOS-12%2B-black) ![Swift](https://img.shields.io/badge/Swift-5-F05138?logo=swift&logoColor=white) ![v0.2.0-beta](https://img.shields.io/badge/release-v0.2.0--beta-4dd9ff) ![MIT](https://img.shields.io/badge/license-MIT-green)

**Status: live** — running as a LaunchAgent, shelving screenshots + voice commands.
**[→ interactive demo](https://casterlygit.github.io/ledge/)**

Native AppKit, zero dependencies, zero TCC prompts. One binary, ~950 lines of Swift. **Segment 3: Complete.**

## What it does

- **Notch on every screen** — hugs the hardware notch on the MacBook display (12pt wings), draws its own 210×30 notch top-center on external monitors. Multi-display aware; rebuilds on plug/unplug.
- **Hover → gallery rail** — the notch expands (300ms ease-out) into a horizontal sliding rail of your recent captures.
- **Screenshots land instantly** — ⇧⌘3/4/5 captures are detected the moment the file is written; the notch auto-peeks for 2.6s with the new thumbnail sliding in. Clipboard-only captures (⌃⇧⌘4) and Copy Image from any app are caught too (0.6s poll).
- **Drag out** — drag any thumbnail into Terminal (inserts the path), Finder, Slack, anywhere. Standard file-URL drag.
- **Drag in** — drop images from Finder, browsers (file promises), or raw image data onto the notch; it shelves them *and* puts them on the clipboard.
- **Click to copy** — click a thumbnail → file URL + image data on the clipboard, cyan flash confirms.
- **⌥-click to grab text** — Vision OCR runs on the image; recognized text lands on the clipboard. Green flash = got text, red = none found. Screenshot of an error message → paste the actual string.
- **Double-click to open** — full image in Preview (or your default app).
- **Hover preview** — dwell 0.45s on a tile → full-size popover with filename, pixel dimensions, and file size. No more squinting at 104px thumbnails.
- **📌 Pinning** — pin a capture and it sorts first, survives the 40-item prune, and survives Clear All. Pins persist across restarts.
- **Share** — right-click → Share… → AirDrop / Messages / Mail / anything in the system share sheet.
- **Live count** — expanded band shows `N items · M pinned` on the right, interaction hints on the left.
- **Right-click** — per-item: Copy / Copy Text (OCR) / Open / Pin / Share… / Reveal in Finder / Delete. On the notch: Open Shelf Folder / Clear All (keeps pinned) / Quit.

## Level-Up Features (Segment 3)

### Level 1: Voice Integration
- **Dictation status** — when ⌃3 (push-to-talk) or voice input is active, the notch auto-lifts from minimized to visible and shows a spinning "Listening" indicator with cyan text. Smooth 180ms fade animations.
- **Voice input bridge** — `com.casterly.ledge.status` notifications from laptop-dictation trigger the UI state changes. Works with the Caster organism's voice pipeline.
- **Auto-collapse** — status clears (0.6s delay) when voice input ends, notch returns to minimized unless hovered.

### Level 2: Search & Filter
- **Live search field** — when shelf is expanded, a search field appears below the notch strip. Type to instantly filter by filename or text.
- **Filter indicators** — expanded band shows filtered count as "X/Y items" when searching or tag-filtering. Helps you understand how many items match your query.
- **Reset gestures** — clear search box to show all again, or use smart filters (coming from Level 3).

### Level 3: Smart Shelf
- **AI-powered tagging** — `ImageAnalyzer` examines each shelf item and auto-tags it: `screenshot`, `error`, `code`, `chart`, `message`. Tags are cached persistently in UserDefaults.
- **Tag-based filtering** — filter shelf to show only items matching a tag. Compose with search + pinned filters.
- **Voice-triggered smart search** — `ShelfStore.smartFilter()` interprets voice commands like "find errors" (shows only error screens) or "show charts" (filtered to data viz).
- **Quick tag lookup** — `ImageAnalyzer.cachedTag(for:)` and `itemsWithTag(_:)` enable instant tag-based queries without re-analysis.

## Numbers

- Shelf cap: 40 items (oldest unpinned pruned, disk included; pinned never age out)
- OCR: Vision `VNRecognizeTextRequest` accurate mode, off-main — ~2,300 chars off a full-screen capture in one pass
- Thumbnail decode: off-main, ≤380px, cached — hover stays at 60fps with a cold rail
- Watchers: 1 dispatch-source fd on the screenshot dir + 0.6s pasteboard poll (runs in `.common` mode, survives drag loops)
- Panel level: `mainMenu + 3`, joins all Spaces, shows over fullscreen apps

## How it runs

```
~/Documents/Dev/ledge/build.sh          # swiftc → build/Ledge.app (ad-hoc signed)
~/Library/LaunchAgents/com.casterly.ledge.plist   # RunAtLoad, restart-on-crash
```

Logs: `/tmp/com.casterly.ledge.err.log` (NSLog: startup, watch dir, every shelved item).

Shelf storage: `~/Library/Application Support/Ledge/shelf/`

### Zero-TCC screenshot detection

Install pointed `com.apple.screencapture location` at `~/Pictures/Screenshots`
(Desktop is TCC-protected; Pictures is not — no permission prompt, ever) and disabled
the floating-thumbnail delay so captures land in the notch *immediately*. If you set a
custom screenshot location later, ledge reads it from preferences at launch and watches
that directory instead.

### Debug hooks

Headless UI driving via distributed notifications (used for screenshot-verification):

```bash
echo 'import Foundation
DistributedNotificationCenter.default().postNotificationName(
  NSNotification.Name("com.casterly.ledge.debug"), object: "expand",  // expand|collapse|peek
  userInfo: nil, deliverImmediately: true)' | swift -
```

## Architecture — Level-Up Edition

**New files:**
- `ImageAnalyzer.swift` — AI tagging engine with Claude Vision API hook (currently heuristic; ready for API integration)
- `NotchView.swift` — updated with search field, filter UI, status display coordination
- `ShelfStore.swift` — extended with filteredItems, tag filters, smart search

**Key integration points:**
- `NotchController.setStatus(_:)` — routes voice state changes to visual indicators
- `ShelfStore.smartFilter(_:)` — interprets voice commands ("find errors", "show charts", etc.)
- `ImageAnalyzer.analyzeImage(_:completion:)` — off-main image analysis with caching
- `AppDelegate` — listens for `com.casterly.ledge.status` notifications from voice input

## Roadmap

### Planned (v0.2)
- [ ] Claude Vision API integration — replace heuristic tagging with actual image analysis
- [ ] Voice command shortcuts — "find errors", "copy latest", "clear all" via curby-dispatch
- [ ] Collections — group filtered items by auto-detected category or date range
- [ ] Metadata export — save selected items to markdown/HTML
- [ ] Screen-recording (`.mov`) thumbnails via AVFoundation

### Eventual
- [ ] Vertical scroll wheel → horizontal rail scroll
- [ ] Drag-session smoke tests via synthesized CGEvents
- [ ] Multi-select drag (band-select tiles, drag as a group)
- [ ] Shelf sync (iCloud / Caster bus)

## Uninstall

```bash
launchctl bootout gui/$(id -u)/com.casterly.ledge
rm ~/Library/LaunchAgents/com.casterly.ledge.plist
rm -rf ~/Documents/Dev/ledge ~/Library/Application\ Support/Ledge
defaults delete com.apple.screencapture location
defaults delete com.apple.screencapture show-thumbnail
```
