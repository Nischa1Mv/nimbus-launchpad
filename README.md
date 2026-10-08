# Omarchy-Customapp

Local dev tooling for Nimbus and Nimbus+Meredian projects. Two parts in one repo:

- `shared-infra/`: one shared Docker stack (postgres, minio, mailpit, cognito-local) plus `run-project.sh`, which sets up and starts any Nimbus project against it. Plain bash; works on any Linux. See `shared-infra/README.md`.
- `nischal.ports/`: Ctrl+P popup (Omarchy shell plugin) that lists listening ports, stops containers, and starts/stops project backends and frontends through `run-project.sh`. Omarchy only (Quickshell + Hyprland).

## Setup

```
git clone https://github.com/Nischa1Mv/Omarchy-Customapp && cd Omarchy-Customapp
./install.sh                      # asks for the folder that contains your Nimbus projects
./install.sh ~/work/Nimbus        # or pass it directly (second arg: optional personal projects folder)
```

`install.sh` writes `~/.config/nimbus-dev/config` (`NIMBUS_DIR`, optional `PERSONAL_DIR`). On Omarchy it also links the popup plugin and prints the keybind line to add. Without Omarchy it only writes the config.

Then, on any Linux:

```
shared-infra/run-project.sh <project-dir> [backend|frontend|all]
```

Requirements: `docker`, `gh` (logged in with access to `aegion-dynamic`), `psql`, `atlas`, `jq`, `lsof`, `npm`. Release downloads are `Linux_x86_64` only.
