#!/usr/bin/env bash
# Install (or remove) the peter.bible Omarchy shell plugin.
#
# Usage:
#   ./install.sh            install + enable the widget
#   ./install.sh --remove   uninstall
#
# Prefer `omarchy plugin add <git-url> --enable` when the plugin lives in a
# git repo; this script is the manual, no-git fallback and does the same job.

set -euo pipefail

PLUGIN_ID="peter.bible"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${HOME}/.config/omarchy/plugins/${PLUGIN_ID}"
SHELL_JSON="${HOME}/.config/omarchy/shell.json"

fail() { echo "install.sh: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

command -v omarchy >/dev/null 2>&1 || fail "omarchy not found — this installer targets Omarchy systems"

remove() {
  if omarchy plugin list 2>/dev/null | grep -q "^${PLUGIN_ID}$"; then
    omarchy plugin remove "$PLUGIN_ID" --yes || fail "omarchy plugin remove failed"
  elif [[ -d $DEST ]]; then
    rm -rf "$DEST"
    omarchy restart shell
  fi
  echo "Removed $PLUGIN_ID."
  exit 0
}

[[ ${1:-} == "--remove" ]] && remove

# ---- dependencies -----------------------------------------------------------
missing=()
for dep in mpv socat curl wl-copy; do
  have "$dep" || missing+=("$dep")
done
if (( ${#missing[@]} > 0 )); then
  echo "Missing dependencies: ${missing[*]}"
  echo "Install them with: omarchy pkg add ${missing[*]}"
  fail "install dependencies first"
fi

# ---- files ------------------------------------------------------------------
for f in manifest.json BarWidget.qml Panel.qml Model.js; do
  [[ -f $SRC/$f ]] || fail "missing $SRC/$f — run this from the plugin repo"
done

mkdir -p "$DEST"
for f in manifest.json BarWidget.qml Panel.qml Model.js; do
  cp "$SRC/$f" "$DEST/$f"
done
echo "Installed plugin files into $DEST"

# ---- enable + place ---------------------------------------------------------
# Already on the bar? (omarchy plugin enable refuses duplicates; check first.)
if [[ -f $SHELL_JSON ]] && command -v jq >/dev/null 2>&1 &&
  jq -e --arg id "$PLUGIN_ID" '.bar.layout[][]? | select(.id == $id)' \
    "$SHELL_JSON" >/dev/null 2>&1; then
  echo "Widget already on the bar — refreshing placement"
  omarchy bar put "$PLUGIN_ID" --section center
else
  omarchy plugin enable "$PLUGIN_ID" --section center
fi

omarchy restart shell
echo "Done — look for the cross in the centre of the menu bar."
