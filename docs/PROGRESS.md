# Poppy — Progress

Resume guide: read docs/DESIGN.md (source of truth), then this file.

Workflow per milestone:
1. Implement it and run `swift build` until clean.
2. The user runs the manual test.
3. A goldfish reviewer reviews `git diff` against DESIGN.md.
4. Fix valid findings, update this file, and commit.

## Status
| M | Milestone | Status |
|---|---|---|
| M1 | Accessory app, no Dock icon | done |
| M2 | Floating panel over fullscreen / all Spaces | done |
| M3 | Liquid Glass pill + fallback | done |
| M4 | Expand/collapse animation + drag | done |
| M5 | Embedded PTY terminal (SwiftTerm) | done |
| M6 | Global hotkey (Carbon) | done |
| M7 | .app bundling script | done |
| M8 | Menu bar item (Restart Agent, Quit) | done |
| M9 | Click outside collapses; collapse button removed | done |
| M10 | Customizable hotkey: Set Hotkey recorder, hotkey shown in the menu, more keys | done |
| M11 | Logos (black-and-white transparent PNGs): logo-only circular pill; Poppy logo in the menu bar and for unrecognized CLIs | done |
| M12 | Agent switching from the menu (no context carry-over) | done |
| M13 | Resizable expanded panel (drag edges/corners, terminal reflows live); pill size presets | done |
| M14 | Agent status hooks (all four agents): status-colored pill (menu bar icon unchanged, per the user); Auto-Open when input is needed / done, with or without taking focus | done |
| M15 | Usage meters (Claude, Codex): footer in the expanded view with % left and reset countdowns; 5-hour ring around the pill; Show Usage menu toggle | done |
| M16 | Working Directory menu (recents, Choose Folder…); `poppy [options] [dir]` shell command opens Poppy in that directory, with flags for agent, pill size, Auto-Open, usage; header shows just the directory name; new round-petal menu bar icon (the user's SVG) | done |
| M17 | Images and files into the agent: ⌘V of screenshots/images/files, drag and drop onto the terminal or the pill | done |
| M18 | Liquid Glass reappearance after a Space swipe: the panel fades in and scales up when the system shows it again (§7.16) | done |

## Decisions
- Window level `.statusBar` (fallback `.floating`); `collectionBehavior` includes canJoinAllSpaces + fullScreenAuxiliary.
- Config in `~/.config/poppy/config.json`, not UserDefaults (`swift run` has no bundle ID).
- Terminal view has a fixed size and is clipped during the animation, so each toggle sends one SIGWINCH.
- Cmd-C/V/A are handled in `GlassPanel.performKeyEquivalent`, because the app is never active.
- `defaultIsolation(MainActor.self)` for the target (compiles on Swift 6.2.3).
- `NSGlassEffectView` API names checked against the macOS 26 SDK header: `contentView`, `cornerRadius`, `tintColor`, `style`.
- SwiftTerm pinned `from: "1.20.0"` (latest tag on 2026-09-28).
- The design went through three goldfish audits (2026-09-28). Changes that came out of them:
  - no `exec` in the shell command, so aliases work
  - the Carbon handler unwraps `Unmanaged` before `assumeIsolated`
  - `SavedPoint` instead of `CGPoint`
  - the expanded frame is never shrunk
  - `restart()` is deferred
- Rejected goldfish claim: "SwiftTerm 1.20.0 doesn't exist". `git ls-remote` shows tags up to v1.20.0.
- Product renamed from GlassTerm to **poppy** (user request, 2026-09-28):
  - lowercase `poppy` for identifiers: package, target, executable, `~/.config/poppy`, `local.poppy`, `POPPY_*` env vars
  - "Poppy" for display text: log prefix, menu, `Poppy.app`
  - `GlassPanel` and `GlassBackgroundView` keep their names, because "Glass" there is the visual effect
- M2 verified by the user (unbundled `swift run`):
  - `.statusBar` level works over fullscreen apps and on all Spaces
  - the text field in the non-activating panel takes typing, and the frontmost app stayed Code/Ghostty
  - the right-click `NSMenu` works in the never-activated app
  - Risks 1 (unbundled half) and 4 are closed.
- M3 verified by the user: native `NSGlassEffectView` looks right on the borderless clear panel, and the fallback mask rounds correctly. Risk 3 is closed except for the un-animated radius change (checked in M4).
- `GlassBackgroundView.roundedMask` is `nonisolated`, because AppKit may call NSImage drawing handlers off the main thread (M3 review).
- `NSAnimationContext` `completionHandler` is `@Sendable` in the Swift overlay, so animation completions are typed `@MainActor () -> Void`.
- M4 verified by the user:
  - keyboard focus returns to the underlying app after collapse (the `orderOut` + `orderFrontRegardless` trick works), which closes risk 2
  - the un-animated corner-radius change looks acceptable, which closes the rest of risk 3
  - the easing looks right
- SwiftTerm resolved to 1.20.0. Its `processTerminated` `exitCode` is the raw waitpid status (exit 3 arrives as 768), so Poppy decodes it.
- The terminal is created at its final fixed size at launch, so expand/collapse causes zero resizes (no `terminal size` log lines).
- Interactive login zsh startup takes about 1.5s on the dev machine, so the agent appears shortly after launch.
- M5 verified by the user:
  - claude runs with colors
  - vim/htop render correctly
  - the session survives collapse
  - focus works over fullscreen Chrome
  - copy/paste works
  - exit + Enter restarts the agent
  - a custom command works
  - Esc and Ctrl-C reach the agent
  - 80% background opacity is readable
  - Closes risks 6 (SwiftTerm half) and 8.
- User-reported after M5 (fixed together with M6, verified by the user):
  - SwiftTerm's scroller showed on the right. Now hidden, and the columns are re-fitted.
  - Square window-shadow edges showed outside the rounded corners when the expanded panel was key.
    - First attempt (turn off `hasShadow` for native glass) was wrong. A side-by-side experiment (scratchpad glasslab: regular/clear, shadow on/off, key, container) showed the bright Spotlight-like rim comes **from the window shadow**, not from `NSGlassEffectView`. Without the shadow the glass looks flat.
    - Actual fix: keep `hasShadow = true` and refresh the shadow shape at every change (`GlassPanel.refreshShadow()`: now plus the next run-loop pass; on becomeKey/resignKey; after animations, fades and drags).
    - The refresh alone did not fix it. The square hairline is the macOS 26 **key-window outline of a borderless window**, reproduced with the scratchpad `keylab` experiment.
    - Of the options tested (borderless: square; borderless without shadow while key: no rim; titled with a hidden titlebar: correct), titled won. The panel is now titled only while expanded (`GlassPanel.setTitledChrome`), and the pill stays borderless.
- Carbon `RegisterEventHotKey` for ctrl+opt+space returns noErr on macOS 26.6.
- User-reported: ⌘⌫ did nothing in the terminal. SwiftTerm sends Command keys through `interpretKeyEvents` and ignores the resulting text commands. Added Ghostty-style mappings in `PoppyTerminalView.performKeyEquivalent`: ⌘⌫ sends ^U, ⌘← sends ^A, ⌘→ sends ^E. (SwiftTerm's `keyDown` isn't `open`.)
- M6 verified by the user:
  - hotkey over fullscreen Chrome
  - collapse returns typing to Chrome
  - refocus without collapsing
  - works on other Spaces
  - Closes risk 7.
  - ⇧↩ inserts a newline in Claude Code without a mapping (SwiftTerm's kitty keyboard protocol).
- Possible later additions (not requested yet): ⌘K clear, ⌘+/−/0 font size via a `fontSize` config.
- M7 verified by the user on the bundled `build/Poppy.app`:
  - no Dock icon, ad-hoc signature
  - the Finder-launched PATH/locale matches the shell
  - claude launches
  - fullscreen, Spaces and hotkey behavior is unchanged
  - rounded key-window corners
  - Closes risks 1 (bundled half) and 5.
- M8: menu bar item (template SF Symbol `terminal`) opens the same menu as the pill's right-click, built by one `PanelController.makeMenu()` so future settings land in both.
  - Verified by the user: icon adapts to light/dark, Restart Agent and Quit work, no activation over fullscreen apps, no Dock icon. Closes risk 10.
  - Review: adopted the controller as `NSMenuDelegate` so the long-lived menu bar menu is rebuilt on each open (no stale state once settings exist), a text fallback if the symbol is missing, a creation log line, and DESIGN §3/§4/§14 fixes.

- M9: the collapse button was replaced by click-outside-to-collapse (a global mouse monitor, DESIGN §6.3), at the user's request. Verified by the user; closes risk 11.
  - Review: left clicks now collapse on mouse-up and not when released over the panel, so dragging a file from Finder into the terminal works (re-check in M10's test). Added a "Collapse" menu item as a fallback if the hotkey fails to register. (Removed again in M10 at the user's request; without a hotkey, click outside is the only way to collapse.)
- M10: customizable hotkey. "Set Hotkey (⌃⌥Space)" in the Poppy menu opens a glass recorder window; the combo is registered live and only `"hotkey"` is written back to config.json. More keys (punctuation, arrows, Return/Tab/Esc/Delete, Home/End/Page, F1–F20). ⇧ alone no longer counts as a modifier. The M9 Collapse menu item was removed at the user's request. Verified by the user; closes risk 12 (and the M9 drag-and-drop re-check).
  - Review: close deferred out of `resignKey`; the recorder closes itself if it never becomes key; after a save-failure the hotkey stays suspended until the recorder closes; a failed restore clears `current`; the terminal is refocused after Esc/save over the expanded panel. Rejected: rejecting duplicate modifiers (`ctrl+ctrl+a`), harmless.
- M11: the pill is a 44×44 glass circle showing only a logo; logos are black-and-white transparent PNGs (template images) rendered from SVGs by `scripts/render-logos.swift`. Harness marks from lobehub/lobe-icons (MIT); the Poppy flower (user-supplied) is the menu bar icon and the logo for unrecognized CLIs. Colored brand variants were tried first and dropped at the user's request. Verified by the user; closes risk 13.
  - Review: repo logo path only in debug builds; pill is an accessibility button and names unrecognized CLIs by `pillTitle`; lobe-icons MIT license added and shipped; render script runs from anywhere. Not migrated: a pill saved hugging the right edge under the old 168-pt width comes back 124 pt left of it; one drag re-saves it.
- M12: "Agent ▸" submenu (built-ins + optional `config.agents`, each with its logo) switches the agent in a fresh terminal and saves `command` to config.json; CLIs not found by a login-shell probe show "(not installed)". Verified by the user; closes risk 14 (the swift-run-terminal part was fixed after the test, by design of setsid).
  - Review: the probe now uses posix_spawn with setsid, reads until the shell exits, and SIGKILLs the group after 5 s (tested with a SIGTERM-ignoring shell and a shell leaving a background job); a bad `agents` entry no longer discards the whole config; the launch command stays in the list after switching away; `probeWord` skips `NAME=value`, expands `~/`, and skips quoted words.
- M13: the expanded panel resizes by its edges/corners (system resizing on the titled panel); the terminal reflows while dragging, coalesced to ~20/s (the user asked for live reflow over reflow-on-release), and the size is saved. Pill Size ▸ Small 36 / Medium 44 / Large 56. Verified by the user; closes risk 15.
  - Review: `.resizable` only after the expand animation; zoom disabled; non-live resizes (tiling) applied at once; the saved pill origin matches a size changed while expanded. Rejected: silencing the per-resize `terminal size` log (debug stderr only, useful).
- M13 follow-up: the traffic-light buttons reappeared after M13 (making the panel resizable after the expand animation changes the style mask, and AppKit recreates the buttons). Fixed by hiding them in a `styleMask` `didSet` in `GlassPanel`. Verified by the user.
- M14: agent status hooks for Claude (`--settings`), Codex and Gemini (additive, env-guarded entries in their global configs) and opencode (a Poppy plugin), reporting through a per-start status file; the pill logo is tinted blue/orange/green (the menu bar icon stays unchanged, the user's choice); Auto-Open ▸ When Input Is Needed / When Done / Focus the Panel. Modeled on platoon's status feed and claude-popup's hooks. Verified by the user (first test: auto-open didn't fire because the option was off; logging added).
  - Reviews (two passes): statusHooks=false really disables everything; only a waiting auto-open collapses back, and only on the first status after it; the key guard starts when the panel takes the keyboard, covers ⌘ shortcuts and held-key repeats; auto-open waits for animations, live resize and mouse-down and retries; `--settings` goes right after the executable; Codex PostToolUse, Gemini AfterTool and opencode tool.execute.after report working after an approval; Gemini non-tool events get no matcher; merges write through symlinks; hooks only write to an existing status file. Rejected: a versioned hook marker (nothing to upgrade yet).

## Known issues
- Ad-hoc signing (`--sign -`) identifies the app by its build hash, so macOS privacy prompts (e.g. when the agent reads ~/Documents) may come back after each `bundle.sh` rebuild, and old grants pile up in System Settings. Expected; a stable identity would need a real signing certificate.
- While expanded the panel is titled, so AppKit may constrain its frame on `makeKeyAndOrderFront`. On a display whose visible area is smaller than about 776×496 pt, this can override §7.4's top-left overflow alignment. Not fixed, because it's practically unreachable (M6 review nit).

## Deferred review notes
- (done in M5) Create the placeholder field only when `session == nil` (M4 review).
- (resolved in M4) Observer cleanup: M4 uses selector-based `NotificationCenter` observers, which unregister automatically, instead of block observers removed in `deinit`. This also avoids nonisolated-deinit problems.
- M15: usage meters for Claude (OAuth usage endpoint + Claude Code's Keychain login) and Codex (`codex app-server` rate-limit RPC), modeled on platoon: footer in the expanded view (% left, reset countdown), 5-hour ring on the pill (uncolored, no track, per the user), Show Usage toggle. The installed-CLI probe moved onto the new `ChildProcess` helper. Fix after the user's test: the ring stayed white in light mode (color resolved once). Goldfish review fixed: a window already reset no longer hides the whole report; Keychain read gets 60 s and isn't retried after a refusal; Codex app-server gets stdin EOF and 1 s to exit before SIGKILL; `@concurrent` Claude fetch; `FD_CLOEXEC` pipes; EINTR-safe `waitpid`; cache keyed per command. Rejected: microsecond date parsing (verified it parses); `Harness` with `NAME=value` prefixes (it already skips them, M14).
- M16: Working Directory menu (recents, Choose Folder…, the one place Poppy activates itself) and the `poppy [options] [directory]` shell command (a `--cli` client mode of Poppy's own binary that hands the app a private request file; no `poppy://` URL, which any web page could open). Flags: agent, command, pill size, Auto-Open, focus, usage, background. Header shows the directory name only (the user's request). New round-petal menu bar icon from the user's SVG. The user's "Claude Code not installed" turned out to be their nvm default moving to a new Node without Claude; fixed by installing Claude Code natively (`~/.local/bin`, added to PATH), at the user's request. Goldfish review fixed: symlink-safe request check; plain folder opens ignored (any app could otherwise restart the agent in a folder of its choosing), so no document types; pending requests queued; the client withdraws a request not picked up in 5 s; pill diameter validated in the app; the directory being left stays in the recents; `--cli` only as the first argument; §4 updated (activation exception, launch steps). Rejected: deferring `show` during an animation (rare, and the panel is already opening/closing); `resolvingSymlinksInPath` for all directories (would replace the user's symlinked folder names with real paths; `/private/tmp` vs `/tmp` is already handled).
- M17: images and files into the agent as pasted paths (Claude Code and Codex attach images from a pasted path): ⌘V of clipboard images/files, drops on the terminal and the pill, Take Screenshot (`screencapture -i`). Fix after the user's test: the pill's logo image view registered for image drags itself and refused drops over the middle of the pill. Goldfish review fixed: pasted text is sanitized (no ESC/control characters, so nothing can end a bracketed paste and inject keystrokes); paths with control characters are skipped; file reference URLs resolved; promise reply handler built nonisolated (would trap on Swift 6's isolation check); promised files get a per-drop folder and cleanup goes by creation date, also on each agent start; drops prefer text over image data like ⌘V; nothing is pasted while the agent is waiting for an answer. Not changed: the operation choice already prefers `.copy` (the doc line was fixed); feedback for failed promises (logged only).
- Take Screenshot removed (user request, 2026-09-30): the user never asked for it, and it was the only thing that made macOS ask Poppy for Screen Recording. Screenshots still go in via ⌘⌃⇧4 + ⌘V or by dragging the thumbnail onto the terminal or the pill, neither of which needs the permission.
- M18: Liquid Glass reappearance after a Space swipe. Probes first: the only start/end signal without new permissions is the panel's occlusion state (private DockControl events need Input Monitoring and the panel isn't drawn mid-swipe anyway, so only the reappearance can animate); a window at alpha 0 never counts as visible again, so the glass layer's opacity is used, not the window alpha. Three goldfish design rounds added the critically damped spring (no clipped overshoot), the watchdog, `revealIfArmed`, and the generation guard. Goldfish code review: user actions reveal fade-only, not from auto-open, watchdog gives up after 10 s; its worry that expand/collapse would arm it was re-measured and rebutted. Fix after the user's test: the rim (window shadow) popped in when the spring settled; the shadow now stays on and is recomputed every frame during the scale.
- GitHub release setup (2026-09-30, user's choice: source only, clone and build): `README.md`, MIT `LICENSE`, `scripts/install.sh` (toolchain check, bundle, install to /Applications, `poppy` wrapper in ~/.local/bin), bundle ID `io.github.dquigles.poppy`. No Developer ID needed: a locally built app isn't quarantined. arm64 checked by cross-compiling on the Intel dev machine.
