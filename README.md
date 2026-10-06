# Poppy

A floating Liquid Glass terminal for your coding agent on macOS.

A small glass pill sits in a corner of your screen, on top of everything and on every Space, fullscreen apps included. Click it (or press **⌃⌥Space**) and it opens into a glass panel with a real terminal running your agent: Claude Code by default, or Codex, Antigravity, opencode, or any command you like. Poppy never takes focus away from the app you're in, so a fullscreen app stays fullscreen, and a click outside the panel folds it back into the pill.

- **Agent status on the pill:** blue while the agent works, orange when it needs your input, green when it's done. It can also open by itself when the agent needs you.
- **Usage meters** for Claude, Codex and Antigravity: a ring around the pill (the 5-hour limit, or for Antigravity the weekly limit of the model group in use), and % left with reset times in the panel.
- **Images and files:** paste a screenshot with ⌘V, or drag files and images onto the terminal or the pill, and the agent gets their paths.
- **A `poppy` command:** `poppy ~/code/myproject` opens the agent in that folder.

## Requirements

- **macOS 26 (Tahoe)** for the Liquid Glass look. Poppy also runs on macOS 14–15 with a frosted-glass fallback, but that is less tested.
- **Apple Silicon or Intel.** It builds natively for your Mac's chip.
- **Xcode 26, or its Command Line Tools** (Swift 6.2 and the macOS 26 SDK), to build it. Install the tools with `xcode-select --install`, or install Xcode from the App Store.
- **The agent you want to use**, installed and working in your terminal, e.g. [Claude Code](https://docs.claude.com/en/docs/claude-code) (`claude`), Codex (`codex`) or the [Antigravity CLI](https://antigravity.google) (`agy`).

## Install

```sh
git clone https://github.com/dquigles/poppy.git
cd poppy
./scripts/install.sh
```

This builds Poppy and installs:

- **`Poppy.app`** in `/Applications`, or `~/Applications` if `/Applications` isn't writable.
- **The `poppy` command** in `~/.local/bin`. If that folder isn't on your `PATH`, the script tells you the line to add to `~/.zshrc`.

It then starts Poppy. To update later, run `git pull` and `./scripts/install.sh` again.

You can put things elsewhere: `APP_DIR=~/Applications BIN_DIR=/usr/local/bin ./scripts/install.sh`.

Because you build Poppy yourself, macOS runs it without any "unidentified developer" warning. No paid Apple Developer account is involved.

macOS asks whether Poppy may access your Desktop or Documents folders when the agent works there (the agent runs inside Poppy, so its file access counts as Poppy's). If you have an Apple Development certificate (Xcode creates one for free when you sign in with your Apple ID under Xcode → Settings → Accounts), the build is signed with it and macOS remembers your answers across updates; otherwise it may ask again after each rebuild. Set `POPPY_SIGN_IDENTITY` to choose a certificate, or `-` to skip signing with one.

To start Poppy at login, add it in **System Settings → General → Login Items**.

## Using it

- **Click the pill**, or press **⌃⌥Space**, to open the panel. Click outside it, or press the hotkey again, to fold it back.
- **Drag the pill** to any corner or edge. The panel opens from the corner it's closest to.
- **Resize** the open panel by dragging its edges.
- **Right-click the pill** (or use Poppy's menu bar icon) for everything else:
  - switch agent, change working folder, restart the agent
  - Auto-Open (open when the agent needs input and/or is done)
  - pill size, show usage, set the hotkey, quit

### The `poppy` command

```text
poppy [options] [directory]

Opens Poppy with the agent in <directory> (default: the current directory).
Options are saved, like changing them in Poppy's menu.

  -a, --agent NAME        claude, codex, agy, opencode, or an agent name from config.json
  -c, --command CMD       run CMD (any shell command) as the agent
      --pill SIZE         small, medium or large
      --auto-open WHEN    input, done, both or off
      --focus             Auto-Open takes the keyboard
      --no-focus          Auto-Open only shows the panel
      --usage             show usage
      --no-usage          hide usage
  -b, --background        don't expand the panel
  -h, --help              show this help
```

## Configuration

Settings live in `~/.config/poppy/config.json`, created on first launch. Most of them are also in the menu. Some examples:

```json
{
  "command": "claude",
  "cwd": "~",
  "hotkey": "ctrl+opt+space",
  "agents": [
    { "name": "Claude (skip perms)", "command": "claude --dangerously-skip-permissions" }
  ]
}
```

- `command` is a shell command, run through your login shell, so your `PATH`, aliases and functions work.
- `agents` adds extra entries to the Agent menu.
- `"statusHooks": false` turns off status reporting (see below).

Poppy reads this file when it starts, so restart Poppy after editing it.

## What Poppy touches on your system

- **Status hooks.** To show the agent's status, Poppy adds small hooks to each agent's config. Each hook only writes one word to a file Poppy gives it, and does nothing when the agent isn't running inside Poppy.
  - Claude Code: a separate settings file, `~/.config/poppy/claude-hooks.json`, passed with `--settings`. Your own settings are untouched.
  - Codex: entries appended to `~/.codex/hooks.json`. Codex asks you once to approve them.
  - Antigravity: a plugin, `~/.gemini/config/plugins/poppy-status/`. That folder is shared with the Antigravity desktop app and IDE, where the plugin does nothing. Antigravity has no hook for "waiting for you", so its pill never turns orange: it stays blue while Antigravity asks you to approve a command, and idle while it asks whether to trust a new folder.
  - opencode: a plugin, `~/.config/opencode/plugins/poppy-status.ts`.
  - It only adds entries; it never removes or changes yours. Turn this off with **Agent status** in Settings (or `"statusHooks": false`).
- **Usage meters.**
  - For Claude, Poppy runs Claude Code's own `/usage` command (`claude -p /usage`): no model call, not saved as a session, and with your user settings skipped, so hooks in your own Claude Code settings don't fire for it (organization-managed settings still apply). Poppy never reads your Claude login.
  - For Codex, it asks `codex app-server` for its rate limits.
  - For Antigravity, it runs `agy -p /usage` (no model call), only after checking that `agy` is signed in (it looks for `agy`'s login in your Keychain by name, without reading it), since a signed-out `agy` would open a browser sign-in page.
  - Turn the meters off with **Show usage meters** in Settings (**Settings…** in the menu, or ⌘, in the panel).
- **Pasted and dropped images** are saved as PNGs in a private temporary folder and deleted after a week.

Poppy needs no special permissions (no Accessibility, Screen Recording or Input Monitoring).

## Uninstall

```sh
pkill -x poppy
rm -rf /Applications/Poppy.app ~/.local/bin/poppy ~/.config/poppy ~/.gemini/config/plugins/poppy-status
```

Then remove Poppy's hook entries from `~/.codex/hooks.json` if you used Codex: each entry mentions `POPPY_STATUS_FILE`. Also delete `~/.config/opencode/plugins/poppy-status.ts` if it's there.

## Development

```sh
swift build        # debug build
swift run          # run from the terminal, with logs on stderr
./scripts/bundle.sh   # build build/Poppy.app (ad-hoc signed)
```

The design and its reasoning live in [`docs/DESIGN.md`](docs/DESIGN.md), and milestone history in [`docs/PROGRESS.md`](docs/PROGRESS.md).

## License

[MIT](LICENSE). The agent logos in `Resources/Logos` are from [lobe-icons](https://github.com/lobehub/lobe-icons); their license is in `Resources/Logos/src/LICENSE-lobe-icons`.
