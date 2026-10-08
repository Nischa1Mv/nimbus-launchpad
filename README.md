# nimbus-launchpad

Local dev tooling for Nimbus and Nimbus+Meredian projects. Two parts in one repo:

- `shared-infra/`: one shared Docker stack (postgres, minio, mailpit, cognito-local) plus `run-project.sh`, which sets up and starts any Nimbus project against it. Plain bash; works on any Linux. See `shared-infra/README.md`.
- Repo root: the Omarchy UI (`manifest.json`, `Ports.qml`, `list-ports.sh`). A popup (Omarchy shell plugin) that lists listening ports, stops containers, and starts/stops project backends and frontends through `run-project.sh`.

## Platform support

| Part | Status |
|---|---|
| CLI (`shared-infra/run-project.sh`) | Any Linux (x86_64) |
| UI | **Omarchy** only today (Quickshell + Hyprland) |
| UI for other desktops / OSes | Coming soon |

Open-source contributions are welcome and encouraged, especially UIs for other platforms (Arch + plain Hyprland, Ubuntu/GNOME, KDE, other Wayland/X11 setups, a TUI, a web UI, macOS). The UI only calls `list-ports.sh` (JSON in, start/stop commands out) and each platform has its own installer adapter, so a new front end does not touch the infra scripts. Start with `platforms/README.md`, then open an issue or a pull request.

## Setup

### Omarchy (UI + CLI)

```
omarchy plugin add https://github.com/Nischa1Mv/nimbus-launchpad.git --enable --yes
~/.config/omarchy/plugins/nimbus.launchpad/install.sh
```

`install.sh` saves your config (the folder that contains your Nimbus projects) and adds the shortcut **SUPER + ALT + P** to `~/.config/hypr/bindings.lua` (it asks first, and skips the key if it is already taken). You can also skip the config question: open the popup with the shortcut, and the **Nimbus** tab shows a first-run setup panel where you paste the folder and press Save.

- Open the popup: **SUPER + ALT + P** (change the key in `bindings.lua`).
- Update: `omarchy plugin update nimbus.launchpad`.
- Flags: `./install.sh <nimbus-dir> [personal-dir] [--yes] [--no-bind]`.
- Omarchy warns that plugins run unsandboxed inside the shell; read the code before enabling.

### Any other Linux (CLI only)

```
git clone https://github.com/Nischa1Mv/nimbus-launchpad && cd nimbus-launchpad
./install.sh ~/work/Nimbus        # saves config, no UI adapter for your desktop yet
shared-infra/run-project.sh <project-dir> [backend|frontend|all]
```

`install.sh` picks a platform adapter from `platforms/` automatically (see `platforms/README.md` for how to add Arch + Hyprland, Ubuntu/GNOME, KDE and others). Config is `~/.config/nimbus-launchpad/config` (`NIMBUS_DIR`, optional `PERSONAL_DIR`).

### Requirements

`docker`, `gh` (run `gh auth login`; the account needs access to the `aegion-dynamic` repos, and to this repo while it is private), `psql`, `atlas`, `jq`, `lsof`, `npm`. Release downloads are `Linux_x86_64` only. The popup's setup panel lists any of these that are missing.
