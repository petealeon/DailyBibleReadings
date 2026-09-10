# AGENTS.md

Guidance for AI agents working on this repo.

## What this is

`peter.bible` — the Bible daily-reading bar widget for Omarchy (menu-bar
"cross" icon, daily readings, reminder, podcast read-along). Built with
Quickshell/QML. This git repo is the canonical source.

## Golden rule

**All work lives in this repo.** Edit agents here, commit here, and only
deploy outward from here. NEVER edit the live install at
`~/.config/omarchy/plugins/peter.bible/` directly (it is a copy deployed
from this repo) — changes there get lost and regress the distributable.

## How changes reach the system

- Deploy: `./install.sh` copies the plugin files to
  `~/.config/omarchy/plugins/peter.bible/` and restarts the shell.
- The live plugin is loaded by the Omarchy shell (quickshell).

## Known gotchas

- **In-session plugin reload does NOT recompile QML.** The "Local plugin
  changed, reloading" watcher re-instantiates widgets but serves previously
  compiled bytecode from `~/.cache/quickshell/qmlcache`. After editing QML,
  a full shell restart is required: `omarchy restart shell` (refuses while
  the session is locked). Only a restart reliably picks up new code.
- **Third-party widgets talk to the Bar through a `PluginBarApi` facade,**
  not the raw Bar. On it, `centerHoverRevealSuppressed` is read-only
  (mirrors the real Bar state); write it via the API method
  `bar.setCenterHoverRevealSuppressed(value)`.
- Omarchy 4.0.3+ hosts loop IPC handlers on the BarWidget (first-party
  pattern); the Panel keeps `manageIpc: false`.
- `qmllint` is at `/usr/lib/qt6/bin/qmllint` (not on PATH). Lint with:
  `/usr/lib/qt6/bin/qmllint -I /usr/share/omarchy/shell <file>.qml`
  (unresolved type/`Style` warnings are pre-existing false positives).

## Commit conventions

Conventional commits, e.g. `fix: ...`, `feat: ...`. Small focused commits.