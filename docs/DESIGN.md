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
  - value types used with Codable (`Config`, `PanelState`)
  - `appLog` (§4)
  - the Carbon C handler (§11)
- Code on the main thread that is not statically main-actor (the bodies of `NSAnimationContext` completion handlers, `NotificationCenter` block observers with `queue: .main`, and the Carbon handler) wraps its body in `MainActor.assumeIsolated { … }`. Never capture non-Sendable parameters (raw pointers, `Notification`) inside that closure; extract Sendable values first.
- SwiftTerm has no actor annotations. Its callbacks arrive on `DispatchQueue.main` (the `LocalProcess` default). Import it with `@preconcurrency import SwiftTerm`, and declare the conformance as `extension TerminalSession: @preconcurrency LocalProcessTerminalViewDelegate`.

## 3. File layout and ownership

```
Package.swift
Sources/poppy/
  main.swift                        entry point
  Log.swift                         appLog()
  App/AppDelegate.swift             creates and owns everything; quit/cleanup
  Config/Config.swift               Config (config.json) + PanelState (state.json) load/save
  Window/GlassPanel.swift           NSPanel subclass
  Window/PanelController.swift      state machine, frames, animation, observers, context menu
  Views/GlassBackgroundView.swift   NSGlassEffectView / NSVisualEffectView fallback
  Views/PillView.swift              collapsed content: click vs drag, right-click
  Views/ExpandedView.swift          ExpandedView + HeaderView (drag, title, collapse button) + contentHost
  Terminal/TerminalSession.swift    TerminalSession + PoppyTerminalView
  Terminal/ShellEnvironment.swift   builds executable/args/env for the child
  Hotkey/GlobalHotKey.swift         Carbon hotkey wrapper + hotkey string parser
Resources/Info.plist                used only by scripts/bundle.sh (not a SwiftPM resource)
scripts/bundle.sh                   builds build/Poppy.app
docs/DESIGN.md, docs/PROGRESS.md
```

Ownership: strong references go downward; back-references are `weak`.
- `AppDelegate` owns `config: Config`, `session: TerminalSession` (from M5), `controller: PanelController`, and `hotKey: GlobalHotKey` (from M6).
- `PanelController` is `final class PanelController: NSObject`; button/menu actions are `@objc` methods.
- `PanelController.init(config:session:)` (from M4; M2–M3 use a temporary `init()` with no arguments and a hard-coded title `claude`):
  - It creates and owns the `GlassPanel`, `GlassBackgroundView`, `PillView` and `ExpandedView`.
  - It calls `session.attach(to: expandedView.contentHost)`.
  - `session` is `TerminalSession?`, which is `nil` before M5.
- `PillView` and `HeaderView` have a `weak var controller: PanelController?`. On right-click they call `controller.showContextMenu(event:in:)`, and the collapse button calls `controller.collapse()`.
- `TerminalSession` owns the current `PoppyTerminalView`.
  - It exposes `var focusView: NSView?`, which is the current terminal view. `PanelController` reads it whenever it needs a first responder.
  - Before M5, `PanelController` uses the placeholder text field instead. The placeholder is created only when `session == nil`, so from M5 on it never exists and `focusTarget` is always the terminal.
- `PoppyTerminalView` has a `weak var session: TerminalSession?`.

Files are introduced in the milestone that needs them (§13).

## 4. Entry point and app lifecycle

- `main.swift` is top-level code (main-actor isolated):
  ```swift
  let app = NSApplication.shared
  let appDelegate = AppDelegate()      // global strong ref; app.delegate is weak
  app.delegate = appDelegate
  app.setActivationPolicy(.accessory)
  app.run()
  ```
- No `@main` anywhere. No main menu is created.
- `applicationDidFinishLaunching`:
  1. `appLog("Poppy started (pid N)")`.
  2. Load the config (§8.1).
  3. Create the session (M5+): `TerminalSession(config:)`. This only computes the launch spec; the process starts in `attach(to:)`.
  4. Create the controller. It shows the pill with `orderFrontRegardless()`.
  5. Register the hotkey (M6+).
- `NSApp.activate` and `NSRunningApplication.activate` are **never** called.
- `applicationWillTerminate`: `session?.terminateChild()` (§9.4).
- Quitting: the context menu's Quit calls `NSApp.terminate(nil)`. Under `swift run`, Ctrl-C in the launching shell also quits (default SIGINT; no handler).

### Logging
`Log.swift`: `nonisolated func appLog(_ message: String)` writes `"[Poppy] " + message + "\n"` as UTF-8 to `FileHandle.standardError`. No os_log.

## 5. The panel (`GlassPanel: NSPanel`)

There is one panel for the app's whole lifetime. It is never closed, only resized.

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
| `hasShadow` | `true` |
| `isMovableByWindowBackground` | `false` |
| `animationBehavior` | `.none` |
| `isReleasedWhenClosed` | `false` |

Overrides:
- `var allowsKey = false` (stored). `canBecomeKey` returns `allowsKey`.
- `canBecomeMain` returns `false`.
- `performKeyEquivalent(with:)` (§6.2).

The panel is shown with `orderFrontRegardless()` only; `makeKeyAndOrderFront` is used only in the expanded state (§6.1). Call `panel.invalidateShadow()` in the completion of every frame animation and after every drag end (the expand/collapse steps in §7.7 list it).

### Observers (in `PanelController`)
- `NSWorkspace.shared.notificationCenter`, `NSWorkspace.activeSpaceDidChangeNotification`: call `panel.orderFrontRegardless()`. Key status is not changed.
- `NotificationCenter.default`, `NSApplication.didChangeScreenParametersNotification`: re-clamp (§7.4). If `isAnimating`, set `needsReclamp = true` instead; the final completion of expand/collapse (where `isAnimating` becomes false) runs the re-clamp if `needsReclamp`, then clears it.

## 6. States and focus

`PanelController.state: State`, where `enum State { case collapsed, expanded }`, plus `isAnimating: Bool`. The only transitions are `expand()` and `collapse()`. Each is a no-op if already in the target state or while `isAnimating`.

**While `isAnimating`, ignore:**
- all left-mouse handling in `PillView` / `HeaderView` (click, drag)
- the collapse button
- the hotkey

Right-click menus still work.

### 6.1 Key focus
- **Collapsed:** `allowsKey = false`. The pill never becomes key. `PillView.acceptsFirstMouse(for:)` returns `true`.
- **Expand** (§7.6 sequencing):
  1. Set `allowsKey = true` at the start.
  2. When the frame animation finishes, call `panel.makeKeyAndOrderFront(nil)`, then `panel.makeFirstResponder(focusTarget)`.
     - `focusTarget` is `session?.focusView ?? placeholderField`.
- **Collapse:** before the animation starts:
  1. `panel.makeFirstResponder(nil)`
  2. `allowsKey = false`
  3. `panel.orderOut(nil)`
  4. immediately `panel.orderFrontRegardless()`

  This drops key status so the underlying app's window gets keyboard input again.
  - **Acceptable fallback if M4 shows otherwise:** the user clicks the underlying app to restore typing. Record this as a known issue. Do not call `activate`.
- Clicking another app while expanded: the panel stays expanded and visible, but not key. Clicking inside it makes it key again (standard non-activating panel behavior).

### 6.2 Key equivalents
The app is never active and has no main menu, so menu key equivalents never fire.

`GlassPanel.performKeyEquivalent(with:)` handles only events where both hold:
- `event.modifierFlags.intersection([.command, .shift, .control, .option]) == [.command]`
- `event.charactersIgnoringModifiers?.lowercased()` is one of:

| Key | Action sent with `NSApp.sendAction(_:to: nil, from: self)` |
|---|---|
| `c` | `#selector(NSText.copy(_:))` |
| `v` | `#selector(NSText.paste(_:))` |
| `a` | `#selector(NSResponder.selectAll(_:))` |

It returns the result of `sendAction`. Everything else, including Cmd-Q and Cmd-W, goes to `super` (so it is not handled; quitting is via the menu). All non-command keys reach the first responder unchanged, so Esc, Ctrl-C and the rest reach the terminal. SwiftTerm's Mac `TerminalView` implements `open func copy(_:)`, `open func paste(_:)` and `override func selectAll(_:)` (checked in v1.20.0 source).

## 7. Geometry, animation, drag

### 7.1 Sizes
| | Size | Corner radius |
|---|---|---|
| Collapsed pill | 168 × 44 pt | 22 |
| Expanded panel | 760 × 480 pt | 20 |

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
Bottom-right of a screen's `visibleFrame`: pill origin = `(maxX − 16 − 168, minY + 16)`. At launch the screen is `NSScreen.main`.

### 7.4 Clamping
`clamp(frame, in screen)` shifts the frame so it lies inside `visibleFrame.insetBy(dx: 8, dy: 8)`. Frames are never shrunk: if a frame is larger than that area, it is aligned to the area's top-left corner (`minX`, `maxY`) and allowed to overflow. This is decided **per axis**: an axis that fits is shifted normally; an axis that overflows is aligned (x to `minX`, y so that `maxY` matches). The fixed-size `ExpandedView` (§7.7) is therefore never clipped by clamping. It is applied:
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
- `ExpandedView` always has a **fixed** size of 760 × 480, so the terminal never resizes.
  - At the start of each expand, its origin is placed so that its anchor corner matches the container's anchor corner.
  - Its `autoresizingMask` is set to keep it attached to that corner:

    | Anchor | Horizontal | Vertical |
    |---|---|---|
    | left | `.maxXMargin` | — |
    | right | `.minXMargin` | — |
    | bottom | — | `.maxYMargin` |
    | top | — | `.minYMargin` |

    Example: bottom-right means origin `(containerWidth − 760, 0)` and mask `[.minXMargin, .maxYMargin]`.
  - The window clips it while the window is smaller. When fully expanded, its frame is exactly the container bounds.
- Animation constants:
  - Frame animation: 0.30 s, `CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.2, 1.0)`.
  - Fades: 0.12 s, default timing.
- Frame animation call: `NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.30; ctx.timingFunction = …; panel.animator().setFrame(target, display: true) }, completionHandler: { MainActor.assumeIsolated { … } })`.
- Fades use their own nested `runAnimationGroup` on `view.animator().alphaValue`.

**Expand:**
1. `isAnimating = true`.
2. Compute the anchor and the target frame.
3. Set the glass `cornerRadius = 20`.
4. Hide `PillView` (`alphaValue = 0`, `isHidden = true`).
5. Position `ExpandedView` and set its mask. Set `alphaValue = 0`, `isHidden = false`.
6. Animate the frame. In its completion:
   1. `invalidateShadow()`.
   2. Focus (§6.1).
   3. Fade `ExpandedView` to 1.
   4. In the fade's completion, `isAnimating = false`.

**Collapse:**
1. `isAnimating = true`.
2. Release focus (§6.1).
3. Compute `pillFrame` (§7.6).
4. `ExpandedView.alphaValue = 0`, `isHidden = true`.
5. Animate the frame to `pillFrame`. In its completion:
   1. Set the glass `cornerRadius = 22`.
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
    - Centered title label: `pillTitle` (§7.11), 12 pt system font, `secondaryLabelColor`.
    - Trailing collapse button, 8 pt from the trailing edge: `FirstMouseButton` (an `NSButton` subclass in `ExpandedView.swift` whose `acceptsFirstMouse(for:)` returns `true`, so one click collapses even when the panel is not key), borderless, SF Symbol `chevron.down`, target `controller`, action `collapse`.
- **`contentHost`** (`NSView`):
  - Its frame is `ExpandedView` bounds minus the header, inset 8 pt on the left, right and bottom. The gap below the header is 0.
  - `wantsLayer = true`, `layer.cornerRadius = 10`, `layer.masksToBounds = true`, no background color.
  - Until M5 it holds the placeholder: an editable `NSTextField` filling its width at the top, with placeholder text "Type here to test focus".

### 7.10 Context menu
`PanelController.showContextMenu(event:in:)`:
- Builds an `NSMenu` with `autoenablesItems = false` and two items, both with explicit `target = self` (the controller):
  - **"Restart Agent":** action `restartAgent` calls `session?.restart()`. Enabled only if `session != nil`.
  - **"Quit Poppy":** action `quit` calls `NSApp.terminate(nil)`.
- Shows it with `NSMenu.popUpContextMenu(menu, with: event, for: view)`.

### 7.11 Pill contents
- `pillTitle` = `lastPathComponent` of the first whitespace-separated word of `config.command` (for example, `/usr/local/bin/claude --x` becomes `claude`).
- The pill shows a centered horizontal `NSStackView` (spacing 6):
  - SF Symbol `terminal` (`NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)`)
  - a label with `pillTitle` (13 pt, medium weight)
- Both use `labelColor`.

## 8. Configuration and state

The directory is `~/.config/poppy/`, created with intermediate directories if missing. Both types are `nonisolated struct … : Codable, Sendable`.

### 8.1 `Config` (`config.json`, user-edited, read at launch only; introduced in M4)
```json
{ "command": "claude", "cwd": "~", "hotkey": "ctrl+opt+space" }
```

**Decoding**
- A hand-written `init(from:)` uses `decodeIfPresent` for each key, falling back to the defaults above. Unknown keys are ignored.

**Load rules**
- **File missing:** write the defaults (pretty-printed, sorted keys) and use them.
- **File exists but doesn't parse:** `appLog` the error and use the defaults. The file is **not** overwritten.

**Field rules**
- `POPPY_COMMAND` env var: if set and non-empty, it replaces `command`.
- If `command` (after the override) is empty or only whitespace: log it and use `claude`.
- `cwd`:
  - `"~"` becomes the home directory, and a prefix of `"~/"` becomes home + the rest. Nothing else is expanded.
  - If the result isn't an existing directory, log it and use the home directory.
- `command` is a shell command string (§9.2).

### 8.2 `PanelState` (`state.json`, app-written)
```json
{ "pillOrigin": { "x": 1200, "y": 16 } }
```
- `pillOrigin` is a `nonisolated struct SavedPoint: Codable, Sendable { var x: Double; var y: Double }` (not `CGPoint`, whose Codable form is an array).
- **Saved after:**
  - every drag end (pill or header)
  - a hotkey screen move (§11)
  - a screen-change clamp that moved the frame

  The saved value is always the pill origin (`pillFrame.origin`).
- **At launch:**
  - If the file is present and a 168×44 rect at that origin intersects any screen's `visibleFrame`, use it, clamped in `screen(for:)`.
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

**`init(config: Config)`** computes the launch spec (executable, args, env, cwd; §9.2) once and stores it; `restart()` reuses it.

**`attach(to host: NSView)`**
- Stores `host` (weak).
- Creates the view with `frame = host.bounds` and `autoresizingMask = [.width, .height]`.
- Adds it to `host` and starts the process.
- Called once by `PanelController.init`, so the agent starts at app launch, not at first expand.
- `host` has a fixed size (§7.7), so the terminal size is constant.

**View configuration**
- `font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)`
- `nativeForegroundColor = NSColor(white: 0.92, alpha: 1)`
- `nativeBackgroundColor = NSColor(white: 0.05, alpha: 1)`
- `backgroundOpacity = 0.80`: only the default background is translucent, so the glass shows through behind the text.
- Do not enable SwiftTerm's Metal renderer (it's off by default).

### 9.2 Spawning (`ShellEnvironment`, `nonisolated enum` with static functions)
- **`executable`:** `$SHELL` from `ProcessInfo.processInfo.environment` if it's an absolute path and `FileManager.isExecutableFile(atPath:)` is true. Otherwise `/bin/zsh`.
- **`args`:** `["-l", "-i", "-c", command]`, **no `exec`**. With `-i`, `.zshrc` is sourced before the `-c` string is parsed, so aliases and shell functions (e.g. `alias claude=~/.claude/local/claude`) work, as do compound commands. The shell stays as the agent's parent; §9.4 signals the whole process group.
- **`execName`:** `nil`.
- **`currentDirectory`:** the resolved `cwd` (§8.1).
- **Environment**, sent as `["KEY=VALUE"]`. Start from `ProcessInfo.processInfo.environment`, then:
  - Always set `TERM=xterm-256color`, `COLORTERM=truecolor`, `TERM_PROGRAM=Poppy`, and `SHELL=<executable>`.
  - Set `LANG=en_US.UTF-8` only if `LANG` is unset or empty.
  - Set `HOME` (`NSHomeDirectory()`), `USER` and `LOGNAME` (`NSUserName()`) each only if unset or empty.
  - Remove `POPPY_COMMAND`.

### 9.3 Exit and restart
- **`processTerminated`:**
  - Set `exited = true`.
  - Feed this into the terminal: `currentView.feed(text: "\r\n[Poppy] process exited (\(desc)). Press Enter to restart.\r\n")`, where `desc` is `code N`, or `signal` if `exitCode` is nil.
- **`PoppyTerminalView.send(source:data:)`** (the outgoing path: keystrokes and terminal-generated replies):
  - If `session?.exited == true`: drop the data. If it contains byte 13, call `DispatchQueue.main.async { session.restart() }` (deferred: `restart()` removes this very view, which is still on the stack in `keyDown`).
  - Otherwise, call `super`.
- **`restart()`** (doesn't wait for the old process):
  1. `terminateChild()`.
  2. Remove the old view from `host`.
  3. Create and start a new view (same as `attach`), set `exited = false`.
  4. Call `onViewReplaced?()`, a closure set by `PanelController`. If the panel is expanded, it makes `session.focusView` the first responder.

### 9.4 Terminating the child
`terminateChild()`, when `currentView.process.running` and `shellPid > 0`:
1. `kill(-shellPid, SIGHUP)`. The child is a group leader after `forkpty`.
2. Only if that returns −1: `kill(shellPid, SIGHUP)`.

It's called from `restart()` and `applicationWillTerminate`. In `restart()` only, after signalling, reap the old child off the main thread so it can't become a zombie: `let pid = shellPid; DispatchQueue.global().async { var st: Int32 = 0; _ = waitpid(pid, &st, 0) }` (returns immediately with ECHILD if SwiftTerm already reaped it).

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

**Registration**
- `GlobalHotKey.init?(spec: String, action: @escaping @MainActor () -> Void)`: parses `spec` (falling back to `ctrl+opt+space` as below), installs the handler, registers the hotkey, and logs both OSStatus values. If either `InstallEventHandler` or `RegisterEventHotKey` returns non-zero, it cleans up whatever succeeded and returns `nil`. `AppDelegate` stores the optional result.
- Handler: `InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)`.
  - `spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))`.
- Hotkey: `RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: 0x506F_7079 /* 'Popy' */, id: 1), GetApplicationEventTarget(), 0, &ref)`.

**The handler**
- `hotKeyHandler` is a file-scope `nonisolated` function matching `EventHandlerProcPtr`.
- It reads the `EventHotKeyID` with `GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, size, nil, &id)`.
- If `id.id == 1`: first `let hk = Unmanaged<GlobalHotKey>.fromOpaque(userData!).takeUnretainedValue()` **outside** any closure (`GlobalHotKey` is main-actor, therefore Sendable; the raw `userData` pointer must not be captured), then `MainActor.assumeIsolated { hk.action() }`.
- It returns `noErr`.

**Logging and teardown**
- `appLog("hotkey \(string) registered: OSStatus \(status)")`. On a non-zero status, log it and continue without a hotkey.
- `AppDelegate` keeps `GlobalHotKey` alive for the app's lifetime.

**Parser** (`nonisolated static func parse(_ s: String) -> (keyCode: UInt32, modifiers: UInt32)?`)
- Lowercase the string and split it on `+`.
- Modifier tokens:

  | Token | Carbon constant (cast to `UInt32`) |
  |---|---|
  | `ctrl`, `control` | `controlKey` |
  | `opt`, `option`, `alt` | `optionKey` |
  | `cmd`, `command` | `cmdKey` |
  | `shift` | `shiftKey` |

- Exactly one key token:
  - `a`–`z` and `0`–`9` map to `kVK_ANSI_*` (US layout).
  - `space` maps to `kVK_Space`.
  - `f1`–`f12` map to `kVK_F1`…`kVK_F12`.
- At least one modifier is required, unless the key is F1–F12.
- Invalid string: log it and use `ctrl+opt+space`.

**Action** (`PanelController.hotkeyPressed()`, ignored while animating)
- **Collapsed:**
  1. If `screenWithMouse()` differs from `screen(for: pillFrame)` (compared by screen number, §7.2), move the pill to the default position (§7.3) on the mouse's screen and save the state.
  2. `expand()`.
- **Expanded and `panel.isKeyWindow`:** `collapse()`.
- **Expanded and not key:** `panel.makeKeyAndOrderFront(nil)` plus first responder = `focusTarget`.

## 12. Packaging (M7)

`scripts/bundle.sh` (bash, `set -euo pipefail`, run from the repo root):
1. `swift build -c release`.
2. `rm -rf build/Poppy.app`, then `mkdir -p build/Poppy.app/Contents/{MacOS,Resources}`.
3. Copy `.build/release/poppy` to `Contents/MacOS/poppy`, and `Resources/Info.plist` to `Contents/Info.plist`.
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
