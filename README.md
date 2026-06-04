# ledge

A sleek, Apple-style black notch that lives at the top of every display — and holds your screenshots.

Native AppKit, zero dependencies, zero TCC prompts. One binary, ~700 lines of Swift.

## What it does

- **Notch on every screen** — hugs the hardware notch on the MacBook display (12pt wings), draws its own 210×30 notch top-center on external monitors. Multi-display aware; rebuilds on plug/unplug.
- **Hover → gallery rail** — the notch expands (300ms ease-out) into a horizontal sliding rail of your recent captures.
- **Screenshots land instantly** — ⇧⌘3/4/5 captures are detected the moment the file is written; the notch auto-peeks for 2.6s with the new thumbnail sliding in. Clipboard-only captures (⌃⇧⌘4) and Copy Image from any app are caught too (0.6s poll).
- **Drag out** — drag any thumbnail into Terminal (inserts the path), Finder, Slack, anywhere. Standard file-URL drag.
- **Drag in** — drop images from Finder, browsers (file promises), or raw image data onto the notch; it shelves them *and* puts them on the clipboard.
- **Click to copy** — click a thumbnail → file URL + image data on the clipboard, cyan flash confirms.
- **Right-click** — per-item: Copy / Reveal in Finder / Delete. On the notch: Open Shelf Folder / Clear All / Quit.

## Numbers

- Shelf cap: 40 items (oldest pruned, disk included)
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

## Uninstall

```bash
launchctl bootout gui/$(id -u)/com.casterly.ledge
rm ~/Library/LaunchAgents/com.casterly.ledge.plist
rm -rf ~/Documents/Dev/ledge ~/Library/Application\ Support/Ledge
defaults delete com.apple.screencapture location
defaults delete com.apple.screencapture show-thumbnail
```
