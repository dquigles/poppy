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
| M3 | Liquid Glass pill + fallback | not started |
| M4 | Expand/collapse animation + drag | not started |
| M5 | Embedded PTY terminal (SwiftTerm) | not started |
| M6 | Global hotkey (Carbon) | not started |
| M7 | .app bundling script | not started |

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

## Known issues
(none yet)

## Deferred review notes
- M4: remove the notification observers in `PanelController.deinit` when the screen-parameter observer is added (M2 review nit).
