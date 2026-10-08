#!/usr/bin/env bash
# Point this tool at your Nimbus projects folder and install the Ctrl+P popup.
#
#   ./install.sh [nimbus-projects-dir] [personal-projects-dir]
#
# Writes ~/.config/nimbus-dev/config (NIMBUS_DIR, optional PERSONAL_DIR). Re-run any time to change it.
# The popup part is Omarchy-only; shared-infra/run-project.sh works on any Linux without it.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${NIMBUS_DEV_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/nimbus-dev/config}"
[ -f "$CONFIG" ] && . "$CONFIG"

nimbus="${1:-}"
if [ -z "$nimbus" ]; then
  read -r -e -i "${NIMBUS_DIR:-}" -p "Folder that contains your Nimbus projects (e.g. ~/work/Nimbus): " nimbus
fi
nimbus="$(cd "${nimbus/#\~/$HOME}" 2>/dev/null && pwd)" || { echo "error: not a folder" >&2; exit 1; }

personal="${2:-}"
if [ -z "$personal" ] && [ -t 0 ]; then
  read -r -e -i "${PERSONAL_DIR:-}" -p "Folder with personal projects (.devports files), empty to skip: " personal
fi
[ -z "$personal" ] || personal="$(cd "${personal/#\~/$HOME}" 2>/dev/null && pwd)" || { echo "error: not a folder" >&2; exit 1; }

mkdir -p "$(dirname "$CONFIG")"
printf 'NIMBUS_DIR=%q\nPERSONAL_DIR=%q\n' "$nimbus" "$personal" >"$CONFIG"
echo "wrote $CONFIG"

# Optional: Omarchy popup plugin
plugins="$HOME/.config/omarchy/plugins"
if [ -d "$HOME/.config/omarchy" ]; then
  mkdir -p "$plugins"
  ln -sfn "$REPO/nimbus.ports" "$plugins/nimbus.ports"
  echo "linked $plugins/nimbus.ports"
  shell_json="$HOME/.config/omarchy/shell.json"
  if [ -f "$shell_json" ] && command -v jq >/dev/null && ! jq -e '.plugins[]? | select(.id=="nimbus.ports")' "$shell_json" >/dev/null; then
    jq '.plugins = ((.plugins // []) + [{"id":"nimbus.ports"}])' "$shell_json" >"$shell_json.tmp" && mv "$shell_json.tmp" "$shell_json"
    echo "enabled nimbus.ports in $shell_json"
  fi
  echo "Add this to ~/.config/hypr/bindings.lua, then restart the shell (omarchy-restart-app quickshell):"
  echo '  o.bind("CTRL + P", "Ports", "omarchy-shell shell toggle nimbus.ports")'
else
  echo "Omarchy not found: skipped the popup. Use: $REPO/shared-infra/run-project.sh <project-dir>"
fi
