# Nimbus shared dev infra

One Docker stack runs the infra for **every** Nimbus and Nimbus+Meredian project on this machine. One script starts any project against it.

```
shared-infra/run-project.sh <project-dir> [backend|frontend|all]
```

Same thing from the Ctrl+P ports popup (plugin `nischal.ports`): its Backend / Frontend **Start** buttons call this script.

## Contents

1. [The two stacks](#the-two-stacks)
2. [Shared infra](#shared-infra)
3. [Quick start](#quick-start)
4. [What `run-project.sh` does](#what-run-projectsh-does)
5. [Nimbus projects (template style)](#nimbus-projects-template-style)
6. [Nimbus + Meredian projects](#nimbus--meredian-projects)
7. [Databases](#databases)
8. [Troubleshooting](#troubleshooting)
9. [Files](#files)

## The two stacks

The script decides which one a project is by reading `backend/version.json`.

The reference for **Nimbus** is `nimbus-apps-template-v2`; other standalone Nimbus projects are expected to look like it. The reference for **Nimbus + Meredian** is `mosambi`.

| | **Nimbus** (`nimbus-apps-template-v2` style) | **Nimbus + Meredian** (`mosambi` style) |
|---|---|---|
| Detected by | `nimbus_version` in `version.json` | `meredian_version` in `version.json` |
| Projects | nimbus-apps-template-v2, and the standalone projects as they move to the template (pace-hr, evergreen-artha, green-fuels, purchase-orders-app, smi-project, document-id-generator, instrumentation-management-system-v2) | mosambi |
| Backend binary | `nimbus-backend` | `meridian-engine` |
| Migrate / seed tool | `nimbus-migrate` (same release as the backend) | `nimbus-migrate` (separate release, version in `nimbus_migrate_version`) |
| Rust library | `backend/libs/linux_amd64/librust.so` | `backend/libs/linux_amd64/librust.so` |
| Downloaded from | `aegion-dynamic/framework-backend` | Backend + lib: `aegion-dynamic/meredian`. `nimbus-migrate`: `aegion-dynamic/framework-backend` |
| Release asset | `framework-backend_Linux_x86_64.tar.gz` | `meridian_Linux_x86_64.tar.gz` (+ `framework-backend_nimbus-migrate_Linux_x86_64.tar.gz` for the migrate tool) |
| Version keys | `nimbus_version` | `meredian_version` and `nimbus_migrate_version` |
| `nimbus-migrate` style | plain flags: `-config ... -env ...` | subcommand: `seed --config ... --env ...` |
| `.devcontainer/.env` | **committed** in git | **git-ignored** (copied from `.env.example`) |
| Backend start | `make start-backend` | `make start-backend` (runs only `./meridian-engine`; the Nimbus core is inside it) |
| Frontend start | `make start-frontend-dev` (Next.js, :3000) | `make start-frontend-dev` (Next.js, :3000) |
| Infra | shared infra | the **same** shared infra |

The infra, ports, database layout and start commands are identical. The differences are the binaries, where they come from, the `nimbus-migrate` call style, and whether `.devcontainer/.env` is tracked. The script handles all of them.

## Shared infra

One compose project, `nimbus-shared` (`docker-compose.yml`), all containers on host networking:

| Service | Port(s) |
|---|---|
| postgres | 5432 |
| minio (S3 API / web console) | 9000 / 9001 |
| mailpit (SMTP / web UI) | 1025 / 8025 |
| cognito-local | 9229 |

The app ports are 8080 (backend) and 3000 (frontend). Only one project runs at a time.

Every project's own `.devcontainer/docker-compose.yml` (with its `PROJECT_NAME_postgres-data` style volumes) is **not** used by this flow. The shared stack replaces it, so there is one set of containers instead of one per project.

Manual control:

```
docker compose -p nimbus-shared -f shared-infra/docker-compose.yml up -d     # start
docker compose -p nimbus-shared -f shared-infra/docker-compose.yml stop      # stop, keep data
```

The popup's Ports tab also shows a **Stop** button on any row owned by a container.

## Quick start

```
# any project, either stack
shared-infra/run-project.sh $NIMBUS_DIR/nimbus-apps-template-v2 all
shared-infra/run-project.sh $NIMBUS_DIR/mosambi all

# only one half
shared-infra/run-project.sh <project-dir> backend      # stays in the foreground
shared-infra/run-project.sh <project-dir> frontend
```

- `all` starts backend and frontend in the background (logs in `<project>/.devcontainer/logs/`) and waits until :8080 answers.
- `backend` and `frontend` run the make target in the foreground, so a caller (the popup) can track and kill the process.
- `shared-infra/start-project.sh [dir]` is the same as `run-project.sh <dir> all`.

Requirements: `docker`, `gh` (logged in with access to the `aegion-dynamic` repos), `psql`, `atlas`, `jq`, `lsof`, `npm`.

## What `run-project.sh` does

Every step runs only when needed, so a second start is fast. You never need to run `make dev`, `make build-backend` or `make migrate` by hand.

1. **Shared infra up.** `docker compose up -d`, then waits for ports 5432, 9000 and 9229. Any other stack holding those ports (for example `ruchi-meredian`) must be stopped first.
2. **Database for this project.** Name = project folder, lowercased, dashes become underscores (`pace-hr` becomes `pace_hr`). The script writes `POSTGRES_DB` into `.devcontainer/.env` and creates the database if it does not exist. A leftover `POSTGRES_HOSTNAME=db` is changed to `localhost`.
   - **Nimbus (tracked `.env`):** the script marks the file `git update-index --skip-worktree`, so the local DB name stays out of `git status` and cannot be committed by accident (see Troubleshooting for pulls).
   - **Meredian (ignored `.env`):** nothing extra; the file is already ignored by git.
3. **Backend binaries.** Checks that the backend binary, `nimbus-migrate` and `librust.so` exist and match `backend/version.json`. If anything is missing or the version changed, it runs the project's own `make build-backend`. The installed version is remembered in `.devcontainer/logs/.backend-version`.
4. **First-time setup of a database.** `atlas migrate apply --env remote`, then the RBAC and super-admin seed with `nimbus-migrate`. When both succeed the database gets the comment `nimbus-seeded`. Without that comment, the next start repeats this step.
5. **Frontend files.** Writes `frontend/.env.local` if missing, and runs `npm ci` if `frontend/node_modules` is missing.
6. **Start.** Frees :8080 and/or :3000 (kills whatever listens there), then runs `make start-backend` and `make start-frontend-dev`. With `all`, on a freshly set-up database, it also runs `make seed-users` (sample logins) if the project has that target. The template does not, so it is skipped there.

`start-backend-dev.sh` (part of each project) also runs `offline-auth.sh` before every backend start. That wires the JWT config to the cognito-local pool and turns `auth-enabled: true` on in `backend/config/nimbus-dev.yaml`. Expect that tracked file to show as modified; it is a project script, not part of this flow.

## Nimbus projects (template style)

Reference: `nimbus-apps-template-v2`.

`backend/version.json`:

```json
{ "nimbus_version": "v0.10.2-snapshot.20260727-072159" }
```

What is in the project:

- `.devcontainer/` with `build-backend.sh`, `start-backend-dev.sh`, `offline-auth.sh`, `dev-up.sh`, `lib.sh`, `docker-compose.yml`, `cognito-seed/`.
- `.devcontainer/.env` is **committed**. Defaults: `POSTGRES_HOSTNAME=localhost`, S3 on `localhost:9000`, Cognito pool `local_nimbus01` at `localhost:9229`, SMTP on `localhost:1025`, `SUPERADMIN_EMAIL=admin@example.com`.
- The `Makefile` has `build-backend`, `start-backend`, `start-frontend-dev`, `dev`, `restart`, but no `seed-users` and no `FRAMEWORK_BACKEND_REF` handling.

How the binaries get there:

- `make build-backend` downloads `framework-backend_Linux_x86_64.tar.gz` from the `framework-backend` release named by `nimbus_version` and unpacks it into `backend/`. You get `nimbus-backend`, `nimbus-migrate` and `libs/linux_amd64/librust.so`.
- This uses `gh`, so `gh auth login` with access to `aegion-dynamic/*` is required once. The download is about 56 MB and prints nothing while it runs.

The backend starts by running `./nimbus-backend` with the `GJ_DATABASE_*` variables built from `POSTGRES_*` in `.env`, which is how the per-project database name reaches it.

`nimbus-migrate` for this style is called with plain flags:

```
nimbus-migrate -config ./backend/config -env .devcontainer/.env
```

**Older standalone projects** that do not match the template yet may differ: some use `server.out` as the backend name (the script reads it from `start-backend-dev.sh`), some have a git-ignored `.env` with `.env.example`, and some build from source and need `FRAMEWORK_BACKEND_REF=<branch|tag|sha>` in `.devcontainer/.env` (otherwise `make build-backend` stops with an error telling you to set it). The script copes with all of these. Once a project is updated to the template, none of those special cases apply.

## Nimbus + Meredian projects

Reference: `mosambi`.

`backend/version.json`:

```json
{ "meredian_version": "v0.2.4", "nimbus_migrate_version": "v0.12.0" }
```

What is in the project:

- `.devcontainer/.env` is **git-ignored**. It is copied from `.devcontainer/.env.example` the first time.
- `backend/schema-meredian.hcl` next to the Nimbus schemas, and the Meredian tables come from `backend/migrations`.

How the binaries get there:

- `make build-backend` downloads `meridian_Linux_x86_64.tar.gz` from the `meredian` release named by `meredian_version`. You get `meridian-engine` and `libs/linux_amd64/librust.so`.
- Meredian ships **no** migrate tool. If `backend/nimbus-migrate` is missing, the script downloads `framework-backend_nimbus-migrate_Linux_x86_64.tar.gz` from the `framework-backend` release named by `nimbus_migrate_version`.
- `start-backend-dev.sh` runs `./meridian-engine` with `QUEUE_ENABLED=false` and `AI_ENABLED=false`, so no Redis or AI services are needed.

`nimbus-migrate` for this style is a subcommand:

```
nimbus-migrate seed --config ./backend/config --env .devcontainer/.env
```

## Databases

- One postgres container, **one database per project**. Switching projects does not drop or reseed anything; each project keeps its own data.
- Your older data from before this setup stays in the `postgres` database. A project's first start creates its own empty database and sets it up (step 4 above).
- Object storage: all projects share the minio bucket `nimbus-dev-artifacts`.
- Cognito: there is one shared pool, `local_nimbus01`. Default login for every project: `admin@example.com` / `DevPass123!`.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `shared infra: nothing listening on :5432 after 60s` | Another stack holds the port, or the container failed. Check `docker ps` and the popup's Ports tab; Stop the other stack. |
| Log looks frozen at `Downloading ...tar.gz` | Normal. `gh release download` prints nothing while downloading (about 50-60 MB). |
| `ERROR: FRAMEWORK_BACKEND_REF is not set` | Older source-build project. Set `FRAMEWORK_BACKEND_REF` in `.devcontainer/.env`, or move the project to the template. |
| `gh` auth or download errors | Run `gh auth login` with an account that can read `aegion-dynamic/*`. |
| `Configuration validation failed: config directory does not exist: ./config` | `nimbus-migrate` was called in the wrong command style (see below). `run-project.sh` detects the style itself; this only appears if you call the tool by hand. |
| `git pull` fails: local changes to `.devcontainer/.env` would be overwritten | Expected for projects with a committed `.env` (skip-worktree). Run `git update-index --no-skip-worktree .devcontainer/.env && git checkout .devcontainer/.env`, pull, then start the project again; the script re-applies the DB name and hides the file. |
| `backend/config/nimbus-dev.yaml` shows as modified | `offline-auth.sh` sets `auth-enabled: true` on every backend start. Not caused by this flow. |
| First start of a project is slow | It is downloading binaries, migrating and seeding. Later starts skip all of that. |
| Want to redo a project's setup | Remove its marker: `psql ... -c "COMMENT ON DATABASE <db> IS NULL"`, or drop the database; the next start rebuilds it. |

### `nimbus-migrate` command styles

Two styles exist. The script checks `nimbus-migrate -h` for `<command>` and picks the right one.

- **Flags** (template, `v0.10.2-snapshot.*`): `nimbus-migrate -config ./backend/config -env .devcontainer/.env`. A leading `seed` word makes Go's `flag` package stop parsing, so the flags are ignored.
- **Subcommands** (Meredian, `v0.12+`): `nimbus-migrate seed --config ./backend/config --env .devcontainer/.env`.

Keep both branches in `run-project.sh` until every project is on one release line. If a Nimbus project later ships a `v0.12+` migrate tool, the script already handles it.

## Files

| File | Purpose |
|---|---|
| `run-project.sh` | The flow described above. |
| `start-project.sh` | Thin wrapper: `run-project.sh <dir> all`. |
| `docker-compose.yml`, `.env` | The shared stack and its non-secret defaults. |
| `cognito-seed/db/` | Fixtures copied into the cognito-local volume on first start. |
| `Makefile` | `reset-project-schemas`: drops per-project data schemas. Old approach, no longer used. |

Related, outside this folder:

- `../nischal.ports/` is the Ctrl+P popup plugin (Omarchy only). It lists ports, starts and stops projects, and calls `run-project.sh`.
- `../nischal.ports/wire-to-shared-infra.sh <project-dir>` converts a project that still has its own db/minio containers onto this stack.
