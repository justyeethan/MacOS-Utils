# Tiling window manager plan (AeroSpace-style, vim keys)

Status: plan. The scroll-reversal core in `MacOSUtils/Scroll/` is built; nothing in this document is yet.

## 1. What we're copying from AeroSpace, and why

AeroSpace (nikitabobko/AeroSpace, MIT) is the model. Its main design choices are what make it fast and stable, so we keep them:

| AeroSpace choice | Why it matters | Our version |
|---|---|---|
| **i3-style tree** of containers; windows are leaves | Direction-based focus/move works the same everywhere; no "magic" auto-layout | Same tree, same normalization rules |
| **Emulated workspaces**, not macOS Spaces | Spaces can't be created, switched or assigned to from a public API, and switching animates. AeroSpace parks windows of hidden workspaces in a screen corner instead | Same: hide = move almost fully off-screen |
| **No SIP disabling, no code injection** | Survives macOS updates; no scripting-addition breakage like yabai | Same constraint, hard rule |
| **One private API**: `_AXUIElementGetWindow` (AX element → `CGWindowID`) | AX elements have no stable identity; the CGWindowID does | Same, via `@_silgen_name` |
| **Plain-text config + CLI** | Dotfiles-friendly, scriptable | TOML config later; CLI over a Unix socket later |
| **Thread per app for AX** (open AeroSpace issue #131) | One hung app's AX calls block everything if they share a thread | We build it this way from the start |

The one thing we change: hotkeys go through the input-tap thread we already have for scroll reversal (see §4.1), so one service owns all global input.

## 2. Architecture

```
┌──────────────────────── MacOSUtils.app (unsandboxed, Accessibility-trusted) ───────────────────────┐
│                                                                                                     │
│  Input thread "MacOSUtils.InputTap"         Main actor                         Per-app AX threads   │
│  ┌──────────────────────────┐   commands   ┌──────────────────────────────┐   ┌─────────────────┐   │
│  │ ScrollEventTap (done)    │─────────────▶│ WindowManager                │──▶│ AppAXWorker(pid)│   │
│  │ HotkeyTap (keyDown)      │              │  • Tree model (workspaces)   │◀──│  AXObserver     │   │
│  │  - BindingTable per mode │              │  • Command executor          │   │  AXUIElement IO │   │
│  └──────────────────────────┘              │  • Normalizer                │   └─────────────────┘   │
│                                            │  • Layout engine → frames    │        × N apps        │
│  NSWorkspace / screen notifications ──────▶│  • Refresh loop (coalesced)  │                         │
│                                            └──────────────────────────────┘                         │
│                                                     │                                               │
│                                            SwiftUI menu bar (workspace indicator, settings)         │
└─────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

Threading rules:

- **Input thread** must never block. It matches a key chord against an immutable binding table and posts a `Command` to the main actor. It doesn't touch the tree.
- **Main actor** owns the tree. Every tree operation is cheap in-memory work. It never calls AX directly; it sends requests to app workers and awaits results.
- **AppAXWorker** is one `Thread` with its own run loop per running app. It owns that app's `AXUIElement`s and its `AXObserver` (observer run-loop sources go on this thread). It sets `AXUIElementSetMessagingTimeout` (~1s) so a hung app degrades to "that app's windows don't move" instead of freezing the manager.

### Proposed folder layout

```
MacOSUtils/
  App/            AppModel, menu bar UI
  Scroll/         (done) ScrollEventTap, classifier, transform, IOHID bridge
  Input/          HotkeyTap (joins the scroll tap's thread), KeyChord, BindingTable, Mode
  WM/
    Model/        TreeNode, Container, WindowNode, Workspace, Monitor
    Commands/     Command enum, parser, executor
    Layout/       Normalizer, LayoutEngine (tiles, accordion)
    AX/           AppAXWorker, AXWindow, PrivateAPI (_AXUIElementGetWindow), WindowBackend protocol
    Workspaces/   WorkspaceManager (hide/show), MonitorManager
  Config/         TOML loading, defaults
docs/
```

Keep `WM/Model`, `Commands` and `Layout` free of AppKit and AX imports. They go behind a `WindowBackend` protocol so the whole tiling brain can be unit-tested against a fake backend.

## 3. Data model

```swift
enum Orientation { case horizontal, vertical }        // h = children side by side
enum Layout { case tiles, accordion }
enum Direction { case left, down, up, right }          // h j k l

final class Workspace {                                // root of one tree
    let name: String
    var root: Container                                // always exists, may be empty
    var floating: [WindowNode]
    weak var monitor: Monitor?                         // where it's shown / last shown
    var lastFocused: WindowNode?
}

final class Container {
    var orientation: Orientation
    var layout: Layout
    var children: [Node]
    var weights: [CGFloat]                             // resize ratios, same count as children
    weak var parent: Container?
    var mostRecentChild: Node?                         // used when focus descends into a container
}

final class WindowNode {
    let id: CGWindowID                                 // from _AXUIElementGetWindow
    let pid: pid_t
    weak var parent: Container?
    var lastAppliedFrame: CGRect?                      // skip AX writes when unchanged
    var floatingFrame: CGRect?                         // restored when un-hidden / un-floated
}

enum Node { case container(Container), window(WindowNode) }
```

### Normalization (run after every mutation, like AeroSpace)

1. A container with **one child** is replaced by that child (flatten).
2. A child container with the **same orientation as its parent** is flattened into the parent ("opposite orientation" rule), so the tree alternates h/v and never has redundant nesting.
3. Empty non-root containers are removed.
4. `weights` are renormalized to sum to 1.

These rules are what keep "move left" predictable. Unit-test them before anything else.

## 4. Subsystems

### 4.1 Hotkeys (vim bindings) on the existing input thread

- Add a second active tap on the same thread as `ScrollEventTap` for `keyDown` and `flagsChanged`. (Refactor: pull thread and run-loop management out of `ScrollEventTap` into an `InputThread` that hosts several taps.)
- For each `keyDown`, build a `KeyChord(keyCode, modifiers)`. Look it up in the **current mode's** `BindingTable`. On a match, return `nil` from the callback (swallow the key) and post the command to the main actor. Otherwise pass the event through.
- Use key **codes**, not characters. Option+letter produces dead keys and accents, and layouts differ, so `h` = `kVK_ANSI_H` resolved through the current layout once at config load.
- Separate taps can tell left and right modifiers apart (`NX_DEVICELALTKEYMASK`, etc.), which Carbon `RegisterEventHotKey` can't. AeroSpace issue #28 tracks the same wish.
- **Secure Event Input** (password fields; Terminal's "Secure Keyboard Entry") stops key events reaching taps. Detect it with `IsSecureEventInputEnabled()` and show it in the menu bar icon, so a missed hotkey isn't a mystery. Put hotkey delivery behind a `HotkeyBackend` protocol so a Carbon fallback can be added if this turns out to matter.

**Modes**, as in AeroSpace/i3. `main` is always active. Other modes are entered by a binding and left with `esc`. This gives true vim-style modal editing for windows:

| Mode | Purpose |
|---|---|
| `main` | Global chords with a modifier (below) |
| `window` (entered with `alt-w`) | **Bare** `h j k l` focus, `H J K L` move, `1–9` workspace, `esc`/`enter` leaves. Feels most like vim normal mode |
| `resize` (`alt-r`) | `h/l` shrink/grow width, `j/k` grow/shrink height, `=` balance, `esc` leaves |
| `service` (`alt-shift-;`) | Reload config, reset layout, toggle float, close all but current |

### Default `main` bindings (AeroSpace defaults, extended)

| Chord | Command |
|---|---|
| `alt-h / j / k / l` | `focus left / down / up / right` |
| `alt-shift-h / j / k / l` | `move left / down / up / right` |
| `alt-ctrl-h / j / k / l` | `join-with <dir>` (wrap focused + neighbour in a new container) |
| `alt-1 … alt-9` | `workspace N` |
| `alt-shift-1 … 9` | `move-node-to-workspace N` |
| `alt-tab` | `workspace-back-and-forth` |
| `alt-shift-tab` | `move-workspace-to-monitor next` |
| `alt-/` | `layout tiles horizontal vertical` (toggle orientation) |
| `alt-,` | `layout accordion horizontal vertical` |
| `alt-f` | `fullscreen` (AeroSpace-style: fills the workspace, not native fullscreen) |
| `alt-shift-space` | `layout floating tiling` toggle |
| `alt-minus / alt-equal` | `resize smart -50 / +50` |
| `alt-w`, `alt-r`, `alt-shift-;` | enter `window`, `resize`, `service` mode |

### 4.2 Commands

```swift
enum Command {
    case focus(Direction), move(Direction), joinWith(Direction)
    case workspace(String), moveNodeToWorkspace(String), workspaceBackAndForth
    case moveWorkspaceToMonitor(MonitorTarget)
    case layout([LayoutToggle]), fullscreen, toggleFloating
    case resize(Dimension, delta: CGFloat), balanceSizes
    case mode(String), reloadConfig, close
}
```

The same enum is produced by the binding table, the config parser, and (later) the CLI socket. The executor mutates the tree, runs the normalizer, and schedules a refresh. Commands are pure tree operations, so they're testable without a screen.

**`focus <dir>`** (the core of vim navigation):
1. From the focused window, walk up until reaching an ancestor container whose orientation matches the direction (h/l → horizontal, j/k → vertical) **and** that has a sibling on that side of the path child.
2. Take that sibling. Descend: at each container, pick the child nearest the edge we came from, breaking ties with `mostRecentChild` (i3 behaviour: you return to the window you left).
3. If no ancestor qualifies, try the **monitor** in that direction (its workspace's nearest-edge window). Otherwise do nothing. Wrapping can be a config option.

**`move <dir>`**:
1. If the parent's orientation matches and a sibling exists on that side: swap with it, or if the sibling is a container, insert into it at the near edge.
2. Otherwise move the window up one level and place it beside its old parent on that side, creating a new root container of the right orientation if needed.
3. At the edge of the root, move to the adjacent monitor's workspace.
4. Normalize.

### 4.3 Layout engine

Pure function: `(Workspace, monitorVisibleRect, gaps) -> [CGWindowID: CGRect]`.

- `tiles`: split the rect along the orientation by `weights`, with inner and outer gaps.
- `accordion`: every child gets the full rect, minus an offset padding (default 30px) per position, so the stack edges stay visible.
- `fullscreen` window: the whole visible rect, on top. Siblings keep their frames underneath.
- Floating windows are left alone unless they're off-screen.

Use `NSScreen.visibleFrame` (excludes menu bar and Dock), converted to AX's **top-left origin** global coordinates. AX y-down and AppKit y-up conversion is the most common source of off-by-a-screen bugs. Put it in one helper with tests.

### 4.4 AX layer

- Discover apps: `NSWorkspace.shared.runningApplications` filtered to `.regular` activation policy. Then `didLaunchApplicationNotification` / `didTerminateApplicationNotification` keep the list current. One `AppAXWorker` per pid.
- Per app: `AXUIElementCreateApplication(pid)`, read `kAXWindowsAttribute`, and register an `AXObserver` for `kAXWindowCreatedNotification`, `kAXUIElementDestroyedNotification`, `kAXFocusedWindowChangedNotification`, `kAXWindowMovedNotification`, `kAXWindowResizedNotification`, `kAXWindowMiniaturizedNotification` / `…Deminiaturized`, and `kAXApplicationHidden/Shown`.
- Window ID: `@_silgen_name("_AXUIElementGetWindow") func _AXUIElementGetWindow(_: AXUIElement, _: UnsafeMutablePointer<CGWindowID>) -> AXError`.
- **What to tile:** role `AXWindow` **and** subrole `AXStandardWindow`, and the window has a fullscreen or zoom button. Treat `AXDialog`, `AXFloatingWindow`, `AXSystemDialog`, sheets, popovers and fixed-size windows as floating. Expect app-specific exceptions, which is what `on-window-detected` rules in config are for.
- **Setting a frame:** write size, then position, then size again. macOS clamps windows to screen edges, so a single write can land wrong when moving across monitors. Temporarily set `AXEnhancedUserInterface = false` on the app element during the write. Some apps animate or refuse frame changes while it's on (it's set by VoiceOver and some utilities); restore it afterwards.
- **Focus:** `kAXRaiseAction` on the window, set `kAXMainAttribute = true`, then `NSRunningApplication.activate()`.
- Echo suppression: when *we* move a window, AX sends us `WindowMoved`. Record `lastAppliedFrame` and ignore notifications whose frame matches. A mismatch means the user dragged or resized, which becomes a resize or float decision.

### 4.5 Emulated workspaces and monitors

- Each `Monitor` (from `NSScreen.screens`, keyed by `CGDirectDisplayID`) shows exactly one workspace. Workspaces not shown anywhere are **hidden**.
- **Hide:** move every window of the workspace so only a ~1px sliver sits in the bottom-right corner of its monitor. macOS won't place a window fully off-screen. Save `floatingFrame` for floating windows first.
- **Show:** run layout for the workspace, apply frames, focus `lastFocused`.
- **Crash and quit safety (must ship with workspaces, not after):** on quit, show every window on its monitor. On launch, any window found parked in a corner is pulled back. Otherwise a crash leaves windows "lost" off-screen.
- Mission Control groups the parked windows oddly. AeroSpace's docs suggest turning on "Group windows by application" in Mission Control settings, and we should surface the same tip.
- Listen for `NSApplication.didChangeScreenParametersNotification`. Re-map workspaces to monitors and move workspaces from removed monitors to the main one.

### 4.6 Refresh loop

Every trigger (AX notification, app launch/quit, command, screen change) calls `scheduleRefresh()`, which coalesces into at most one refresh per ~16ms:

1. Ask workers for the current window list per app (cached; only re-query apps that signalled).
2. **Reconcile:** add unknown windows (tile into the focused workspace next to the focused window, or follow a config rule) and drop vanished ones.
3. Normalize every touched workspace.
4. Lay out the visible workspaces → target frames.
5. Diff against `lastAppliedFrame` and send only the changes to the owning workers, in parallel.

## 5. How it ties into the existing scroll code

- `AppModel` already owns the permission flow. The WM needs the same Accessibility trust, so add a `WindowManager` next to `ScrollEventTap`, started from the same `startWhenTrusted`.
- Refactor `ScrollEventTap` into `InputThread` (thread + run loop + tap re-enable) hosting `ScrollTapHandler` and `HotkeyTapHandler`. The `tapDisabledByTimeout` recovery is then shared.
- Optional cross-feature bindings once both exist: `alt` + scroll on the menu-bar indicator cycles workspaces, and `alt-shift` + scroll resizes the focused tile.

## 6. Milestones

| # | Deliverable | Done when |
|---|---|---|
| M0 | ✅ App shell, Accessibility flow, input thread, scroll reversal | Per-device direction works in Finder, Safari, Chrome, Terminal |
| M1 | AX layer: workers, window inventory, IDs, observers; debug list in the menu panel | Opening and closing windows in any app updates the list within 100ms; a hung app doesn't stall others |
| M2 | Tree + normalizer + tiles layout, one monitor, one workspace | New windows auto-tile and closing reflows; normalizer unit tests pass |
| M3 | Hotkey tap, binding table, modes; `focus`, `move`, `join-with`, `layout`, `resize` | Full vim navigation on one screen; keys don't leak into the focused app |
| M4 | Emulated workspaces 1–9, back-and-forth, menu-bar indicator, quit and crash restore | Instant switching; kill -9 then relaunch recovers every window |
| M5 | Multi-monitor: per-monitor workspaces, cross-monitor focus/move, display hot-plug | Unplugging a display loses no windows |
| M6 | TOML config (bindings, gaps, modes, `on-window-detected` float/assign rules), reload | Config edits apply on `service` → reload |
| M7 | CLI (`macosutils focus left`) over a Unix socket, `list-windows` / `list-workspaces` output | Usable from SketchyBar or a shell script |
| M8 | Polish: accordion, fullscreen, mouse-drag-to-reorder, minimized/native-fullscreen handling | Daily-drivable |

## 7. Project and environment requirements

- **App Sandbox off** (done in this commit). Neither modifying event taps nor AX control of other apps works sandboxed, so this can't ship on the Mac App Store. Distribute as a notarized Developer ID app or via Homebrew cask.
- **Stable code signing in development.** Accessibility trust is tied to the signature. Ad-hoc or changing signatures make macOS silently distrust each new build; if permission "stops working", remove and re-add the app in System Settings → Privacy & Security → Accessibility.
- **Dependencies:** a TOML parser via SwiftPM (M6). Nothing else is needed.
- **Licensing:** AeroSpace is MIT and Scroll Reverser is Apache-2.0. This code is an independent implementation of their approaches. If you copy actual source from either, keep their license notices.

## 8. Open decisions

1. **Hotkey backend:** CGEventTap only, or also a Carbon fallback for secure-input situations? Decide after testing M3.
2. **Where new windows go:** next to focused (i3/AeroSpace) or a dwindle-style auto split (HyprSpace fork)? Start with i3 behaviour and keep the insertion policy pluggable.
3. **Config format:** TOML for AeroSpace familiarity (and possibly importing a user's existing `~/.aerospace.toml` bindings), or JSON to avoid a dependency.
