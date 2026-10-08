# Platform adapters

`install.sh` saves the user config (core, identical on every OS), then runs **one adapter** from this folder.
An adapter wires the launchpad UI and a shortcut into one desktop environment. The CLI
(`shared-infra/run-project.sh`) needs no adapter and works on any Linux.

## Existing

| id | Desktop | What it does |
|---|---|---|
| `omarchy` | Omarchy (Hyprland + Quickshell) | links/enables the shell plugin, adds `SUPER + ALT + P` |
| `generic` | anything else | fallback: prints how to use the CLI |

## Planned / wanted

| id | Desktop | Notes |
|---|---|---|
| `arch-hyprland` | Arch + plain Hyprland (e.g. Celestia dots) | UI toolkit + `hyprland.conf` keybind |
| `ubuntu-gnome` | Ubuntu / GNOME | GNOME extension or GTK app, gsettings shortcut |
| `kde` | KDE Plasma | Plasmoid or Qt app, KGlobalAccel shortcut |
| `tui` / `web` | any terminal / any browser | desktop-independent front ends |

## Adding a platform

1. Create `platforms/<id>/detect.sh`: exit 0 when this adapter fits the current machine (the first match wins, `generic` is the fallback).
2. Create `platforms/<id>/install.sh`: install/enable your UI and add a shortcut. Env provided: `REPO` (repo root), `YES=1` (no prompts), `NO_BIND=1` (skip the shortcut). Be idempotent and never edit existing user config lines (append a marked block).
3. Put your UI code under `ui/<id>/` (the Omarchy plugin sits at the repo root only because `omarchy plugin add` requires `manifest.json` there).
4. Talk to the backend only through `list-ports.sh` (below). Do not duplicate infra logic in the UI.

## The UI contract: `list-ports.sh`

All commands print JSON (or nothing) and are safe to poll.

| Command | Output / effect |
|---|---|
| `--json` | listening TCP ports: `[{port, process, pid, project, stop}]` (`stop` = container name or `shared-infra` when stoppable) |
| `--count` | number of listening ports |
| `--nimbus-json` / `--personal-json` | projects: `[{name, path, kind, hasBackend, hasFrontend, backendRunning, frontendRunning, backendPid, frontendPid}]` |
| `--setup-status` | `{configured, nimbusDir, personalDir, missing:[tools]}` for a first-run panel |
| `--save-config <nimbus-dir> [personal-dir]` | validate and write the user config |
| `--background --start-backend <dir>` / `--start-frontend <dir>` | start detached; log in `~/.local/state/nimbus-launchpad/logs/<project>-<backend|frontend>.log` |
| `--stop <container\|shared-infra>` | stop a container / the whole shared stack |
| `--infra-status` | `{running}` |

Config lives in `~/.config/nimbus-launchpad/config` (`NIMBUS_DIR`, `PERSONAL_DIR`); override the path with `NIMBUS_DEV_CONFIG`.
