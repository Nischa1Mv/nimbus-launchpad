#!/usr/bin/env bash
# nimbus-launchpad installer: saves your config, then hands off to the adapter for your platform.
#
#   ./install.sh [nimbus-dir] [personal-dir] [--yes] [--no-bind] [--platform <id>]
#
# 1. Config (core, same on every OS): NIMBUS_DIR / PERSONAL_DIR -> ~/.config/nimbus-launchpad/config
# 2. Platform adapter (platforms/<id>/): wires up the UI + shortcut for your desktop.
#    The first adapter whose detect.sh succeeds runs; `generic` is the fallback (CLI only).
#
# Adding a platform: see platforms/README.md.
set -euo pipefail

REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
export REPO

YES=0 NO_BIND=0 PLATFORM="" dirs=()
while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) YES=1 ;;
    --no-bind) NO_BIND=1 ;;
    --platform) PLATFORM="${2:?--platform needs an id}"; shift ;;
    -*) echo "unknown option: $1" >&2; exit 1 ;;
    *) dirs+=("$1") ;;
  esac
  shift
done
export YES NO_BIND

# --- 1. config ------------------------------------------------------------------------------
CONFIG="${NIMBUS_DEV_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/nimbus-launchpad/config}"
[ -f "$CONFIG" ] && . "$CONFIG"
nimbus="${dirs[0]:-${NIMBUS_DIR:-}}"; personal="${dirs[1]:-${PERSONAL_DIR:-}}"
if [ -z "$nimbus" ] && [ -t 0 ] && [ "$YES" = 0 ]; then
  read -r -e -i "${NIMBUS_DIR:-}" -p "Folder that contains your Nimbus projects (e.g. ~/work/Nimbus): " nimbus
  read -r -e -i "${PERSONAL_DIR:-}" -p "Folder with personal projects (.devports files), empty to skip: " personal
fi
if [ -n "$nimbus" ]; then
  "$REPO/list-ports.sh" --save-config "$nimbus" "$personal"
else
  echo "No projects folder given: skipped. Set it later in the popup's setup panel or re-run ./install.sh <dir>."
fi

# --- 2. platform adapter ------------------------------------------------------------------
chosen="$PLATFORM"
if [ -z "$chosen" ]; then
  for d in "$REPO"/platforms/*/; do
    id="$(basename "$d")"
    [ "$id" = generic ] && continue
    if [ -f "$d/detect.sh" ] && bash "$d/detect.sh" >/dev/null 2>&1; then chosen="$id"; break; fi
  done
fi
chosen="${chosen:-generic}"
[ -f "$REPO/platforms/$chosen/install.sh" ] || { echo "no such platform adapter: $chosen" >&2; exit 1; }
echo "==> platform: $chosen"
exec bash "$REPO/platforms/$chosen/install.sh"
