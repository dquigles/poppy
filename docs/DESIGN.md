# Poppy — Design

This file is the source of truth for the implementation. If the design changes, update this file in the same commit.

## 1. Product

Poppy is a native macOS utility. A small Liquid Glass "pill" floats in a screen corner, always on top, on every Space (including other apps' fullscreen Spaces). Clicking it animates it open into a larger glass panel containing a real terminal (PTY) running a configurable CLI agent (default `claude`). It never activates itself, so the app underneath stays frontmost and stays fullscreen. No Dock icon.

## 2. Toolchain and package

- Toolchain: Xcode 26.2, Swift 6.2.3, macOS 26 SDK. Built with SwiftPM (`swift build` / `swift run`), no .xcodeproj. The dev machine is Intel (x86_64).
- `Package.swift`:
  - `swift-tools-version: 6.2`, package name `poppy`.
  - `platforms: [.macOS(.v14)]`.
  - One `.executableTarget(name: "poppy")` at `Sources/poppy/`.
  - `swiftSettings: [.defaultIsolation(MainActor.self)]`. Every type/function not marked otherwise is `@MainActor`. If this setting proves unworkable, remove it, annotate UI types `@MainActor` explicitly, and record the change in PROGRESS.md.
  - Swift language mode 6 (the default for tools 6.2).
  - Dependency, from M5: `.package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.20.0")`, product `SwiftTerm`. Tag `v1.20.0` exists; its APIs were checked (§9).
- Liquid Glass APIs are gated by `if #available(macOS 26, *)`.

### Concurrency rules
- These are `nonisolated`:
  - value types used with Codable (`Config`, `PanelState`), `HotKeyCombo` with its nested `Key` table, `Harness` (§7.11), `AgentProfile` (§9.5), and `AgentStatus` / `StatusHooks` (§9.6), `ChildProcess`, `UsageWindow` / `UsageReport` / `UsageError` and the `ClaudeUsage` / `CodexUsage` fetchers (§9.7; the Claude fetch is `async` on the global executor, the Codex fetch runs in a `Task.detached`, and results are applied on the main actor)
  - `appLog` (§4)
  - the Carbon C handler (§11)
- Code on the main thread that is not statically main-actor (the bodies of `NSAnimationContext` completion handlers, `Timer` block closures, `NotificationCenter` block observers with `queue: .main`, and the Carbon handler) wraps its body in `MainActor.assumeIsolated { … }`. Never capture non-Sendable parameters (raw pointers, `Notification`) inside that closure; extract Sendable values first.
- SwiftTerm has no actor annotations. Its callbacks arrive on `DispatchQueue.main` (the `LocalProcess` default). Import it with `@preconcurrency import SwiftTerm`, and declare the conformance as `extension TerminalSession: @preconcurrency LocalProcessTerminalViewDelegate`.

## 3. File layout and ownership

```
Package.swift
Sources/poppy/
  main.swift                        entry point (or the `poppy` shell command's client, §9.9)
  App/LaunchRequest.swift           LaunchRequest: changes asked for by the shell command or a folder (§9.9)
  App/CommandLineClient.swift       `poppy [options] [directory]`: parses flags, hands a request to the app (§9.9)
  Log.swift                         appLog()
  App/AppDelegate.swift             creates and owns everything; quit/cleanup
  Config/Config.swift               Config (config.json) + PanelState (state.json) load/save
  Window/GlassPanel.swift           NSPanel subclass
  Window/PanelController.swift      state machine, frames, animation, observers, Poppy menu (§7.10)
  Views/GlassBackgroundView.swift   NSGlassEffectView / NSVisualEffectView fallback
  Views/PillView.swift              collapsed content: click vs drag, right-click
  Views/HarnessLogo.swift           Harness detection + logo loading (§7.11)
  Views/ExpandedView.swift          ExpandedView + HeaderView (drag, title) + contentHost
  Terminal/TerminalSession.swift    TerminalSession + PoppyTerminalView
  Terminal/ShellEnvironment.swift   builds executable/args/env for the child (and the agent probe)
  Terminal/AgentCatalog.swift       AgentProfile, the agent list and the installed-CLI probe (§9.5)
  Terminal/AgentStatus.swift        AgentStatus + StatusHooks installers (§9.6)
  Terminal/Attachments.swift        images and files into the agent: paste, drop (§9.10)
  Terminal/ChildProcess.swift       posix_spawn helper for short-lived helpers (the agent probe, Codex usage)
  Usage/UsageMonitor.swift          UsageReport + UsageMonitor: which source, when to fetch, staleness (§9.7)
  Usage/UsageSources.swift          Claude (OAuth endpoint) and Codex (app-server) fetchers (§9.7)
  Views/UsageBar.swift              the expanded view's usage footer (§7.9) and the ring's formatting helpers
  Hotkey/GlobalHotKey.swift         Carbon hotkey wrapper (register/unregister)
  Hotkey/HotKeyCombo.swift          key table: parse, config string, display, validity (§11.1)
  Hotkey/HotKeyManager.swift        owns the hotkey, current combo and recorder (§11)
  Hotkey/HotKeyRecorder.swift       "Set Hotkey" window (§11.2)
Resources/Info.plist                used only by scripts/bundle.sh (not a SwiftPM resource)
Resources/Logos/*.png               harness + Poppy logos, black on transparent (§7.11); src/*.svg are their sources, src/LICENSE-lobe-icons their license
scripts/render-logos.swift          renders Resources/Logos/src/*.svg to the PNGs
scripts/bundle.sh                   builds build/Poppy.app
docs/DESIGN.md, docs/PROGRESS.md
```

Ownership: strong references go downward; back-references are `weak`.
- `AppDelegate` owns `config: Config`, `session: TerminalSession` (from M5), `controller: PanelController`, `hotKeys: HotKeyManager` (from M10; M6–M9 held a `GlobalHotKey` directly), and `statusItem: NSStatusItem` (from M8; the item is removed from the menu bar when deallocated, so it must be retained).
- `PanelController` is `final class PanelController: NSObject`; menu actions are `@objc` methods.
- `PanelController.init(config:session:)` (from M4; M2–M3 use a temporary `init()` with no arguments and a hard-coded title `claude`):
  - It creates and owns the `GlassPanel`, `GlassBackgroundView`, `PillView` and `ExpandedView`.
  - It calls `session.attach(to: expandedView.contentHost)`.
  - `session` is `TerminalSession?`, which is `nil` before M5.
- `PillView` and `HeaderView` have a `weak var controller: PanelController?`. On right-click they call `controller.showContextMenu(event:in:)`.
- `PanelController` owns the `AgentCatalog` (M12, §9.5) and the `UsageMonitor` (M15, §9.7).
- `TerminalSession` owns the current `PoppyTerminalView` and keeps its own `config` copy (M12).
  - It exposes `var focusView: NSView?`, which is the current terminal view. `PanelController` reads it whenever it needs a first responder.
  - Before M5, `PanelController` uses the placeholder text field instead. The placeholder is created only when `session == nil`, so from M5 on it never exists and `focusTarget` is always the terminal.
- `PoppyTerminalView` has a `weak var session: TerminalSession?`.

Files are introduced in the milestone that needs them (§13).

## 4. Entry point and app lifecycle

- `main.swift` is top-level code (main-actor isolated). From M16 it first checks whether the first argument is `--cli`; if so it runs the `poppy` shell command's client instead of the app and exits with its status (§9.9):
  ```swift
  if CommandLine.arguments.dropFirst().first == CommandLineClient.flag {
      exit(CommandLineClient.run(Array(CommandLine.arguments.dropFirst(2))))
  }
  let app = NSApplication.shared
  let appDelegate = AppDelegate()      // global strong ref; app.delegate is weak
  app.delegate = appDelegate
  app.setActivationPolicy(.accessory)
  app.run()
  ```
- No `@main` anywhere. No main menu is created.
- `applicationDidFinishLaunching`:
  1. `appLog("Poppy started (pid N)")`.
  2. Load the config (§8.1). Delete stale request files (`LaunchRequest.removeStaleFiles()`, M16). If requests from the `poppy` command arrived during launch (`pendingRequests`, §9.9), take `command` and `cwd` from them (the last one wins) and save both, so the agent starts there once.
  3. Create the session (M5+): `TerminalSession(config:)`. This only computes the launch spec; the process starts in `attach(to:)`.
  4. Create the controller. It shows the pill with `orderFrontRegardless()`.
  5. Create the `HotKeyManager` (M10+; §11), which registers the hotkey, and set `controller.hotKeys`.
  6. Create the menu bar item (M8+, §7.12).
  7. Apply the pending requests in order (`controller.apply`, M16, §9.9), then clear them.
- `NSApp.activate` and `NSRunningApplication.activate` are **never** called, with one exception: Choose Folder… (M16, §9.8) activates Poppy while the folder picker is open and then gives activation back to the previous app.
- `applicationWillTerminate`: `session?.terminateChild()` (§9.4).
- Quitting: the Poppy menu's Quit (context menu or menu bar item, §7.10) calls `NSApp.terminate(nil)`. Under `swift run`, Ctrl-C in the launching shell also quits (default SIGINT; no handler).

### Logging
`Log.swift`: `nonisolated func appLog(_ message: String)` writes `"[Poppy] " + message + "\n"` as UTF-8 to `FileHandle.standardError`. No os_log.

## 5. The panel (`GlassPanel: NSPanel`)

There is one Poppy panel for the app's whole lifetime. It is never closed, only resized. (From M10 the hotkey recorder, §11.2, is a separate, short-lived `GlassPanel`.)

```swift
super.init(contentRect: rect,
           styleMask: [.borderless, .nonactivatingPanel],
           backing: .buffered, defer: false)
```
The style mask must be passed to `init`. Then:

| Property | Value |
|---|---|
| `level` | `.statusBar` (if the M2 test fails: `.floating`; record in PROGRESS.md) |
| `collectionBehavior` | `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]` |
| `hidesOnDeactivate` | `false` |
| `isFloatingPanel` | `true` |
| `becomesKeyOnlyIfNeeded` | `false` |
| `isOpaque` | `false` |
| `backgroundColor` | `.clear` |
| `hasShadow` | `true`. On macOS 26 the window shadow also draws the bright rim around the glass (verified side by side against Spotlight: without it the glass looks flat). |
| `isMovableByWindowBackground` | `false` |
| `isMovable` | `false` (no system titlebar drag while titled; drags are manual, §7.8–7.9) |
| `animationBehavior` | `.none` |
| `isReleasedWhenClosed` | `false` |

Overrides:
- `var allowsKey = false` (stored). `canBecomeKey` returns `allowsKey`.
- `canBecomeMain` returns `false`.
- `performKeyEquivalent(with:)` (§6.2).
- `sendEvent(_:)` and `ignoreKeys(for:)`: the auto-open key guard (M14, §7.15).

The Poppy panel is shown with `orderFrontRegardless()` only; `makeKeyAndOrderFront` is used only in the expanded state (§6.1). (The hotkey recorder's own `GlassPanel` is covered by §11.2.)

**Titled while expanded.** `titlebarAppearsTransparent = true` and `titleVisibility = .hidden` are set once in `init`. `GlassPanel.setTitledChrome(_:)` adds `[.titled, .fullSizeContentView]` at the start of `expand()`. AppKit recreates the three standard (traffic-light) buttons when a titled window's style mask changes (observed for `.titled` and `.resizable`), so `GlassPanel` overrides `styleMask` with a `didSet` that hides them again after **every** change, whatever made it. It removes them, and `.resizable` (added after the expand animation, §7.13), in the collapse frame-animation completion. `zoom(_:)` is a no-op (§7.13). Reason: as a borderless *key* window on macOS 26, the panel got a square hairline outline along its bounds, outside the rounded glass. A titled window gets a real rounded window shape, so the key outline and shadow follow the glass. This was verified with a scratchpad experiment in three modes: borderless (square), borderless without shadow while key (no rim), and titled (correct). The pill stays borderless, because its shadow follows the capsule's alpha and a titled window's system corner radius wouldn't match the capsule.

**Shadow shape.** `GlassPanel.refreshShadow()` calls `invalidateShadow()` now and again via `DispatchQueue.main.async` (the glass renders its new shape a pass later; a shadow computed too early came out square around the expanded panel). It is called from `becomeKey()`/`resignKey()` overrides (key windows use a stronger shadow), in every frame-animation and fade completion, and after every drag end. The expand/collapse steps in §7.7 that say `invalidateShadow()` mean `refreshShadow()`.

### Observers (in `PanelController`)
These and the three live-resize observers (§7.13) are selector-based (`addObserver(self, selector:…)`), so they unregister automatically; no `deinit` cleanup is needed.
- `NSWorkspace.shared.notificationCenter`, `NSWorkspace.activeSpaceDidChangeNotification`: call `panel.orderFrontRegardless()`. Key status is not changed.
- `NotificationCenter.default`, `NSApplication.didChangeScreenParametersNotification`: re-clamp (§7.4). If `isAnimating`, set `needsReclamp = true` instead; the final completion of expand/collapse (where `isAnimating` becomes false) runs the re-clamp if `needsReclamp`, then clears it.

## 6. States and focus

`PanelController.state: State`, where `enum State { case collapsed, expanded }`, plus `isAnimating: Bool`. The only transitions are `expand()` and `collapse()`. Each is a no-op if already in the target state or while `isAnimating`.

**While `isAnimating`, ignore:**
- all left-mouse handling in `PillView` / `HeaderView` (click, drag)
- clicks outside the panel (the monitor isn't installed while animating; §6.3)
- the hotkey

Right-click menus still work.

### 6.1 Key focus
- **Collapsed:** `allowsKey = false`. The pill never becomes key. `PillView.acceptsFirstMouse(for:)` returns `true`.
- **Expand** (§7.6 sequencing):
  1. Set `allowsKey = true` at the start.
  2. When the frame animation finishes, call `panel.makeFirstResponder(focusTarget)`, then `panel.makeKeyAndOrderFront(nil)` (or only `orderFrontRegardless()` for an unfocused auto-open, §7.15).
     - `focusTarget` is `session?.focusView ?? placeholderField`.
- **Collapse:** before the animation starts:
  1. `panel.makeFirstResponder(nil)`
  2. `allowsKey = false`
  3. `panel.orderOut(nil)`
  4. immediately `panel.orderFrontRegardless()`

  This drops key status so the underlying app's window gets keyboard input again.
  - **Acceptable fallback if M4 shows otherwise:** the user clicks the underlying app to restore typing. Record this as a known issue. Do not call `activate`.
- Clicking another app, the desktop or another menu bar item while expanded collapses the panel (§6.3).
- Switching apps without a click (e.g. ⌘Tab) leaves the panel expanded but not key. Clicking inside it makes it key again, and the hotkey refocuses it (§11).

### 6.2 Key equivalents
The app is never active and has no main menu, so menu key equivalents never fire.

`GlassPanel.performKeyEquivalent(with:)` first returns true for anything while the auto-open key guard is active (§7.15). Otherwise it handles only events where both hold:
- `event.modifierFlags.intersection([.command, .shift, .control, .option]) == [.command]`
- `event.charactersIgnoringModifiers?.lowercased()` is one of:

| Key | Action sent with `NSApp.sendAction(_:to: nil, from: self)` |
|---|---|
| `c` | `#selector(NSText.copy(_:))` |
| `v` | `#selector(NSText.paste(_:))` |
| `a` | `#selector(NSResponder.selectAll(_:))` |

It returns the result of `sendAction`. Everything else, including Cmd-Q and Cmd-W, goes to `super` (so it is not handled; quitting is via the menu). All non-command keys reach the first responder unchanged, so Esc, Ctrl-C and the rest reach the terminal. SwiftTerm's Mac `TerminalView` implements `open func copy(_:)`, `open func paste(_:)` and `override func selectAll(_:)` (checked in v1.20.0 source).

### 6.3 Click outside collapses (M9)
There is no collapse button; the panel collapses on a click outside it, or with the hotkey while it is key (§11). (M9 briefly had a Collapse menu item; the user removed it in M10.)
- `PanelController.clickOutsideMonitor: Any?` holds an `NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .rightMouseDown, .otherMouseDown])` monitor. The handler (called on the main thread) runs `MainActor.assumeIsolated { self?.clickedOutside() }`.
- A global monitor only sees events delivered to **other** apps, so clicks inside the panel, on its right-click menu, or on Poppy's own menu bar item (§7.12) never collapse it. Mouse monitors need no Accessibility permission.
- **Installed** in expand's final fade completion, just before `finishAnimation()`, if the panel is key; otherwise when it first becomes key (M14, §7.15). Clicks during the expand animation are ignored.
- **Removed** at the start of `collapse()`, right after `state = .collapsed`, whatever triggered the collapse.
- `clickedOutside()`: if `state == .expanded && !isAnimating` and `!NSMouseInRect(NSEvent.mouseLocation, panel.frame, false)`, call `collapse()`.
- Left clicks count on **mouse-up**, and not when released over the panel: dragging a file from Finder into the terminal starts with a mouse-down in Finder, and must not collapse the panel before the drop.
- The click itself still goes to the app that was clicked, which takes keyboard focus as usual.

## 7. Geometry, animation, drag

### 7.1 Sizes
| | Size | Corner radius |
|---|---|---|
| Collapsed pill | a circle, diameter 36 / **44** / 56 pt by preset (§7.14; 168 × 44 before M11) | diameter / 2 |
| Expanded panel | **760 × 480** pt by default, user-resizable, min 480 × 300 (§7.13) | 20 |

The screen margin is 16 pt from `visibleFrame`.

### 7.2 Screen selection
`screen(for rect:)` returns, in order:
1. the screen whose `frame` contains the rect's center
2. the screen with the largest intersection with the rect
3. `NSScreen.main`
4. `NSScreen.screens[0]`

Screens are compared by `deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]` (as `NSNumber`), never by object identity.

`screenWithMouse()` = the first screen where `NSMouseInRect(NSEvent.mouseLocation, screen.frame, false)`, else `NSScreen.main`.

### 7.3 Default position
Bottom-right of a screen's `visibleFrame`: pill origin = `(maxX − 16 − pillWidth, minY + 16)`, with `pillWidth` the current diameter (§7.14). At launch the screen is `NSScreen.main`.

### 7.4 Clamping
`clamp(frame, in screen)` shifts the frame so it lies inside `visibleFrame.insetBy(dx: 8, dy: 8)`. Frames are never shrunk: if a frame is larger than that area, it is aligned to the area's top-left corner (`minX`, `maxY`) and allowed to overflow. This is decided **per axis**: an axis that fits is shifted normally; an axis that overflows is aligned (x to `minX`, y so that `maxY` matches). The `ExpandedView` (§7.7) is therefore never clipped by clamping. (Only the expand-time fit, §7.13, ever shrinks it, before clamping.) It is applied:
- **To the computed expanded frame**, using the screen chosen from the pill frame.
- **To the restored pill frame at launch.**
- **On a screen-parameter change:**
  - Collapsed: clamp the pill frame.
  - Expanded: clamp the current expanded frame in `screen(for: currentExpandedFrame)`, then recompute `pillFrame` from it (§7.6).

  If the frame actually changed, save the state (§8.2).

### 7.5 Anchor corner
`anchor: Anchor` is computed at the start of each `expand()`:
- Compare the pill's center with the center of `screen(for: pillFrame).visibleFrame`.
  - The left half gives a left anchor; the right half gives a right anchor.
  - The bottom half gives a bottom anchor; the top half gives a top anchor.
- The anchor is kept until the next expand.

The expanded frame keeps that corner of the pill fixed (bottom-right means `maxX` and `minY` are fixed, top-left means `minX` and `maxY`, and so on). Then it is clamped.

### 7.6 Collapsed frame after moving the expanded panel
`PanelController` stores `pillFrame`. `collapse()` recomputes the target `pillFrame` from the **current** expanded frame, using the stored anchor. For example, with a bottom-right anchor, the pill's `maxX` = the expanded frame's `maxX`, and the pill's `minY` = the expanded frame's `minY`.

### 7.7 View hierarchy and animation
- Hierarchy:
  - `panel.contentView` = `GlassBackgroundView` (autoresizing `[.width, .height]`).
  - Inside `GlassBackgroundView.contentView`:
    - `PillView` fills it (autoresizing `[.width, .height]`).
    - `ExpandedView`.
- `ExpandedView` keeps its own size during every animation and during a live resize, so the terminal is resized only when its size is deliberately set: during and at the end of a user resize (coalesced, §7.13), or, while hidden at the start of an expand, when the saved size doesn't fit the screen. Its size is `expandedSize` (760 × 480 by default).
  - At the start of each expand, its origin is placed so that its anchor corner matches the container's anchor corner.
  - Its `autoresizingMask` is set to keep it attached to that corner:

    | Anchor | Horizontal | Vertical |
    |---|---|---|
    | left | `.maxXMargin` | — |
    | right | `.minXMargin` | — |
    | bottom | — | `.maxYMargin` |
    | top | — | `.minYMargin` |

    Example: bottom-right means origin `(containerWidth − width, 0)` and mask `[.minXMargin, .maxYMargin]`.
  - The window clips it while the window is smaller. When fully expanded, its frame is exactly the container bounds.
- Animation constants:
  - Frame animation: 0.30 s, `CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.2, 1.0)`.
  - Fades: 0.12 s, default timing.
- Frame animation call: `NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.30; ctx.timingFunction = …; panel.animator().setFrame(target, display: true) }, completionHandler: { MainActor.assumeIsolated { … } })`.
- Fades use their own nested `runAnimationGroup` on `view.animator().alphaValue`.

**Expand:**
1. `isAnimating = true`.
2. Compute the anchor, fit the ExpandedView's size to the screen (§7.13), and compute the target frame.
3. Set the glass `cornerRadius = 20`.
4. Hide `PillView` (`alphaValue = 0`, `isHidden = true`).
5. Position `ExpandedView` and set its mask. Set `alphaValue = 0`, `isHidden = false`.
6. Animate the frame. In its completion:
   1. `panel.setResizable(true)` and set `contentMinSize` (§7.13); `invalidateShadow()`.
   2. Focus (§6.1).
   3. Fade `ExpandedView` to 1.
   4. In the fade's completion: install the click-outside monitor if key (§6.3, §7.15), `isAnimating = false` (then retry a pending auto-open), and settle a waiting auto-open whose status moved on (§7.15).

**Collapse:**
1. Return if `panel.inLiveResize` (§7.13). `isAnimating = true`; `panel.setResizable(false)`.
2. Release focus (§6.1).
3. Compute `pillFrame` (§7.6).
4. `ExpandedView.alphaValue = 0`, `isHidden = true`.
5. Animate the frame to `pillFrame`. In its completion:
   1. Set the glass `cornerRadius = pillCornerRadius` (diameter / 2, §7.14).
   2. `invalidateShadow()`.
   3. `PillView.isHidden = false`.
   4. Fade `PillView` to 1.
   5. In the fade's completion, `isAnimating = false`.

The corner radius is set, not animated.

### 7.8 Drag (pill)
In `PillView`, ignored while `isAnimating`:
- **`mouseDown`:** record `startMouse = NSEvent.mouseLocation` and `startOrigin = window.frame.origin`, and set `dragging = false`.
- **`mouseDragged`:**
  - `delta = NSEvent.mouseLocation − startMouse`.
  - If not already dragging and `hypot(delta.x, delta.y) > 3`, set `dragging = true`.
  - While dragging, `window.setFrameOrigin(startOrigin + delta)`.
- **`mouseUp`:**
  - If dragging: clamp in `screen(for: frame)`, update `pillFrame`, save state.
  - Otherwise: `controller.expand()`.
- **`rightMouseDown`:** `controller.showContextMenu(event:in: self)`.

### 7.9 Expanded view
- **`HeaderView`:**
  - The top 28 pt of `ExpandedView`, with the same drag logic, except that `mouseUp` without a drag does nothing.
  - On drag end: clamp, recompute `pillFrame` (§7.6), save state.
  - `acceptsFirstMouse` returns `true`. Right-click shows the context menu.
  - Contents:
    - Centered title label: the working directory's **name** (`lastPathComponent`; `~` for home, `/` for root), since M16 (§9.8; the user asked for no agent name, the pill's logo shows it). The header's tooltip (`setPath(_:)`) is the full `~`-abbreviated path. 12 pt system font, `secondaryLabelColor`, truncating in the middle, at least 16 pt from the edges. `setTitle(_:)` changes it on a directory change (§9.8).
    - No buttons (the collapse button was removed in M9; §6.3). `hitTest` returns the header itself for any point inside it, so the title also drags.
- **`contentHost`** (`NSView`):
  - Its frame is `ExpandedView` bounds minus the header, inset 8 pt on the left, right and bottom (above the usage footer when it's shown). The gap below the header is 0.
  - `wantsLayer = true`, `layer.cornerRadius = 10`, `layer.masksToBounds = true`, no background color.
  - Until M5 it holds the placeholder: an editable `NSTextField` filling its width at the top, with placeholder text "Type here to test focus".
- **`UsageBar`** (M15, §9.7): a 22 pt footer along the bottom (full width, 12 pt side padding, autoresizing `[.width, .maxYMargin]`); `contentHost` then starts at 22 pt instead of 8 pt. `ExpandedView.setUsageVisible(_:)` shows or hides it and moves `contentHost`'s bottom edge (a terminal resize, so it's driven only by the harness and the Show Usage setting, never by fetch results). Contents, left to right, one group per window (short, then long): the window label (`5h`, `7d`, from the window's length), a 48×4 pt capsule meter filled to the **used** fraction (`labelColor` at 0.75 alpha, or `.systemRed` at ≥ 90 % used, over a `labelColor` 0.15 track), and text `"<left>% left · resets in <countdown>"` (11 pt, `secondaryLabelColor`, truncating tail). Countdown: `<1 h` → `"Xm"`, `<48 h` → `"Xh Ym"`, else `"Xd Yh"`; past or missing → no "resets" part. With no report yet it reads `"Usage: loading…"`; when unavailable, `"Usage unavailable"` (the reason in the tooltip). Each group's tooltip: `"<used>% of the <label> limit used, resets <local time>"`. Right-clicks show the context menu; clicks do nothing.

### 7.10 Poppy menu (context menu and menu bar)
`PanelController.makeMenu() -> NSMenu` is the single source of Poppy's menu, used by both the right-click context menu and the menu bar item (§7.12), so future settings appear in both places:
- It builds a new `NSMenu` with `autoenablesItems = false` and `delegate = self` (the controller, an `NSMenuDelegate`), and fills it via `populateMenu(_:)`, which removes all items and adds, in order (separators between the groups), each action item with explicit `target = self`:
  - **"Agent ▸"** (M12): a submenu built by `makeAgentMenu()` (§9.5). Enabled only if `session != nil`.
  - **"Working Directory ▸"** (M16): a submenu built by `makeDirectoryMenu()` (§9.8). Enabled only if `session != nil`.
  - **"Pill Size ▸"** (M13): Small / Medium / Large (§7.14).
  - **"Auto-Open ▸"** (M14): "When Input Is Needed" and "When Done", then a separator and "Focus the Panel"; checkmarks from `config.autoOpenOnInput` / `autoOpenOnDone` / `autoOpenFocus`; `toggleAutoOpen(_:)` (key in `representedObject`) flips the flag and saves it with `Config.saveValue(Bool, forKey:)`. Enabled only if there's a session and `config.statusHooks` (§7.15).
  - **"Show Usage"** (M15): checkmark from `config.showUsage`; `toggleShowUsage` flips it, saves it with `Config.saveValue`, and updates the monitor, footer and ring at once (§9.7).
  - **"Set Hotkey (⌃⌥Space)"** (M10): the current hotkey is shown in the same item, `" (" + hotKeys.current.displayString + ")"`, omitted when there is none. Action `setHotKey` calls `hotKeys?.beginRecording()` (§11.2). Enabled only if `hotKeys?.canRecord == true`.
  - separator
  - **"Restart Agent":** action `restartAgent` calls `session?.restart()`. Enabled only if `session != nil`.
  - separator
  - **"Quit Poppy":** action `quit` calls `NSApp.terminate(nil)`.
- `menuNeedsUpdate(_:)` calls `populateMenu(_:)` again, so the long-lived menu bar copy is rebuilt each time it opens and never shows stale state.
- `PanelController.showContextMenu(event:in:)` shows `makeMenu()` with `NSMenu.popUpContextMenu(menu, with: event, for: view)`.

### 7.11 Pill contents (the harness logo, M11)
- `pillTitle` = `lastPathComponent` of the first whitespace-separated word of `config.command` (for example, `/usr/local/bin/claude --x` becomes `claude`). From M11 it is used only by the expanded header's title (§7.9).
- **`Harness`** (`Views/HarnessLogo.swift`, `nonisolated enum`): `.claude`, `.codex`, `.gemini`, `.opencode`, `.other`, from the command's first word after any leading `NAME=value` words (M14), lowercased (`claude`, `codex`, `gemini`, `opencode`; anything else, including aliases and wrappers like `npx …`, is `.other`). `displayName`: "Claude Code", "Codex", "Gemini CLI", "opencode", "Poppy". Computed from `config.command` at launch, and again by `switchAgent` (§9.5) when the agent changes.
- **The pill** shows no text, only a centered `NSImageView`, 24×24 pt on the default pill (scaled with the pill size, §7.14), `imageScaling = .scaleProportionallyUpOrDown`, `contentTintColor = .labelColor`, showing `HarnessLogo.image(for: harness, points: 24)`. `PillView.init(frame:harness:title:)` calls `update(harness:title:)` (also called on an agent switch, §9.5), which sets the logo, and the tooltip and accessibility label to `displayName`, or `pillTitle` when the harness is `.other` (so `zsh` or `aider` is named, not "Poppy"). It's an accessibility element with role `.button`; `accessibilityPerformPress()` calls `controller.expand()` unless animating.
- **Logos are black-and-white only** (the user's choice in M11: no brand colors). Each is a transparent PNG, black on alpha, used as a template image, so it tints to `labelColor` on the pill (black in light mode, white in dark) and follows the menu bar's appearance.
- **`HarnessLogo.image(for:points:)`** loads `<name>.png` (`claude`, `codex`, `gemini`, `opencode`; `.other`, i.e. unrecognized CLIs and plain shells, uses `poppy`), sets `size` to `points`×`points`, `isTemplate = true`, `accessibilityDescription = displayName`. `HarnessLogo.menuBar(points:)` loads `poppy-menubar.png` the same way (description "Poppy"; M16, replacing `poppy(points:)`). A file that can't be found logs `logo: <name>.png not found in [...]` and falls back to SF Symbol `terminal` (natural size, template).
- **Where the PNGs are loaded from**, first match wins:
  1. `Bundle.main.resourceURL/Logos` (the .app's `Contents/Resources/Logos`, §12);
  2. Debug builds only (`#if DEBUG`): `<repo>/Resources/Logos`, found from `#filePath`, for `swift run` from this checkout. Release builds don't embed the checkout path, and a bundled app missing its Logos folder logs the problem.

  SwiftPM resources (`Bundle.module`) are not used: in a .app they'd need a bundle beside `Contents/`, which breaks code signing.
- **Files:** `Resources/Logos/<name>.png`, 128×128 px RGBA, rendered by `scripts/render-logos.swift` (paths found from `#filePath`, so it runs from anywhere; fails if no SVGs are found) from `Resources/Logos/src/<name>.svg`. The PNGs are committed and `bundle.sh` doesn't re-render them: re-run the script after editing any SVG. The script draws each SVG, then fills black with `.sourceIn` so every covered pixel is pure black at its original alpha.
- **Poppy's own logo** (`src/poppy.svg`, added by the user in M11): a four-petal flower with a stem and leaf, black on transparent, 24×24 viewBox, designed to stay legible at 18 px. Its arcs already have separated flags. It stays the pill's logo for unrecognized CLIs.
- **The menu bar mark** (`src/poppy-menubar.svg`, added by the user in M16): the same flower with round petals (four circles and a center circle, all separate), stem and leaf; circles and plain paths only. Used only for the menu bar icon (§7.12).
- **Sources:** the harness SVGs are the mono marks from lobehub/lobe-icons (`@lobehub/icons-static-svg`, MIT License, Copyright (c) 2023 LobeHub; the same marks platoon vendors). The full license, with a note that the marks remain their owners' trademarks, is `Resources/Logos/src/LICENSE-lobe-icons`, and `bundle.sh` ships it next to the PNGs. CoreSVG can't parse SVG arcs with packed flags (`a14 14 0 01-4 3`, "wrong number of floats"; verified in a scratchpad test), so their path data was normalized to separate the flags (`0 1`). Normalize any new or updated logo the same way before rendering.

- **Usage ring** (M15, §9.7): a `CAShapeLayer` circle just inside the glass edge (inset `lineWidth / 2 + 1.5` pt; `lineWidth` 2.5 pt on the 44 pt pill, scaled with the diameter), starting at 12 o'clock and running clockwise, `strokeEnd` = the **short window's** used fraction, round caps, with **no track** (nothing drawn for the unused part, so it sits directly on the glass) and **no color**: always `labelColor` at 0.75 alpha, never red (the user's choice in M15; the footer meter keeps its red warning). Its CGColor is resolved in `viewDidChangeEffectiveAppearance` inside `performAsCurrentDrawingAppearance` from `labelColor.cgColor.copy(alpha:)`; a stored `withAlphaComponent` color kept the appearance it was first resolved in (the ring stayed white in light mode). The footer's colors are computed on each draw for the same reason. Hidden when there's no current report for the running harness. The tooltip and accessibility label get `" · <used>% of 5h used"` appended (after the status suffix). The logo tint (status) is unaffected.

### 7.12 Menu bar item (M8; icon M11)
- `AppDelegate` creates it after the controller: `NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)`.
- `button.image` = `HarnessLogo.menuBar(points: 18)` (M11; the round-petal mark since M16; §7.11): Poppy's own logo, whatever the harness, so the menu bar item is always recognizably Poppy. It's a template, so it adapts to light and dark menu bars. `button.toolTip = "Poppy"`. It never shows agent status (only the pill does, §7.15).
- If the image has zero size, `button.title = "P"` and a log line, so the item is never invisible.
- `statusItem.menu = controller.makeMenu()` (repopulated on each open, §7.10). Clicking the icon shows the menu; no custom click handling.
- `appLog("status item created")`.
- The accessory policy is unchanged: no Dock icon, and opening the menu does not activate Poppy.

### 7.13 Resizing the expanded panel (M13)
- While expanded the panel is titled (§5). In expand's frame-animation completion, once fully grown (not earlier, so an edge drag can't fight the grow animation), `PanelController` calls `panel.setResizable(true)` and sets `panel.contentMinSize = ExpandedView.minSize` (480 × 300; it limits user resizes only, code-driven frames ignore it). `GlassPanel.setResizable(_:)` inserts or removes `.resizable`. At the start of collapse `PanelController` calls `panel.setResizable(false)` (and `setTitledChrome(false)` also removes `.resizable`). So the system provides edge and corner resizing, cursors included. `isMovable` stays false; moving is still the header drag.
- `GlassPanel.zoom(_:)` is overridden to do nothing, so double-clicking the hidden titlebar area under the header can't resize the panel.
- `PanelController.expandedSize` is the size the user chose; loaded from `state.json` (each dimension at least the minimum), else `ExpandedView.defaultSize`.
- **At expand**, before animating: fit it to the screen, each dimension `max(min(expandedSize, visibleFrame inset by 8), minSize)`, and if that differs from the ExpandedView's current size, `setFrameSize` it (it's hidden, so the terminal's one resize is invisible). `expandedSize` itself isn't changed. `expandedFrame(fromPill:)` and `pinExpandedView` use the ExpandedView's current size.
- **Live resize** (`NSWindow.willStartLiveResizeNotification` / `didResizeNotification` / `didEndLiveResizeNotification` for the panel, selector observers, expanded only). The terminal reflows **while dragging** (the user asked for this in M13), coalesced so the agent isn't sent a resize on every mouse move:
  - All three handlers do nothing unless expanded and not animating.
  - Start: `expandedView.autoresizingMask = [.maxXMargin, .minYMargin]` (pinned top-left, so the header stays at the top).
  - Each `didResize` while `panel.inLiveResize`: if no update is pending, schedule one `liveResizeInterval` (0.05 s) later (`liveResizeUpdatePending`), which, if still expanded and in live resize, sets `expandedView.frame` to the container bounds. So the ExpandedView (header, `contentHost` via autoresizing `[.width, .minYMargin]` / `[.width, .height]`, and the terminal view) follows the window at most ~20 times a second; between updates growing shows a sliver of bare glass and shrinking clips.
  - End (`applyUserResize()`): clamp the panel frame (§7.4) and apply it if it moved; `expandedSize` = the container size; `expandedView.setFrameSize(expandedSize)` (the final size); `pinExpandedView`; `refreshShadow()`; `pillFrame` from the new frame (§7.6); save state; log `expanded size WxH`.
- A `didResize` while expanded, not animating and **not** in live resize (e.g. a macOS window-tiling command) runs `applyUserResize()` at once if the ExpandedView's size differs from the container's.
- `collapse()` does nothing while `panel.inLiveResize`.

### 7.14 Pill size presets (M13)
- `PanelController.pillPresets`: Small 36, Medium 44 (default), Large 56 pt. `pillDiameter` is loaded from `state.json` if it's one of these, else 44. `pillSize` and `pillCornerRadius` (diameter / 2) are computed from it.
- **Logo size:** `PillView.logoSize(forDiameter:)` = `round(diameter × 24 / 44)` (20, 24, 31); `PillView.setDiameter(_:)` updates the logo's width and height constraints. The logo image itself is always requested at 24 pt and scaled by the image view.
- **Menu:** "Pill Size ▸" (§7.10) lists the presets, the current one checked, disabled while animating; `selectPillSize(_:)` (tag = diameter) calls `setPillDiameter(_:)`:
  - Ignored if unchanged or animating. Sets `pillDiameter` and the logo size.
  - Collapsed: the new frame keeps the corner nearest the screen corner (`anchor(for: pillFrame)`, §7.5), is clamped, and applied; `glass.cornerRadius = pillCornerRadius`; `refreshShadow()`; `pillFrame` = it.
  - Expanded: nothing moves; the next collapse uses the new size (`pillFrame(fromExpanded:)` and the collapse completion's corner radius).
  - Save state.

### 7.15 Auto-open (M14)
Driven by status changes (§9.6), in `PanelController.statusChanged(_:)`, which also calls `PillView.setStatus` (logo tint, plus " (working)" / " (needs input)" / " (done)" in the tooltip and accessibility label, so status isn't conveyed by color alone). Only the pill shows status: the menu bar icon never changes color (the user's choice in M14).
- **Arming:** a `.waiting` auto-open collapses only on the **first** status after it, and only if that is `working` (the user answered). Any other status (e.g. a denied prompt ending the turn with `done`) clears `autoOpenedFor`, so a later prompt never collapses the panel. Any status other than the pending one also clears `pendingAutoOpen`.
- **working:** if that first status after a waiting open, expanded and not animating, `collapse()`: focus goes back to the app underneath (like claude-popup's detach hook). Not after a `.done` auto-open, where the user is typing the next prompt in the panel.
- **waiting:** if `config.autoOpenOnInput`, `autoOpen(for: .waiting)`.
- **done:** if expanded and key, `markDoneSeen()`; else if `config.autoOpenOnDone`, `autoOpen(for: .done)`.
- **`autoOpen(for:)`**: while animating, in live resize, or with a mouse button down (`NSEvent.pressedMouseButtons != 0`; a pill drag would keep moving the now-expanded window and save its frame as the pill's), it logs `waiting`, stores `pendingAutoOpen = reason` and returns; `retryPendingAutoOpen()` runs it again from `finishAnimation()`, the end of a live resize, or (mouse down) a 0.25 s re-check, if the session's status still equals the reason. While the hotkey recorder is open (`hotKeys.isRecording`; taking key would close it and lose the recording) it's skipped (logged), not retried.
  - Collapsed: `expand(focus: config.autoOpenFocus)`, then `autoOpenedFor = reason`. In expand's frame completion, right after `makeKeyAndOrderFront`, if `autoOpenedFor != nil`, `panel.ignoreKeys(for: 0.4)`, so the guard starts when the panel actually takes the keyboard. In expand's fade completion, if `autoOpenedFor == .waiting` and the status has already moved on: clear it, and `collapse()` if it's `working` (the user answered during the animation).
  - Expanded but not key: with `autoOpenFocus`, `ignoreKeys(for: 0.4)`, `makeKeyAndOrderFront`, first responder = `focusTarget`; without it, only `orderFrontRegardless()`. `autoOpenedFor` is unchanged.
  - Expanded and key: nothing.
- **`autoOpenedFor`** is cleared at the start of every `expand()` and `collapse()`, so manual opens never auto-collapse.
- **Key guard:** `GlassPanel.ignoreKeys(for:)` sets `ignoreKeysUntil` and `dropRepeats`. While `ignoreKeysUntil` is in the future, `sendEvent` drops `keyDown` events and `performKeyEquivalent` returns true (so ⌘ shortcuts such as ⌘V are swallowed too). After it, `keyDown` auto-repeats (`isARepeat`) are still dropped until a fresh key press or any key-up (a Return held from the previous app would otherwise repeat into the prompt and confirm it). It protects against typing meant for the previous app landing in the agent, e.g. answering a permission prompt with a stray keystroke or paste.
- **"Focus the Panel" off** (`config.autoOpenFocus = false`; the user asked for this in M14): `expand(focus: false)` sets the first responder but calls `orderFrontRegardless()` instead of `makeKeyAndOrderFront`, so the panel appears while typing keeps going to the user's app (no key guard needed). Clicking into the panel, or the hotkey (§11, "expanded and not key"), focuses it.
  - The click-outside monitor (§6.3) is installed in expand's fade completion only if the panel is key; otherwise when it first becomes key (`panelDidBecomeKey`, if expanded and not animating; installing is idempotent). Without this, the user's next click in their own app would collapse the unfocused panel at once. So an unfocused auto-open stays until the user clicks in and then out, presses the hotkey, or (after a `.waiting` open) the agent is working again.
- **"Done" seen:** `NSWindow.didBecomeKeyNotification` for the panel calls `session.markDoneSeen()` (and installs the click-outside monitor if expanded and not animating), however it became key (expand, the hotkey, an auto-open, a click into it).
- **Logging** (added while debugging the first M14 test, where the option simply wasn't on): `auto-open: <key> = <bool>` on a toggle (and `not saved; it applies until Poppy quits` if saving fails); `auto-open: off for input` / `off for done` when a status arrives with the option off; `auto-open: expanding` / `focusing` / `already focused`, or `skipped (…)`.

## 8. Configuration and state

The directory is `~/.config/poppy/`, created with intermediate directories if missing. Both types are `nonisolated struct … : Codable, Sendable`.

### 8.1 `Config` (`config.json`, user-edited, read at launch only; introduced in M4; Poppy writes only `hotkey` (M10), `command` (M12), `autoOpenOnInput`, `autoOpenOnDone`, `autoOpenFocus` (M14), `showUsage` (M15), and `cwd` (M16))
```json
{ "command": "claude", "cwd": "~", "hotkey": "ctrl+opt+space" }
```
Flags (M14; a missing or wrongly typed value falls back to the default, never failing the file): `"statusHooks": true` (install status hooks, §9.6; false disables them and Auto-Open), `"autoOpenOnInput": false`, `"autoOpenOnDone": false`, `"autoOpenFocus": true` (§7.15; the Auto-Open menu writes these three; `statusHooks` is user-written only). `"showUsage": true` (M15, §9.7; written by the Show Usage menu item). The defaults file written on first launch contains these flags too.

Optional, user-written only (M12): `"agents": [{ "name": "Claude (skip perms)", "command": "claude --dangerously-skip-permissions" }]`, extra entries for the Agent submenu (§9.5). It's `var agents: [AgentProfile]?`; the synthesized encoder omits it when nil, so the defaults file doesn't contain it. Decoding it can't fail the whole file: if it doesn't decode (e.g. an entry without `name`), log `config.json "agents" is invalid, ignoring it` and use nil; entries whose `name` or `command` is blank after trimming are dropped.

**Decoding**
- A hand-written `init(from:)` uses `decodeIfPresent` for each key, falling back to the defaults above. Unknown keys are ignored.

**Saving one key** (`static func saveValue(_ value: Any, forKey key: String) -> Bool`, any JSON value; `saveHotkey(_:)` (M10) calls it with `"hotkey"`, the agent switch (M12, §9.5) with `"command"`, and `toggleAutoOpen` (M14) with the autoOpen flags; a value that isn't valid JSON is refused with a log line, never an exception)
- Read config.json with `JSONSerialization` as a `[String: Any]`, set only `key`, and write it back (pretty-printed, sorted keys, unescaped slashes, atomic). Every other key and value, including unknown keys, is kept as written; the `POPPY_COMMAND` override is never written.
- The live copies of the config are `PanelController.config` (its `command` changes on an agent switch, §9.5) and `TerminalSession`'s own `config`. `AppDelegate.config` is not updated after launch, and nothing reads it after launch.
- Logs `saved <key> <value> to <path>`, or the failure.
- If the file is missing, write `{"<key>": …}` alone (the other keys fall back to defaults on load).
- If the file exists but can't be read or isn't a JSON object: log it, don't touch the file, return false.

**Load rules**
- **File missing:** write the defaults (pretty-printed, sorted keys) and use them.
- **File exists but doesn't parse:** `appLog` the error and use the defaults. The file is **not** overwritten.

**Field rules**
- `POPPY_COMMAND` env var: if set and non-empty, it replaces `command`.
- If `command` (after the override) is empty or only whitespace: log it and use `claude`.
- `cwd` (written by a directory change, §9.8, as `Config.abbreviate(path)`: the home directory as `~`):
  - `"~"` becomes the home directory, and a prefix of `"~/"` becomes home + the rest. Nothing else is expanded.
  - If the result isn't an existing directory, log it and use the home directory.
- `command` is a shell command string (§9.2).

### 8.2 `PanelState` (`state.json`, app-written; `recentDirectories: [String]?` added in M16, §9.8)
```json
{ "pillOrigin": { "x": 1200, "y": 16 }, "pillDiameter": 44, "expandedSize": { "width": 760, "height": 480 } }
```
- `pillDiameter: Double?` (M13, §7.14) and `expandedSize: SavedSize?` (M13, §7.13; `nonisolated struct SavedSize: Codable, Sendable { var width: Double; var height: Double }`) are optional, so older files still load; nil means the default. `saveState()` always writes all three.
- `pillOrigin` is a `nonisolated struct SavedPoint: Codable, Sendable { var x: Double; var y: Double }` (not `CGPoint`, whose Codable form is an array).
- **Saved after:**
  - every drag end (pill or header)
  - a hotkey screen move (§11)
  - a screen-change clamp that moved the frame
  - the end of a live resize (§7.13) and a pill size change (§7.14)

  The saved origin is always the pill origin (`pillFrame.origin`, for the current diameter); `pillDiameter` and `expandedSize` are the current values.
- **At launch:**
  - If the file is present and a `pillSize` rect (the loaded diameter) at that origin intersects any screen's `visibleFrame`, use it, clamped in `screen(for:)`.
  - Otherwise, use the default position (§7.3).
- Read and write failures are logged and otherwise ignored.

## 9. Terminal (M5)

SwiftTerm v1.20.0 APIs (checked in source):
- `open class LocalProcessTerminalView`
- `open func send(source: TerminalView, data: ArraySlice<UInt8>)`
- `startProcess(executable:args:environment:execName:currentDirectory:)`
- `public internal(set) var process: LocalProcess!`, with `process.shellPid: pid_t` and `process.running: Bool`
- `nativeBackgroundColor`, `nativeForegroundColor` and `backgroundOpacity`
- `processDelegate: LocalProcessTerminalViewDelegate?`

Callbacks arrive on the main queue.

### 9.1 View
`TerminalSession` owns one `PoppyTerminalView: LocalProcessTerminalView` at a time and is its `processDelegate`. It implements all four protocol methods:

| Method | Behavior |
|---|---|
| `sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int)` | `appLog("terminal size \(cols)x\(rows)")` |
| `setTerminalTitle(source: LocalProcessTerminalView, title: String)` | no-op |
| `hostCurrentDirectoryUpdate(source: TerminalView, directory: String?)` | no-op |
| `processTerminated(source: TerminalView, exitCode: Int32?)` | see §9.3 |

Each callback returns early if `source !== currentView`.

**`init(config: Config)`** keeps its own copy of `config`, computes the launch spec (executable, args, env, cwd; §9.2) and stores it; `restart()` recomputes it (re-readying the status hooks, §9.6), so `switchTo(command:directory:)` (§9.5, §9.8) only sets the command and directory and restarts.

**`attach(to host: NSView)`**
- Stores `host` (weak).
- Creates the view with `frame = host.bounds` and `autoresizingMask = [.width, .height]`.
- Adds it to `host` and starts the process.
- Called once by `PanelController.init`, so the agent starts at app launch, not at first expand.
- `host` follows the ExpandedView's size, which changes only deliberately (§7.7, §7.13), so the terminal follows user resizes (at most ~20 times a second while dragging) and never resizes during animations.

**View configuration**
- `font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)`
- `nativeForegroundColor = NSColor(white: 0.92, alpha: 1)`
- `nativeBackgroundColor = NSColor(white: 0.05, alpha: 1)`
- `backgroundOpacity = 0.80`: only the default background is translucent, so the glass shows through behind the text.
- Do not enable SwiftTerm's Metal renderer (it's off by default).
- Hide the scroller: SwiftTerm's `NSScroller` is a private subview, so set `isHidden = true` on every `NSScroller` in `view.subviews`, then call `view.setFrameSize(host.bounds.size)` before `startProcess` so the columns are re-fitted (SwiftTerm reserves no scroller width when it's hidden and never un-hides it; checked in v1.20.0). Trackpad scrollback still works.

### 9.1a Command-key line editing
SwiftTerm routes Command-key presses through `interpretKeyEvents` and ignores the resulting text-editing commands. Its `keyDown` is `public`, not `open`, so `PoppyTerminalView.performKeyEquivalent` (which SwiftTerm doesn't override, and which AppKit calls before `keyDown` for Command keys) intercepts key-down events, only while the view is first responder, whose modifiers (among command/shift/control/option) are exactly `[.command]` and sends these bytes through `send(source:data:)`, matching Ghostty's defaults: ⌘⌫ (keyCode 51) → `0x15` (^U), ⌘← (123) → `0x01` (^A), ⌘→ (124) → `0x05` (^E). ⌥-arrows and ⌥⌫ already work through SwiftTerm's option-as-meta handling.

### 9.2 Spawning (`ShellEnvironment`, `nonisolated enum` with static functions)
- **`executable`:** `$SHELL` from `ProcessInfo.processInfo.environment` if it's an absolute path and `FileManager.isExecutableFile(atPath:)` is true. Otherwise `/bin/zsh`.
- **`args`:** `["-l", "-i", "-c", command]`, **no `exec`**. With `-i`, `.zshrc` is sourced before the `-c` string is parsed, so aliases and shell functions (e.g. `alias claude=~/.claude/local/claude`) work, as do compound commands. The shell stays as the agent's parent; §9.4 signals the whole process group.
- **`execName`:** `nil`.
- **`currentDirectory`:** the resolved `cwd` (§8.1).
- **Environment**, sent as `["KEY=VALUE"]`. Start from `ProcessInfo.processInfo.environment`, then:
  - Always set `TERM=xterm-256color`, `COLORTERM=truecolor`, `TERM_PROGRAM=Poppy`, and `SHELL=<executable>`.
  - Set `LANG=en_US.UTF-8` only if `LANG` is unset or empty.
  - Set `HOME` (`NSHomeDirectory()`), `USER` and `LOGNAME` (`NSUserName()`) each only if unset or empty.
  - `POPPY_STATUS_FILE` is added per start by `TerminalSession` (§9.6), not here.
  - Remove `POPPY_COMMAND`, `TERM_PROGRAM_VERSION`, `TERM_SESSION_ID`, `CLAUDECODE` and `CLAUDE_CODE_ENTRYPOINT` (the launching terminal's identity, and a parent Claude Code session when started via `swift run` from one).

### 9.3 Exit and restart
- **`processTerminated`:**
  - Set `exited = true`; stop status polling and set `idle` (§9.6).
  - Feed this into the terminal: `currentView.feed(text: "\r\n[Poppy] process exited (\(desc)). Press Enter to restart.\r\n")`, where `desc` is `code N` or `signal N`. SwiftTerm passes the **raw `waitpid` status** as `exitCode` (checked in v1.20.0: exit 3 arrives as 768), so decode it: `status & 0x7f == 0` means exited with code `(status >> 8) & 0xff`, otherwise it was killed by signal `status & 0x7f`. A nil `exitCode` is reported as `signal`.
- **`PoppyTerminalView.send(source:data:)`** (the outgoing path: keystrokes and terminal-generated replies):
  - If `session?.exited == true`: drop the data. If it contains byte 13, defer with `DispatchQueue.main.async` (`restart()` removes this very view, which is still on the stack in `keyDown`), and inside the block restart only if `session.exited` is still true and `session.focusView === self` (so repeated Enters can't kill the fresh agent).
  - Otherwise, call `super`.
- **`restart()`** (doesn't wait for the old process):
  1. `terminateChild()`.
  2. Remove the old view from `host`.
  3. Create and start a new view (same as `attach`), set `exited = false`.
  4. Call `onViewReplaced?()`, a closure set by `PanelController`. If the panel is expanded, it makes `session.focusView` the first responder.

### 9.4 Terminating the child
`terminateChild()`, when `currentView.process.running` and `shellPid > 0`:
1. `kill(-shellPid, SIGHUP)`. The shell leads its own group after `forkpty`; with `-i` the agent may be in a separate job group, but it still gets SIGHUP when the shell (the pty's session leader) exits.
2. Only if that returns −1: `kill(shellPid, SIGHUP)`.

It's called from `restart()` and `applicationWillTerminate`, and first removes the status file (§9.6). In `restart()` only, after signalling, reap the old child on a global queue: poll `waitpid(pid, &st, WNOHANG)` every 50 ms for up to 1 s (stop on any non-zero result, including -1/ECHILD if SwiftTerm already reaped it); if it's still alive, `kill(-pid, SIGKILL)`, `kill(pid, SIGKILL)`, then a blocking `waitpid`.

### 9.5 Switching agents (M12)
Chosen from the Poppy menu's **Agent ▸** submenu (§7.10). The conversation is **not** carried over: the old agent is ended and the new one starts fresh (carrying context over may come later).

**`AgentProfile`** (`Terminal/AgentCatalog.swift`, `nonisolated struct … Codable, Sendable, Equatable`): `name`, `command`, and `probeWord: String?`, the word checked with `command -v`: the command's first word after any leading `NAME=value` assignments, with a leading `~/` expanded to the home directory. Nil (can't tell, treated as installed, not probed) for an empty command or a word containing a quote, `$`, backtick or backslash.

**`AgentCatalog`** (owned by `PanelController`):
- `builtIns`: Claude Code (`claude`), Codex (`codex`), Gemini CLI (`gemini`), opencode (`opencode`).
- `AgentCatalog.init(launchCommand:)` keeps the command Poppy launched with (`PanelController.init` passes `config.command`).
- `profiles(for: config)`: the built-ins, then `config.agents` in order, skipping any whose command equals one already listed (`same(_:_:)`: equal after trimming spaces). Then the current command and the launch command, each if not already listed, are inserted **first** (current before launch) as `AgentProfile(name: <its pillTitle>, command:)`. So the running agent is always listed and checked, and a custom launch command (e.g. `aider`) stays available after switching away from it.
- **Installed check:** `refreshIfNeeded(profiles)` (called from `PanelController.init` and each time the menu is built) runs a background probe of the profiles' `probeWord`s if none has run, the last is over 60 s old, or there are words not yet probed (and none is already running, and there's at least one word). `ShellEnvironment.probeSpec(script:)` gives the agent's own shell, `-l -i -c`, environment and home as working directory, so PATH, aliases and functions match what the agent would see. The script loops over the single-quoted words: `command -v "$c" >/dev/null 2>&1 && printf 'POPPY_AGENT:%s\n' "$c"`; only lines with that marker count, so dotfile output is ignored. A result shows the next time the menu opens; on success, log `agents installed: …`; a failed or timed-out probe leaves the previous result unchanged.
  - **Running the probe** (`runProbe`, on a global queue): `posix_spawn` with `POSIX_SPAWN_SETSID` (its own session, so no controlling terminal: under `swift run` it can't print to, or stop, the launching terminal) and `POSIX_SPAWN_CLOEXEC_DEFAULT` (no inherited descriptors, e.g. the agent's pty); stdin and stderr `/dev/null`, stdout a pipe; `chdir` via `posix_spawn_file_actions_addchdir_np`.
  - It reads the pipe non-blocking (`poll`, 100 ms) **until the shell exits** (`waitpid` `WNOHANG`), then drains once more; it doesn't wait for EOF, since a background job started by the dotfiles may keep the pipe open (verified with a test shell that leaves `sleep 30` running). A shell killed by a signal counts as a failure.
  - After 5 s: log `agent probe timed out`, `SIGKILL` the process group (`kill(-pid)`) and the shell (interactive shells ignore SIGTERM), reap it, and fail (verified with a test shell that ignores SIGTERM).
  - `isInstalled(profile)`: nil if the profile has no `probeWord` or no successful probe has included it (both treated as installed), else true/false.

**The submenu** (`makeAgentMenu()`, rebuilt with the menu each time it opens): stores the list in `menuAgents`, then one item per profile: title `name`, or `name + " (not installed)"`; `image` = `HarnessLogo.image(for: Harness(command:), points: 16)` (the Poppy flower for unrecognized commands); `state = .on` for the running command; `tag` = index; action `selectAgent(_:)`. Disabled if not installed, unless it's the running one.

**`switchAgent(to:)`** (`selectAgent` looks the profile up by tag):
1. Return if there's no session or the profile's command is the running one (use Restart Agent to restart).
2. `changeAgent(command: profile.command, directory: workingDirectory)` (M16, §9.8): `config.command = …` (`PanelController.config` is a `var`), `pillView.update(harness:title:)` (new logo, tooltip and accessibility label), `Config.saveValue(command, forKey: "command")` (so the next launch starts it; a `POPPY_COMMAND` env var still overrides it at launch), then `session.switchTo(command:directory:)`: sets its own `config.command`/`cwd`, then `restart()` (§9.3), which recomputes and logs the `LaunchSpec`, ends the old agent, starts a new view and refocuses it if expanded; then `usage.setCommand` (§9.7). (Before M16: `session.switchCommand(to:)` and the header showed `pillTitle`.)

### 9.6 Agent status hooks (M14)
Modeled on platoon's status feed and claude-popup's hooks. **`AgentStatus`** (`Terminal/AgentStatus.swift`): `idle`, `working`, `waiting` (blocked, needs the user), `done` (finished a turn). `tint` (pill logo only): nil (normal), `.systemBlue`, `.systemOrange`, `.systemGreen`.

**Channel.** Each agent start gets a fresh file `~/.config/poppy/run/status-<poppy pid>-<generation>` (created empty), passed to the child as `POPPY_STATUS_FILE` (appended to the launch environment in `startNewView`). A hook writes one word into it. The file is new per start, so an old agent that's still dying can't report into the new one. `terminateChild` removes it; at launch, `status-*` files whose Poppy pid is no longer running are deleted.
- **Polling** (`TerminalSession`): a 0.25 s `Timer` added to the main run loop in `.common` modes (so it keeps running during menus and live resize). It acts only when the file's modification date differs from the last one acted on (a hook rewriting the same word is still a new report), reads the word, ignores anything that isn't a status (empty, mid-write), and sets it. The file is never truncated by Poppy, so no report can be lost between reading and clearing.
- `setStatus` logs `status: a -> b` and calls `onStatusChange` only on a change. A new start sets `idle` (before creating the file, so even if that fails the old agent's status isn't left showing). When the agent exits (`processTerminated`), polling stops (so a report written just before exit can't change the status, or auto-open, for a dead agent; the file stays until the next start or quit) and the status is set to `idle`. `markDoneSeen()` turns `done` into `idle` locally.

**Hook command** (every agent): `[ -f "$POPPY_STATUS_FILE" ] && printf %s <status> > "$POPPY_STATUS_FILE"; exit 0`. It's a no-op outside Poppy (unset variable), so global entries are inert for other sessions, and it only writes to an existing file, so a dying agent can't recreate a file Poppy removed.
- **Limitations:** every descendant of the agent inherits `POPPY_STATUS_FILE`, so e.g. `codex exec` or `gemini -p` run from Claude's Bash tool can report `done` mid-turn through their global hooks. An Esc interrupt (and usually a denied permission) fires no Claude `Stop`, so the pill can stay blue or orange until the next prompt. `POPPY_STATUS_FILE` is also the marker for recognizing Poppy's entries.

**Installing** (`StatusHooks.prepare(command:)`, called by `TerminalSession` when computing the launch spec: at init, on each agent switch, and on each restart; only if `config.statusHooks`). With `statusHooks` false there is also no status file, no `POPPY_STATUS_FILE` and no polling, so no status or auto-open, even if old entries remain in other tools' configs. So a tool's config is only touched when that agent is actually started in Poppy. It returns the command to run:
- **Claude:** writes `~/.config/poppy/claude-hooks.json` and returns the command with `--settings '<path>'` inserted **right after the executable word** (`insertAfterExecutable`: after any leading `NAME=value` words (`Harness(command:)` also skips them, so `FOO=1 claude` is Claude), and before a shell operator glued to the word, so `claude; exec zsh`, `claude|tee log`, `claude -- "prompt"` and `claude # note` all pass it to claude; tested). Claude layers it over the user's settings; nothing global is touched. If the command already contains `--settings`, that's logged (the user's later flag may override Poppy's, disabling status). Events: SessionStart with matcher `startup|resume|clear` → idle (not `compact`, which fires mid-turn after auto-compaction); UserPromptSubmit, PreToolUse, PostToolUse → working; Notification with matcher `permission_prompt` → waiting (not `idle_prompt`, Claude's ~60 s idle notice); PermissionRequest → waiting; Stop → done. Other events use matcher `.*`.
- **Codex:** merges into `$CODEX_HOME/hooks.json` (default `~/.codex`): SessionStart → idle; UserPromptSubmit, PreToolUse, PostToolUse → working (PostToolUse, found in the installed Codex binary, reports working again after the user approves a tool); PermissionRequest → waiting; Stop → done. Codex asks the user to approve new hooks once (it records approval per entry position).
- **Gemini CLI:** merges into `~/.gemini/settings.json` (entries for BeforeTool/AfterTool get `matcher: ".*"`; the others get **no** matcher, which matches all; Gemini treats `matcher` as a regex only for tool events, and other tools' Gemini hooks on this machine omit it): SessionStart → idle; BeforeAgent, BeforeTool, AfterTool → working; Notification → waiting; AfterAgent → done.
- **opencode:** writes the Poppy-owned plugin `$XDG_CONFIG_HOME/opencode/plugins/poppy-status.ts` (default `~/.config`; only if its content differs): `session.created` → idle and `session.idle` → done for the root session only (a `session.created` with `info.parentID` is a subagent and ignored; the first root's id is remembered and other sessions' `session.idle` is ignored, so a finishing subagent doesn't report done mid-turn), `chat.message`, `tool.execute.before` and `tool.execute.after` → working (after runs once an approved tool finishes), `permission.ask` and the `permission.updated` / `permission.asked` events → waiting; it returns `{}` unless `POPPY_STATUS_FILE` is set.
- **`.other`:** nothing (the file and variable still exist, so a custom command can report).
- **Environment:** `CODEX_HOME` and `XDG_CONFIG_HOME` are read from Poppy's own environment (empty counts as unset, a leading `~` is expanded). A value exported only in the shell's dotfiles isn't seen by a Finder-launched Poppy, so hooks would go to the default location.
- **Merging** (Codex, Gemini): **additive only**, platoon's rule. For each event, skip it if any entry already contains the marker; otherwise append `{"matcher": ".*", "hooks": [{"type": "command", "command": …}]}` (without `matcher` for Gemini's non-tool events). Nothing is removed or reordered (Codex's approvals are per position), and the values of all other keys are kept, but the file is re-serialized (pretty-printed, sorted keys; noisy in a dotfiles repo). If the file isn't a JSON object (including JSONC with comments), or `hooks`/an event has an unexpected shape, nothing is written (logged). Written atomically **through symlinks** (`resolvingSymlinksInPath`, for dotfile managers), keeping the file's POSIX permissions.
- **Upgrades:** an event with any entry containing the marker counts as installed, so a future change to the command text wouldn't update existing entries. Not needed yet; a versioned marker would be the way. Idempotent (verified on a copy of a real `hooks.json`: each event gained exactly one entry, the existing ones were unchanged, and a second run added nothing).

### 9.7 Usage meters (M15)
Modeled on platoon (`usage.rs`, `codex_usage.rs`, `UsageFooter.tsx`). Shows how much of the running agent's subscription limits is left: the footer (§7.9) shows both windows, the pill ring (§7.11) the short (5-hour) one. Only Claude and Codex have a source; for Gemini, opencode and `.other` there's no footer and no ring.

**Model** (`nonisolated struct`s): `UsageWindow { usedPercent: Double (0–100, clamped), resetsAt: Date?, minutes: Int? }` with `label` (`minutes` 300 → `"5h"`, 10080 → `"7d"`, other → `"<h>h"` / `"<d>d"`, nil → the slot's default: `"5h"` short, `"7d"` long); `UsageReport { short: UsageWindow?, long: UsageWindow?, fetchedAt: Date }`. A report is **stale** (due for a fetch) once any window's `resetsAt` has passed, or 15 min after `fetchedAt`. What's shown is `current(at:)`: windows whose `resetsAt` has passed are dropped (their numbers no longer apply, platoon's rule) and the rest kept; nil after 15 min or when no window is left. A successful fetch with nothing current shows "unavailable" with the reason "no current usage reported" (review fix: a window reported as already reset must not hide the other one or read as "loading" forever).

**Claude** (`ClaudeUsage.fetch() async throws -> UsageReport`, off the main actor):
- `fetch()` is `@concurrent` (the token read blocks, so never on the main actor).
- Token: `/usr/bin/security find-generic-password -s "Claude Code-credentials" -w` (the Keychain item Claude Code maintains; run as a subprocess with a 60 s timeout, time to answer an access prompt; stderr discarded). Exit 44 (item not found) falls back to `~/.claude/.credentials.json`; any other failure (denied, cancelled, timed out) is `keychainDenied`, which is **not retried** (`nextAllowed = .distantFuture`) until Show Usage is turned off and on or Poppy relaunches, so the prompt never keeps coming back. JSON `claudeAiOauth.accessToken` (or top-level `accessToken`). Read on every fetch (Claude rotates it), never stored or logged. If `expiresAt` (ms) has passed, fail with "token expired" without calling the network (Claude refreshes it the next time it runs). The first read may make macOS ask to allow Keychain access.
- `GET https://api.anthropic.com/api/oauth/usage` with `Authorization: Bearer <token>`, `anthropic-beta: oauth-2025-04-20`, `User-Agent: claude-code/2.1.0` (the endpoint rate-limits unknown agents harder; platoon does the same), 15 s timeout, ephemeral `URLSession` (no cookies/cache). Undocumented endpoint: every field is optional, and a changed shape degrades to "unavailable".
- `five_hour` → short, `seven_day` → long: `utilization` → `usedPercent`, `resets_at` (ISO 8601, with fractional seconds) → `resetsAt`, `minutes` 300 / 10080. HTTP 429 → `rateLimited`; other non-200 → failure with the code.

**Codex** (`CodexUsage.fetch(command:)`): runs `<prefix> app-server` through the login shell (`ShellEnvironment.probeSpec`, so PATH/nvm match the agent), where `<prefix>` is the running command up to and including its executable word (`StatusHooks.executablePrefix`, shared with `insertAfterExecutable`; keeps `CODEX_HOME=…` assignments). Via `ChildProcess.run` (new session, 10 s timeout, then SIGKILL to the group): writes three JSON-RPC lines to stdin — `initialize` (id 0, clientInfo `poppy`), `initialized`, `account/rateLimits/read` (id 1) — and stops (killing the group) as soon as a stdout line parses as JSON with `"id": 1`. `result.rateLimits.primary` → short, `.secondary` → long (`usedPercent`, `resetsAt` unix seconds, `windowDurationMins`); an `error` (e.g. API-key login: "chatgpt authentication required") → failure with its message.

**`ChildProcess.run(_:label:input:timeout:until:)`** (`nonisolated`; M15, extracted from the M12 probe): posix_spawn with `SETSID | CLOEXEC_DEFAULT`; its pipes are `FD_CLOEXEC` in Poppy (so an agent started meanwhile doesn't inherit them); stdin `/dev/null` or a pipe holding `input` (`F_SETNOSIGPIPE`, kept open until the end), stdout a pipe, stderr `/dev/null`; polls stdout every 100 ms; returns the output when `until(output)` is true (then closes stdin, gives the process up to 1 s to exit on its own, e.g. so Codex can finish writing its files, then SIGKILLs the group) or when the process exits (status included); nil on spawn failure or timeout (logged with `label`). `waitpid` is retried on EINTR. `AgentCatalog.runProbe` now uses it (same behavior as §9.5).

**`UsageMonitor`** (main actor, owned by `PanelController`):
- `harness` (set at init and by `switchAgent`), `enabled` (`config.showUsage`), `onChange: (UsageReport?, String?) -> Void` (report to show, or nil with a reason: nil reason = loading), `supports(harness)`.
- Per-source cache, keyed by harness and `executablePrefix(command)` (so Codex profiles with different `CODEX_HOME`s don't share numbers): last good report, `nextAllowed`, `inFlight`, `backoff`, last failure reason. Switching back to a harness shows its cached report at once if not stale.
- `refresh(trigger:)`: nothing if disabled, unsupported, in flight, or before `nextAllowed`. `.poll` (a 60 s `Timer` in `.common` modes) fetches only if there's no report, it's stale, or it's ≥ 5 min old; `.event` (expand, agent switch, a turn ending = status `.done`, turning Show Usage on) fetches regardless of age. After a success `nextAllowed` = now + 2 min (Claude; the endpoint is rate-limited) / 1 min (Codex); after a 429, now + backoff (10 min, doubling to 30 min, reset by a success); after `keychainDenied`, never (until Show Usage is toggled); after another failure, now + 5 min. Failures keep showing the last report until it goes stale; with none, the reason is shown.
- Every timer tick also re-publishes (so countdowns and staleness update each minute). Results for a harness that's no longer current update the cache only. Logs `usage: <harness> 5h 12% 7d 47%` or `usage: <harness> failed: <reason>` (never the token).

### 9.8 Working directory (M16)
The agent's working directory is `config.cwd` (§8.1). `PanelController` keeps it as `workingDirectory` (absolute, `Config.normalize`d: `standardizedFileURL.path`, so `/private/tmp` and `/tmp`, or `a/../b`, are one directory) and `recentDirectories` (absolute, newest first, at most 8, saved in `state.json`).

**`openDirectory(_ path:show:)`** (the menu and the picker) is `apply(LaunchRequest(directory: path, show: show))` (§9.9): a nonexistent directory is logged and ignored; otherwise it moves to the front of the recents (state saved), and if it differs from `workingDirectory` the agent is restarted there (`changeAgent(command:directory:)`: sets `workingDirectory`, `config.cwd = Config.abbreviate(path)`, the header title and path, saves `cwd`, and calls `session.switchTo(command:directory:)`, one `restart()`, no conversation carried over). The same directory never restarts the agent. Then, if `show` and not animating: collapsed → `expand()` (focused); expanded → make key and focus the terminal. Agent switches (§9.5) go through `changeAgent` too.

**Menu** (`makeDirectoryMenu()`): the current directory, then the recents (skipping ones that no longer exist), up to 8, each titled with its `~`-abbreviated path and the folder's Finder icon (16 pt); the current one is checked. Picking one calls `openDirectory(path, show: false)`. Then a separator and **"Choose Folder…"**: an `NSOpenPanel` (directories only, can create folders, prompt "Open", starting in the current directory, `level = .statusBar + 1`, `collectionBehavior` plus `.moveToActiveSpace` and `.fullScreenAuxiliary` so it opens over a fullscreen app's Space). This is the **one place Poppy activates itself** (a picker can't take keyboard input otherwise): it remembers `NSWorkspace.frontmostApplication`, calls `NSApp.activate()`, runs the picker non-modally (`begin`), and when it closes yields activation back to that app and activates it; on OK, `openDirectory(url.path, show: true)`.

Folders opened with Poppy some other way (`open -a Poppy <dir>`, Finder's Open With, another app) are **ignored** and logged (review fix): any app could otherwise silently restart the agent in a folder of its choosing, whose project config (hooks, plugins) the agent would load. Only the `poppy` command's request files are accepted (§9.9), and Info.plist declares no document types (an earlier M16 draft declared `public.folder`; `open -a` delivers the request files without it, verified).

When the directory changes, the one being left is also kept in the recents (review fix), so the directory Poppy launched in can be picked again.

### 9.9 The `poppy` shell command (M16)
`poppy [options] [directory]` in a terminal opens Poppy with the agent in that directory (default: the shell's current directory), launching it if needed. It's a function in `~/.zshrc` (added for the user in M16):
```zsh
poppy() { "${POPPY_APP:-$HOME/Documents/poppy/build/Poppy.app}/Contents/MacOS/poppy" --cli "$@"; }
```
**Client** (`CommandLineClient`, `nonisolated`): `main.swift` checks for `--cli` before creating `NSApplication` and, if present, runs `CommandLineClient.run(<the arguments after it>)` and `exit`s with its status; no app, window or menu bar item. It:
1. Parses the options (help text in `CommandLineClient.usage`): `-a/--agent NAME` (a built-in agent by name or command word, `claude`, `codex`, `gemini`, `opencode`, or a `config.json` agent by name, case-insensitive; unknown → error listing the names), `-c/--command CMD` (any command), `--pill small|medium|large`, `--auto-open input|done|both|off` (sets both flags), `--focus`/`--no-focus`, `--usage`/`--no-usage`, `-b/--background` (don't expand), `-h/--help`, and at most one directory (relative to the shell's cwd; must exist). Errors go to stderr as `poppy: …` plus a hint, exit 2. `Config.load(quiet: true)` reads `agents` without writing defaults or logging.
2. Requires running inside the bundle (`Bundle.main.bundleURL` ends in `.app`; `swift run` isn't registered with LaunchServices).
3. Writes the `LaunchRequest` as JSON to `~/.config/poppy/run/request-<UUID>.json` (directory 0700, file 0600).
4. Runs `/usr/bin/open -g -a <this bundle> <file>` (`-g`: Poppy isn't brought forward; launched if not running).
5. Waits up to 5 s for Poppy to delete the file (it does when it reads it); if it's still there, **withdraws** it (deletes it, so it can't take effect later, after the user has moved on; review fix), says `poppy: Poppy didn't pick up the request within 5 s; nothing was changed. Try again.` and exits 1. (In testing, one request right after rebuilding wasn't picked up and couldn't be reproduced; this makes such a case visible and harmless.)

**Why a file, not a `poppy://` URL:** a registered URL scheme could be opened by any web page, and a request can carry a command to run. A request file in the user's own `~/.config/poppy/run/` can only come from something that can already write Poppy's config (and so set `command` anyway).

**`LaunchRequest`** (`nonisolated struct`, Codable): `directory`, `command`, `pillDiameter`, `autoOpenOnInput`, `autoOpenOnDone`, `autoOpenFocus`, `showUsage` (all optional: nil = leave as is), `show` (default true). The app accepts a request file only if it's directly in `run/` (compared with symlinks resolved on both sides, for a symlinked `~/.config`; review fix), named `request-*.json` (`isRequestFile`); `consume` reads and deletes it (an invalid one is logged and deleted). At launch, request files older than 5 min are deleted.

**App side:**
- `AppDelegate.application(_:open:)`: each request file is consumed; anything else is ignored and logged (§9.8). Logs `open request: <dir>[, agent <command>]`. If the controller exists, `controller.apply(request)`; otherwise (the open event arrives before `applicationDidFinishLaunching` when it launched Poppy, verified) it's appended to `pendingRequests`: launch then sets `config.command` and `config.cwd` from them (§4) before creating the session, so the agent starts once, in the right place, and then `apply`s each in order.
- **`PanelController.apply(_:)`**: settings first, each through the same code as its menu item and saved the same way (`setPillDiameter`, only for a preset diameter whoever wrote the request (review fix), `setAutoOpen(key, value)`, `toggleShowUsage` if different); then the directory (validated, added to the recents) and command together through `changeAgent(command:directory:)`, **at most one restart**; then `show` expands or focuses the panel as in §9.8.

### 9.10 Images and files into the agent (M17)
Agents take an attachment as a **path**: Claude Code and Codex attach an image when its path is pasted (a terminal drop is exactly that). So Poppy turns every image or file into shell-escaped paths and pastes them into the agent (`PoppyTerminalView.pasteText`: `send(txt:)`, wrapped in `ESC[200~`/`ESC[201~` when `terminal.bracketedPasteMode`, so the agent sees one paste). SwiftTerm's own paste only reads text and it accepts no drops.

**`Attachments`** (`Terminal/Attachments.swift`):
- Images are saved as PNG in `<NSTemporaryDirectory>/poppy-images/` (0700; per-user and private), named `image-<yyyyMMdd-HHmmss>.png` (with `-2`, `-3`, … if taken): PNG data as is, TIFF converted. Promised files are received into their own `drop-<UUID>/` folder per drop (names can't collide). Entries created over 7 days ago (creation date: a promised file keeps its original modification date) are deleted at launch and on every agent (re)start.
- `text(from:completion:)` (true if it handled it): file URLs → their paths; else file promises (`NSFilePromiseReceiver`, e.g. Mail, Photos; the screenshot thumbnail also offers a file URL, which wins) → received as above, then their paths (asynchronously; failures logged; the reply handler is built in a `nonisolated` helper, since AppKit calls it on the operation queue and a main-actor closure would trap there); else PNG/TIFF data **with no non-blank text** → saved, then its path (text wins, as for ⌘V, e.g. a dragged rich-text selection). `completion` runs on the main actor.
- `pasteText(for:)`: file reference URLs are turned into path URLs (`filePathURL`); a path containing a control character (e.g. a newline in a file name) is left out and logged; the rest are joined by spaces, each with a backslash before shell-special characters (as Terminal does for a drop), plus a trailing space.
- `hasAttachment(_:)` (for ⌘V): file URLs, or image data with no non-blank text; so copied text (even with an image alongside) still pastes as text.
- **`sanitized(_:)`** (every Poppy-originated paste goes through it, in `pasteText`; review fix): CRLF/CR → LF, then every C0/C1 control character and DEL is removed except tab and newline. So no pasted text (a dropped string, a promised file's name) can contain `ESC[201~` and end a bracketed paste early, turning the rest into keystrokes (e.g. submitting a prompt or answering a permission dialog). Tested: `hello ESC[201~ CR rm -rf ~` becomes harmless text.

**Ways in:**
- **⌘V** (`PoppyTerminalView.paste`): attachments if `hasAttachment`, else SwiftTerm's text paste. So a screenshot copied with ⌘⌃⇧4, "Copy Image" from a browser, or files copied in Finder paste as paths. (Ctrl+V still goes to the agent, e.g. Claude's own clipboard-image paste.)
- **Drop on the terminal** (`registerForDraggedTypes(Attachments.dropTypes)`: file URL, PNG, TIFF, string, and file-promise types; registered on each new terminal view): attachments, else a dropped string is pasted (sanitized). The operation is below.
- **Operation:** `Attachments.operation(for:)`: `.copy` if the source allows it, else the first of `.generic`, `.link`, `.move` it allows. Each drop logs `drop: on pill|terminal ops=<mask> types=[…]`, then `attachments: …` (files, promised files, or nothing found).
- **Drop on the pill** (`PillView`, same types; accepted only if there's a session and not animating). The logo `NSImageView` is `unregisterDraggedTypes()`'d: an image view registers for image drags itself, so it took the drag over the middle of the pill and refused it (found in the user's M17 test: drops only worked when the drag entered across the rim). `PanelController.dropped(_:)` pastes the same way, then `sendToAgent` expands the panel (focused) or focuses it. **Not while the agent is waiting for an answer** (status `.waiting`, §9.6): then nothing is pasted (logged) and the panel is only shown, since the pasted characters could answer its prompt (review fix).

## 10. Liquid Glass (`GlassBackgroundView`)

`GlassBackgroundView: NSView` has `var cornerRadius: CGFloat` (its `didSet` forwards the value to the backing view) and `let contentView = NSView()`. `PillView` and `ExpandedView` are added to `contentView`.

**Native glass** is used if `#available(macOS 26, *)` and the env var `POPPY_FORCE_FALLBACK` is not `"1"`:
- An `NSGlassEffectView` subview fills self (`autoresizingMask = [.width, .height]`).
- `style = .regular`, `tintColor = nil`, `cornerRadius` is forwarded. Before `glass.contentView = contentView`, set `contentView.frame = glass.bounds` and `contentView.autoresizingMask = [.width, .height]` (in case the glass view does not size it).
- The SDK header was checked: `NSGlassEffectView` has `contentView`, `cornerRadius`, `tintColor` and `style` (`.regular` / `.clear`).

**Fallback** otherwise:
- An `NSVisualEffectView` subview fills self, with `material = .hudWindow`, `blendingMode = .behindWindow`, `state = .active`.
- Corners come from `maskImage`: a resizable rounded-rect image (`NSImage(size:flipped:drawingHandler:)` of size `2r+1` square, `capInsets = NSEdgeInsets(r, r, r, r)`, `resizingMode = .stretch`), regenerated when `cornerRadius` changes.
- `contentView` is added as a subview filling it (autoresizing).

`appLog("glass: native")` or `appLog("glass: fallback")` is logged once when the view is created.

## 11. Global hotkey (M6)

**Ownership (M10).** `AppDelegate` owns a `HotKeyManager` (`Hotkey/HotKeyManager.swift`) and hands it to `PanelController.hotKeys` (weak), so the menu can show and change the hotkey (§7.10). The manager owns `GlobalHotKey?`, `current: HotKeyCombo?` (the chosen combo) and the recorder (§11.2).

**`HotKeyManager.init(spec:action:)`**
- `isRecording` (M14): true while the recorder is open; auto-open waits for it (§7.15).
- `GlobalHotKey(action:)`; nil if the handler can't be installed (then there is no hotkey and "Set Hotkey" is disabled).
- `HotKeyCombo(spec: config.hotkey)`; if nil, log it and use `Config.defaultHotkey` (`ctrl+opt+space`).
- `register(combo)`; `current = combo` only if it returned `noErr`. Otherwise log it and continue without a hotkey (the menu item reads just "Set Hotkey").

**`GlobalHotKey`** (`final class`, the Carbon wrapper)
- `init?(action: @escaping @MainActor () -> Void)`: `InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)`, with `spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))`. Logs the OSStatus; returns nil if non-zero. The handler stays installed for the app's lifetime.
- `register(_ combo: HotKeyCombo) -> OSStatus` (discardable): `unregister()`, then `RegisterEventHotKey(combo.keyCode, combo.modifiers, EventHotKeyID(signature: 0x506F_7079 /* 'Popy' */, id: 1), GetApplicationEventTarget(), 0, &ref)`. Logs `"hotkey <spec> registered: OSStatus N"`. On `noErr` stores the ref and `registered = combo`.
- `unregister()`: `UnregisterEventHotKey` if registered; `registered = nil`.
- `private(set) var registered: HotKeyCombo?`.

**The handler**
- `hotKeyHandler` is a file-scope `nonisolated` function matching `EventHandlerProcPtr`.
- It reads the `EventHotKeyID` with `GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, size, nil, &id)`.
- If `id.signature` is `'Popy'` and `id.id == 1` (otherwise return `eventNotHandledErr`): first `let hk = Unmanaged<GlobalHotKey>.fromOpaque(userData!).takeUnretainedValue()` **outside** any closure (`GlobalHotKey` is main-actor, therefore Sendable; the raw `userData` pointer must not be captured), then `MainActor.assumeIsolated { hk.fire() }` (`fire()` is `fileprivate` and calls the private `action`).
- It returns `noErr`.

**Action** (`PanelController.hotkeyPressed()`, ignored while animating)
- **Collapsed:**
  1. If `screenWithMouse()` differs from `screen(for: pillFrame)` (compared by screen number, §7.2), move the pill to the default position (§7.3) on the mouse's screen and save the state.
  2. `expand()`.
- **Expanded and `panel.isKeyWindow`:** `collapse()`.
- **Expanded and not key:** `panel.makeKeyAndOrderFront(nil)` plus first responder = `focusTarget` (becoming key also clears "done", §7.15).

### 11.1 `HotKeyCombo` (`Hotkey/HotKeyCombo.swift`, M10)
`nonisolated struct HotKeyCombo: Equatable, Sendable { var keyCode: UInt32; var modifiers: UInt32 }` (Carbon key code and Carbon modifier mask). One key table drives parsing, the canonical config string, display and recording.

**`init?(spec:)`**
- Lowercase the string and split it on `+` (empty pieces dropped).
- Modifier tokens:

  | Token | Carbon constant (cast to `UInt32`) |
  |---|---|
  | `ctrl`, `control` | `controlKey` |
  | `opt`, `option`, `alt` | `optionKey` |
  | `cmd`, `command` | `cmdKey` |
  | `shift` | `shiftKey` |

- Exactly one key token. The first token listed is canonical (written back to config.json); the others are accepted aliases:

  | Keys | Tokens | Display |
  |---|---|---|
  | `a`–`z`, `0`–`9` (`kVK_ANSI_*`, US layout) | the character | uppercase character |
  | `` ` `` `-` `=` `[` `]` `\` `;` `'` `,` `.` `/` | `grave`, `minus`, `equal`, `leftbracket`, `rightbracket`, `backslash`, `semicolon`, `quote`, `comma`, `period`, `slash`; or the character | the character |
  | Space, Return, Tab, Escape | `space`; `return`/`enter`; `tab`; `escape`/`esc` | `Space` `↩` `⇥` `⎋` |
  | Delete, Forward Delete | `delete`/`backspace`; `forwarddelete` | `⌫` `⌦` |
  | Arrows | `left` `right` `up` `down` | `←` `→` `↑` `↓` |
  | Home, End, Page Up, Page Down | `home` `end` `pageup` `pagedown` | `↖` `↘` `⇞` `⇟` |
  | F1–F20 (`kVK_F1`…`kVK_F20`) | `f1`…`f20` | `F1`…`F20` |

- **Validity rule** (`static func check(keyCode:modifiers:) -> Problem?`, shared by parsing and recording): the key must be in the table (`.unsupportedKey`), and any key except F1–F20 needs at least one of ⌃, ⌥ or ⌘ (`.needsModifier`). ⇧ alone is not enough, since it would swallow typed capitals system-wide. (Before M10, `shift+<letter>` was accepted.)
- Invalid string: nil (the manager logs it and uses the default).

**Other members**
- `init(keyCode:modifiers:)`, used by the recorder after `check` passes.
- `static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32`: ⌃⌥⇧⌘ only; fn, Caps Lock and keypad flags are ignored.
- `spec`: canonical string with modifiers in the order `ctrl`, `opt`, `shift`, `cmd`, then the key, e.g. `ctrl+opt+space`.
- `displayString`: modifier symbols in Apple's order ⌃⌥⇧⌘, then the key's display, e.g. `⌃⌥Space`. `static func modifierSymbols(_:)` gives the symbols alone.

### 11.2 Hotkey recorder (`Hotkey/HotKeyRecorder.swift`, M10)
Opened by the menu's "Set Hotkey" (§7.10) via `HotKeyManager.beginRecording()`:
- If a recorder is already open, `show()` it again. Otherwise `hotKey.unregister()` (so pressing the current hotkey is recorded instead of toggling the panel), create the recorder and `show()` it.
- **Window:** a `GlassPanel` (§5), 340×140, `allowsKey = true`, `setTitledChrome(true)` (rounded key outline), content a `GlassBackgroundView` with radius 20. Centered horizontally on `PanelController.screenWithMouse().visibleFrame`, and a sixth of its height above center. `show()` = `makeKeyAndOrderFront(nil)` + `refreshShadow()`. Like the expanded panel, it becomes key without activating Poppy. 0.5 s later, if it isn't closed and `!panel.isKeyWindow`, log it and close (no refocus): otherwise it could never be dismissed and the hotkey would stay suspended.
- **Contents:** a vertical `NSStackView`, centered, spacing 6: "Poppy hotkey" (12 pt, secondary); the combo label (24 pt medium, starts as "Press a shortcut"); the hint (11 pt, wrapping, centered, secondary; red for errors), initially "Current: ⌃⌥Space · Esc to cancel" (or "none").
- **Keys:** an `NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged])` monitor, installed on the first `show()` and removed on close. It sees keys before key equivalents (so `GlassPanel`'s ⌘C/V/A routing doesn't fire) and returns nil to swallow them. Events whose `window !== panel` pass through. The handler isn't `@Sendable`, so it is main-actor isolated and calls `handle(_:)` directly (no `assumeIsolated`, which can't capture the non-Sendable `NSEvent`).
  - `flagsChanged`: the combo label shows the held modifier symbols plus "…" (or "Press a shortcut" when none); pass the event through.
  - `keyDown` repeats are swallowed. Escape with no modifiers closes (cancel).
  - `check` fails: combo label resets, hint in red: "That key can't be used." or "Add ⌃, ⌥ or ⌘ (F-keys work alone).", each followed by "Esc to cancel". Stay open.
  - Otherwise show `displayString` and call the manager's `record(combo)`:
    - `register` fails: `.failed("<combo> couldn't be registered (OSStatus N). Try another.")`; the hint shows it; stay open.
    - Success: `current = combo`, then `Config.saveHotkey(combo.spec)` (§8.1). Saved: `.saved`, the recorder closes. Not saved: `.notSaved`; `unregister()` again so the hotkey stays suspended while the recorder is open, the hint says it will be active but resets on relaunch, and Esc closes (which registers `current`).
- **Close** (`close(refocus:)`, idempotent): `refocus` is true for Esc and a successful save, false for losing key status and the not-key timeout. `onResignKey` closes via `DispatchQueue.main.async`, because closing releases the panel, which must not happen inside its own `resignKey`. Remove the monitor, clear `onResignKey`, `allowsKey = false`, `orderOut`, then call the manager's `recorderClosed(refocus:)`:
  - `recorder = nil`.
  - If `hotKey.registered != current`, `register(current)` (restores the old hotkey after a cancel or a failed attempt). If that fails, `current = nil`, so the menu doesn't show a hotkey that doesn't work.
  - If `refocus`, call `onRecorderClosed`, which `PanelController` sets (in `hotKeys`' `didSet`) to `refocusIfExpanded()`: if expanded and not animating, `panel.makeKeyAndOrderFront(nil)` and first responder = `focusTarget`. Not after a click elsewhere, so focus stays where the user put it.
- Recording stores the physical key code; the display uses US-layout names (§11.1), so on other layouts (e.g. AZERTY) the shown character can differ from the key's printed label.
- Shortcuts owned by the system or another app (e.g. ⌘Space for Spotlight) are generally intercepted before they reach the recorder, so they can't be recorded.

## 12. Packaging (M7)

`scripts/bundle.sh` (bash, `set -euo pipefail`, first `cd`s to the repo root so it can run from anywhere):
1. `swift build -c release`.
2. `rm -rf build/Poppy.app`, then `mkdir -p build/Poppy.app/Contents/{MacOS,Resources}`.
3. Copy `$(swift build -c release --show-bin-path)/poppy` to `Contents/MacOS/poppy`, and `Resources/Info.plist` to `Contents/Info.plist`.
   - `mkdir -p Contents/Resources/Logos` and copy `Resources/Logos/*.png` and `Resources/Logos/src/LICENSE-lobe-icons` into it (M11; not the `src` SVGs).
   - SwiftTerm's resource bundle (Metal shaders) is **not** copied. The Metal renderer is not enabled, and SwiftTerm deliberately doesn't use `Bundle.module`.
4. `codesign --force --deep --sign - build/Poppy.app`.
5. Print the app path.

**`Resources/Info.plist`**

| Key | Value |
|---|---|
| `CFBundleExecutable` | `poppy` |
| `CFBundleIdentifier` | `local.poppy` |
| `CFBundleName` | `Poppy` |
| `CFBundlePackageType` | `APPL` |
| `CFBundleShortVersionString` | `0.1.0` |
| `CFBundleVersion` | `1` |
| `LSMinimumSystemVersion` | `14.0` |
| `LSUIElement` | `true` |
| `NSHighResolutionCapable` | `true` |

`.gitignore` adds `/build`.

## 13. Milestones (each builds and runs on its own)

| M | Adds | Temporary behavior |
|---|---|---|
| M1 | `main.swift`, `Log.swift`, `App/AppDelegate.swift`; package/target `poppy` with `defaultIsolation`; `.vscode/launch.json` targets `poppy` | No window. Logs the startup line and keeps running. |
| M2 | `Window/GlassPanel.swift`, minimal `PanelController` | See the M2 spike below. |
| M3 | `Views/GlassBackgroundView.swift`, `Views/PillView.swift` | The panel becomes the 168×44 pill at the default position with `allowsKey = false`. Left-click (no drag) only logs "pill clicked". Right-click shows the context menu (Restart disabled). `pillTitle` is `claude` (Config arrives in M4); `PanelController.init()` takes no arguments. Drag end clamps and updates `pillFrame` but does not save (PanelState arrives in M4), and the position resets on relaunch. The M2 spike is removed. |
| M4 | full `PanelController` (§5–7), `Views/ExpandedView.swift`, `Config/Config.swift` (Config + PanelState, complete) | `contentHost` holds the placeholder text field. `session` is nil. |
| M5 | SwiftTerm, `Terminal/*` | — |
| M6 | `Hotkey/GlobalHotKey.swift` | — |
| M7 | `scripts/bundle.sh`, `Resources/Info.plist`, `.gitignore` `/build` | — |
| M8 | Menu bar item (§7.12); `PanelController.makeMenu()` shared with the context menu (§7.10) | — |
| M9 | Click outside collapses (§6.3); collapse button removed (§7.9) | — |
| M10 | `HotKeyCombo` with more keys (§11.1), `HotKeyManager`, register/unregister `GlobalHotKey` (§11), the recorder (§11.2), hotkey shown in the Set Hotkey menu item and the Collapse item removed (§7.10), `Config.saveHotkey` (§8.1) | — |
| M11 | `Views/HarnessLogo.swift`, `Resources/Logos/` (PNGs + SVG sources), `scripts/render-logos.swift`, logo copy in `bundle.sh`; the pill becomes a 44×44 circle with just the harness logo, unrecognized CLIs show the Poppy logo, and the menu bar icon becomes the Poppy logo (§7.11, §7.12, §12) | — |
| M12 | `Terminal/AgentCatalog.swift`; Agent submenu with installed check, `TerminalSession.switchCommand(to:)`, `PillView.update`, `HeaderView.setTitle`, `Config.agents` and `saveValue` (§9.5, §7.10, §8.1) | — |
| M13 | Expanded panel resizable by edges/corners, terminal reflows while dragging (coalesced, ~20/s) and on release (§7.13); pill size presets Small/Medium/Large in the menu (§7.14); `PanelState.pillDiameter`/`expandedSize` (§8.2) | — |
| M14 | `Terminal/AgentStatus.swift`; status file + polling in `TerminalSession`; hooks for Claude (`--settings`), Codex, Gemini, opencode; pill tint; Auto-Open menu and `GlassPanel` key guard; config flags (§9.6, §7.15, §8.1) | — |
| M15 | `Usage/*`, `Terminal/ChildProcess.swift` (probe refactored onto it), `Views/UsageBar.swift`; usage footer in the expanded view, usage ring on the pill, Show Usage menu item, `showUsage` flag (§9.7, §7.9, §7.10, §7.11, §8.1) | — |
| M16 | Working Directory menu (recents, Choose Folder…), `apply`/`changeAgent`, `TerminalSession.switchTo(command:directory:)` (replacing `switchCommand`), header title = directory name, `PanelState.recentDirectories`, open-documents handling and the `public.folder` document type (Info.plist); `App/LaunchRequest.swift`, `App/CommandLineClient.swift`, the `--cli` branch in `main.swift`, the `poppy` shell function with flags; the round-petal menu bar icon `poppy-menubar` (§9.8, §9.9, §7.9, §7.10, §7.11, §7.12, §8) | — |
| M17 | `Terminal/Attachments.swift`; ⌘V of images/files, drag and drop onto the terminal and the pill (§9.10); a Take Screenshot menu item was removed after M17 at the user's request | — |

**M2 spike:**
- A 240×80 panel at the default bottom-right position (16 pt margin).
- Content is an `NSVisualEffectView` (`.hudWindow`, `.behindWindow`, `.active`, `layer.cornerRadius = 16`, `masksToBounds`) containing an editable `NSTextField`.
- `allowsKey = true` permanently.
- Left mouse-down on the panel's background view logs `NSWorkspace.shared.frontmostApplication?.localizedName`.
- Right-click shows a menu with only Quit.

## 14. Known risks (verify during the milestone noted)

1. Overlay on fullscreen Spaces and following Spaces, both unbundled (`swift run`) and bundled: M2, M7.
2. Keyboard focus returning to the underlying app on collapse (§6.1): M4.
3. Whether `NSGlassEffectView` looks right on a borderless clear panel, and whether the un-animated corner-radius change looks acceptable: M3, M4.
4. Right-click `NSMenu` in a never-activated app: M2.
5. PATH and LANG when launched from Finder: M7.
6. Whether `@preconcurrency` conformance, `defaultIsolation` and the Carbon handler compile cleanly in Swift 6: M1 (`defaultIsolation`), M5, M6.
7. Carbon hotkey on macOS 26, and conflicts with ⌃⌥Space: M6.
8. Whether SwiftTerm's `backgroundOpacity` looks good over glass: M5.
9. Whether `panel.animator().setFrame` honors `ctx.timingFunction` (easing only; judged by eye): M4.
10. The menu bar item's menu doesn't activate Poppy or take key/frontmost from the underlying app, collapsed or expanded: M8.
11. Whether the global mouse monitor fires for clicks on other apps over fullscreen Spaces, on the desktop, and on other menu bar items, without Accessibility permission, both unbundled and bundled; and that dragging a file from Finder into the expanded terminal doesn't collapse it: M9.
12. Whether the recorder panel becomes key and receives keys (including ⌘ combos) without activating Poppy, over fullscreen apps too, and whether a changed hotkey takes effect immediately; the recorder can always be dismissed; and keyboard focus returns to the underlying app after it closes over the collapsed pill: M10.
13. Whether the 44×44 glass circle keeps a good rim and shadow, whether template logos read well on glass in light and dark, and whether the Poppy logo is legible at 18 pt in the menu bar: M11.
14. Whether the installed-CLI probe (an interactive login shell without a tty) finishes quickly and finds aliases, including from the Finder-launched app; that under `swift run` it never touches the launching terminal; and whether switching agents cleanly ends the old one and starts the new one: M12.
15. Whether system edge/corner resizing works on the non-activating titled panel (cursors, all edges, over fullscreen apps), whether the terminal reflows smoothly while dragging without garbling the agent's display, and whether the smaller and larger pills keep a good glass rim: M13.
16. Whether each agent's hooks fire as mapped (Claude via `--settings`, Codex after approving the new hooks, Gemini, opencode's `chat.message`/`permission.ask` hook names), whether Codex's PostToolUse and Gemini's AfterTool report working after an approval, whether Codex/Gemini need hooks switched on in their settings, whether opencode's plugin directory is `plugins/` (not the older `plugin/`), and whether auto-open steals focus acceptably (key guard) and collapses back after answering: M14.
17. Whether the Keychain read via `/usr/bin/security` works without a prompt (or after one "Always Allow") in both the unbundled and bundled app; whether the undocumented Claude usage endpoint keeps answering at this cadence without 429s; whether `codex app-server` answers through the login shell within the timeout; whether the ring reads well on the glass at all three pill sizes: M15.
18. Whether Choose Folder…'s open panel appears over a fullscreen app's Space and takes typing, and whether activation goes back to the previous app afterward (fullscreen included); whether `open -g -a <bundle> <file>` routes to the running bundled app without bringing it forward (verified from a script: Obsidian stayed frontmost), and whether the client's request is always picked up (once, right after a rebuild, it wasn't; not reproduced): M16.
19. Whether Claude Code and Codex attach an image from a bracketed-paste path in Poppy (as from a terminal drop); whether drops reach the non-activating panel and the pill over fullscreen apps; whether the screenshot thumbnail's drag arrives as a file promise or a file URL: M17.
