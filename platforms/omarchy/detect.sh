#!/usr/bin/env bash
# Omarchy = omarchy-shell present and a user config dir.
command -v omarchy-shell >/dev/null 2>&1 && [ -d "$HOME/.config/omarchy" ]
