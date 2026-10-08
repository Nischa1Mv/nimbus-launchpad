# Omarchy-Customapp

Local dev tooling for Nimbus and Nimbus+Meredian projects on an Omarchy (Hyprland + Quickshell) machine.

- `shared-infra/`: one shared Docker stack (postgres, minio, mailpit, cognito-local) plus `run-project.sh`, which sets up and starts any Nimbus project against it. Plain bash; works on any Linux. See `shared-infra/README.md`.
- `nischal.ports/`: Ctrl+P popup (Omarchy shell plugin) that lists listening ports, stops containers, and starts/stops project backends and frontends through `run-project.sh`. Omarchy only.

Install notes:

- Plugin: symlink `nischal.ports` into `~/.config/omarchy/plugins/` and bind a key to `omarchy-shell shell toggle nischal.ports`.
- Infra path: the plugin and the `nimbus-shared-infra` workflow expect this repo's `shared-infra/` at `/mnt/Work/work/Nimbus/shared-infra` (a symlink here).
