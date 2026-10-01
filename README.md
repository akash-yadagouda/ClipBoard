# clipboard-manager

A tiny clipboard history tool for macOS. It runs from Terminal (or at login),
records what you copy, and opens a small search window on **⌘⇧V**. Pick an
entry and it goes back on the clipboard, ready for **⌘V**.

No GUI app, no Dock icon, no network, no dependencies beyond the macOS SDK.

```
copy things  →  ⌘⇧V  →  type to search  →  ↑/↓  →  Enter  →  ⌘V
```

## Requirements

- macOS 12 or later
- Swift toolchain: Xcode or the Command Line Tools (`xcode-select --install`)

## Build

```sh
./build.sh          # produces build/clipboard-manager
./test.sh           # builds and runs the tests
```

## Install

```sh
./install.sh                  # installs to ~/.local/bin/clipboard-manager
./install.sh --launch-agent   # same, and start automatically at every login
PREFIX=/usr/local ./install.sh   # install to /usr/local/bin instead (may need sudo)
```

If `~/.local/bin` isn't on your `PATH`, the installer prints the line to add to `~/.zshrc`.

## Start

```sh
clipboard-manager          # foreground; Ctrl+C to stop
clipboard-manager start    # background; survives closing the Terminal window
```

Foreground output:

```
Clipboard Manager started.

Monitoring clipboard...
Press ⌘⇧V to open the picker.
Press Ctrl+C to stop.
```

Only one instance runs at a time.

## Global shortcut

**⌘⇧V** opens the picker from any app. It is registered with the Carbon
`RegisterEventHotKey` API, which needs **no Accessibility or Input Monitoring
permission**.

| Key        | Action                                |
| ---------- | ------------------------------------- |
| type       | filter (case-insensitive, substring)  |
| ↑ / ↓      | move selection                        |
| Enter      | copy the selected item, close picker  |
| ⌘⌫         | delete the selected item from history |
| Esc        | close (also closes if you click away) |

The picker has the history list on the left and a large **preview pane** on
the right: the full text (up to 50,000 characters, scrollable and selectable)
or the image scaled to fit, with its size and copy time underneath. Images and
text are both searchable (images match on their description, e.g. `Image 800×600`).

The picker is a non-activating panel, so keyboard focus returns to the app you
were in as soon as it closes. Then press ⌘V.

If another app already owns ⌘⇧V, the manager prints a warning; use
`clipboard-manager show` (bind it to anything you like) to open the picker.

## Commands

| Command                      | What it does                                             |
| ---------------------------- | -------------------------------------------------------- |
| `clipboard-manager`          | Monitor in the foreground                                |
| `clipboard-manager start`    | Monitor in the background                                |
| `clipboard-manager stop`     | Stop the running manager                                 |
| `clipboard-manager status`   | Running or not, history size, data location              |
| `clipboard-manager show`     | Open the picker (same as ⌘⇧V)                            |
| `clipboard-manager history [n]` | Print the *n* most recent entries (default 20)        |
| `clipboard-manager clear`    | Delete all history, after a `[y/N]` confirmation (`-y` skips it) |

## What is captured

- Plain text, and text that is a single URL (tagged as a URL)
- Images (PNG/TIFF), up to 10 MB; shown as `[Image 800×600]`
- Consecutive duplicates are not stored; copying something you copied earlier moves it to the top
- Items marked concealed/transient by the source app (password managers follow
  the nspasteboard.org convention) are **not** recorded

Text wins when the clipboard has both text and an image. Rich text, files, and
other formats are not preserved — only the plain-text or image representation.

## Configuration

History keeps the newest **1000** items by default. To change it, create
`~/Library/Application Support/clipboard-manager/config.json`:

```json
{ "maxItems": 500 }
```

and restart the manager. `CLIPBOARD_MANAGER_HOME` overrides the data directory.

## Where data is stored

Everything lives in `~/Library/Application Support/clipboard-manager/`
(directory mode `0700`, files `0600`):

- `history.sqlite` — the history (SQLite)
- `clipboard-manager.pid` — lock/PID file
- `clipboard-manager.log` — startup/error messages only

## Privacy

- Nothing leaves your Mac: no network code, no analytics, no cloud.
- Clipboard contents are never written to logs or printed, except by the
  explicit `history` command.
- History is **not encrypted** (it relies on file permissions and FileVault).
  Anything that isn't marked concealed by its source app — including a password
  you copy from a page that doesn't set that marker — will be stored in plain
  text until it ages out or you run `clipboard-manager clear`.
- Deleted rows are zeroed in the database file (`secure_delete`).

## macOS permissions and limitations

- **No special permissions** are required for monitoring, the shortcut, or the picker.
- macOS 15.4+ may show a one-time "allow *Terminal* to paste from other apps"
  prompt for programmatic pasteboard reads, depending on your Privacy settings.
  If clipboard capture stops working, check **System Settings → Privacy & Security → Paste from Other Apps**.
- The clipboard is polled every 0.5 s (NSPasteboard has no change notification).
  Two copies within the same half-second record only the last one.
- The picker does not paste for you — it restores the item to the clipboard and
  you press ⌘V. (Auto-pasting would require Accessibility permission.)
- Some apps with secure input enabled (e.g. a focused password field) can block global hotkeys.

## Launch at login

`./install.sh --launch-agent` installs `~/Library/LaunchAgents/com.clipboard-manager.plist`
(template in [`launchd/`](launchd/)). launchd restarts the manager if it crashes.

## Uninstall

```sh
./uninstall.sh            # remove binary and launch agent, keep history
./uninstall.sh --purge    # also delete clipboard history
```

## Project layout

```
Sources/Core/   clipboard capture, SQLite store, monitor, config (shared with tests)
Sources/App/    CLI, daemon/process control, hotkey, picker window
Tests/          test runner (plain executable; no XCTest needed)
```
