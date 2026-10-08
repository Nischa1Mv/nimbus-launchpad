#!/usr/bin/env bash
# Omarchy adapter: link + enable the shell plugin, optionally add the SUPER+ALT+P shortcut.
# Env from install.sh: REPO, YES (1 = no prompts), NO_BIND (1 = skip the shortcut).
set -euo pipefail

ID="nimbus.launchpad"
PLUGINS="$HOME/.config/omarchy/plugins"
KEY="SUPER + ALT + P"
BINDINGS="$HOME/.config/hypr/bindings.lua"
MARK="-- nimbus-launchpad (managed by install.sh)"

# 1. plugin link (skipped when `omarchy plugin add` already cloned the repo there)
mkdir -p "$PLUGINS"
if [ "$(readlink -f "$PLUGINS/$ID")" != "$REPO" ]; then
  ln -sfn "$REPO" "$PLUGINS/$ID"
  echo "linked $PLUGINS/$ID"
fi

# 2. enable
omarchy-shell -q shell rescanPlugins || true
if command -v omarchy >/dev/null 2>&1 && omarchy plugin enable "$ID" >/dev/null 2>&1; then
  echo "enabled $ID"
elif command -v jq >/dev/null 2>&1 && [ -f "$HOME/.config/omarchy/shell.json" ]; then
  sj="$HOME/.config/omarchy/shell.json"
  jq -e --arg id "$ID" '.plugins[]? | select(.id==$id)' "$sj" >/dev/null ||
    { jq --arg id "$ID" '.plugins = ((.plugins // []) + [{"id":$id}])' "$sj" >"$sj.tmp" && mv "$sj.tmp" "$sj"; }
  echo "enabled $ID in shell.json"
fi

# 3. shortcut
[ "${NO_BIND:-0}" = 1 ] && { echo "skipped shortcut (--no-bind)"; exit 0; }
if [ -f "$BINDINGS" ] && grep -qF -- "$MARK" "$BINDINGS"; then
  echo "shortcut already installed ($KEY)"; exit 0
fi
# `omarchy menu keybindings --print` shows "SUPER ALT + P": modifiers space-joined, then " + key"
printed="${KEY% + *}"; printed="${printed// + / } + ${KEY##* + }"
taken="$(omarchy menu keybindings --print 2>/dev/null | grep -iF "$printed " | head -1 || true)"
if [ -n "$taken" ]; then
  echo "shortcut $KEY is already used ($taken): skipped. Add your own bind to $BINDINGS:"
  echo "  o.bind(\"<KEY>\", \"Nimbus Launchpad\", \"omarchy-shell shell toggle $ID\")"
  exit 0
fi
ans=y
if [ "${YES:-0}" != 1 ] && [ -t 0 ]; then read -r -p "Add shortcut $KEY to $BINDINGS? [Y/n] " ans; fi
case "${ans:-y}" in
  n|N) echo "skipped. Add manually: o.bind(\"$KEY\", \"Nimbus Launchpad\", \"omarchy-shell shell toggle $ID\")" ;;
  *)
    mkdir -p "$(dirname "$BINDINGS")"
    printf '\n%s\no.bind("%s", "Nimbus Launchpad", "omarchy-shell shell toggle %s")\n' "$MARK" "$KEY" "$ID" >>"$BINDINGS"
    echo "added $KEY to $BINDINGS (change the key there any time)"
    ;;
esac
