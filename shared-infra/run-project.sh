#!/usr/bin/env bash
# Run a Nimbus or Nimbus+Meredian project against the ONE shared dev-infra stack.
#
#   run-project.sh <project-dir> [backend|frontend|all]      (default: all)
#
# Order, each step only when needed:
#   1. shared infra up (postgres/minio/mailpit/cognito-local), ports answering
#   2. per-project database (POSTGRES_DB in the project's git-ignored .devcontainer/.env);
#      first time in a DB: atlas migrate + RBAC seed. Switching projects never wipes anything.
#   3. backend binaries present + match backend/version.json (else `make build-backend`)
#   4. free :8080/:3000, then `make start-backend` / `make start-frontend-dev`
#
# Stack is detected from backend/version.json: meredian_version => meredian
# (meridian-engine), otherwise plain nimbus (server.out / nimbus-backend).
#
# backend  => runs `make start-backend` in the FOREGROUND (exec) so a caller can track/kill the pid.
# frontend => same for `make start-frontend-dev`.
# all      => starts both in the background (logs in .devcontainer/logs) and waits for :8080.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE=(docker compose -p nimbus-shared -f "$SCRIPT_DIR/docker-compose.yml")
PROJECT="$(cd "${1:?Usage: run-project.sh <project-dir> [backend|frontend|all]}" && pwd)"
MODE="${2:-all}"
NAME="$(basename "$PROJECT")"
DB_NAME="$(tr -c 'a-zA-Z0-9\n' '_' <<<"$NAME" | tr 'A-Z' 'a-z')"
LOGS="$PROJECT/.devcontainer/logs"
ENV_FILE="$PROJECT/.devcontainer/.env"
VERSION_FILE="$PROJECT/backend/version.json"
step() { printf '\n\033[1;32m==>\033[0m %s\n' "$1"; }
die() { echo "error: $*" >&2; exit 1; }

case "$MODE" in backend|frontend|all) ;; *) die "mode must be backend|frontend|all" ;; esac
[ -f "$PROJECT/Makefile" ] || die "$PROJECT/Makefile not found — not a Nimbus project"
mkdir -p "$LOGS"

port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
free_port() {
  local pids
  pids=$(lsof -ti tcp:"$1" -sTCP:LISTEN 2>/dev/null || true)
  [ -z "$pids" ] && return 0
  echo "  freeing :$1 (pid $pids)"
  kill $pids 2>/dev/null || true
  sleep 1
  kill -9 $pids 2>/dev/null || true
}
set_env() { # KEY VALUE — set/append in the project's local .env
  if grep -qE "^$1=" "$ENV_FILE"; then sed -i -E "s|^$1=.*|$1=$2|" "$ENV_FILE"; else echo "$1=$2" >>"$ENV_FILE"; fi
}
psql_shared() { "${COMPOSE[@]}" exec -T db psql -U postgres -v ON_ERROR_STOP=1 -qtA "$@"; }

# ---- 1. shared infra -------------------------------------------------------------------------
step "Shared infra"
"${COMPOSE[@]}" up -d
for port in 5432 9000 9229; do
  for _ in $(seq 1 60); do port_open "$port" && break; sleep 1; done
  port_open "$port" || die "shared infra: nothing listening on :$port after 60s"
done
for _ in $(seq 1 30); do "${COMPOSE[@]}" exec -T db pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done

# ---- 2. per-project env + database -----------------------------------------------------------
[ -f "$ENV_FILE" ] || { [ -f "$ENV_FILE.example" ] || die "no .devcontainer/.env or .env.example"; cp "$ENV_FILE.example" "$ENV_FILE"; }
cur_db="$(sed -n 's/^POSTGRES_DB=//p' "$ENV_FILE" | head -1)"
if [ -z "$cur_db" ] || [ "$cur_db" = "postgres" ]; then
  set_env POSTGRES_DB "$DB_NAME"
  cur_db="$DB_NAME"
fi
# shared infra is host-networked: a leftover `db` hostname (own-stack compose) would not resolve
[ "$(sed -n 's/^POSTGRES_HOSTNAME=//p' "$ENV_FILE" | head -1)" = "db" ] && set_env POSTGRES_HOSTNAME localhost

# Newer templates commit .devcontainer/.env. Our local edits (POSTGRES_DB/HOSTNAME) must not show up
# in git status or get committed: mark it skip-worktree. Before a `git pull` that changes it, run:
#   git update-index --no-skip-worktree .devcontainer/.env && git stash   (or git checkout the file)
if git -C "$PROJECT" ls-files --error-unmatch .devcontainer/.env >/dev/null 2>&1 \
   && ! git -C "$PROJECT" ls-files -v .devcontainer/.env | grep -q '^S'; then
  git -C "$PROJECT" update-index --skip-worktree .devcontainer/.env
  echo "  .devcontainer/.env is tracked: marked skip-worktree (local DB name hidden from git)"
fi

step "Database '$cur_db'"
if [ -z "$(psql_shared -d postgres -c "SELECT 1 FROM pg_database WHERE datname='$cur_db'")" ]; then
  echo "  creating database $cur_db"
  psql_shared -d postgres -c "CREATE DATABASE \"$cur_db\""
fi
needs_init=false
# Marker = database comment, set only after migrate+seed both succeeded (a half-failed init retries).
[ "$(psql_shared -d postgres -c "SELECT shobj_description(oid,'pg_database') FROM pg_database WHERE datname='$cur_db'")" = "nimbus-seeded" ] || needs_init=true

# ---- 3. backend binaries ---------------------------------------------------------------------
case "$(uname -m)" in x86_64|amd64) LIBS=linux_amd64 ;; aarch64|arm64) LIBS=linux_arm64 ;; *) die "unsupported arch $(uname -m)" ;; esac
[ -f "$VERSION_FILE" ] || die "backend/version.json not found"
if jq -e '.meredian_version' "$VERSION_FILE" >/dev/null 2>&1; then
  STACK=meredian BIN=meridian-engine
else
  STACK=nimbus
  BIN="$(sed -nE 's/^[[:space:]]*exec \.\/([A-Za-z0-9._-]+).*/\1/p' "$PROJECT/.devcontainer/start-backend-dev.sh" | head -1)"
  [ -n "$BIN" ] || BIN=server.out
fi
# Wanted version: the source-build ref when the project's build script uses one, else version.json.
want="$(jq -cS . "$VERSION_FILE")"
if grep -q FRAMEWORK_BACKEND_REF "$PROJECT/.devcontainer/build-backend.sh" 2>/dev/null; then
  want="$want|$(sed -n 's/^FRAMEWORK_BACKEND_REF=//p' "$ENV_FILE" | head -1)"
fi
STAMP="$LOGS/.backend-version"
have_files=true
for f in "backend/$BIN" backend/nimbus-migrate "backend/libs/$LIBS/librust.so"; do
  [ -f "$PROJECT/$f" ] || { have_files=false; echo "  missing $f"; }
done
if $have_files && [ ! -f "$STAMP" ]; then
  echo "$want" >"$STAMP"   # pre-existing install: trust it, track from now on
elif ! $have_files || [ "$(cat "$STAMP" 2>/dev/null)" != "$want" ]; then
  step "Installing backend ($STACK): make build-backend"
  (cd "$PROJECT" && make build-backend)
  if [ ! -f "$PROJECT/backend/nimbus-migrate" ]; then
    # meredian ships no migrate CLI; it still comes from framework-backend
    nm_ver="$(jq -r '.nimbus_migrate_version // empty' "$VERSION_FILE")"
    [ -n "$nm_ver" ] || die "backend/nimbus-migrate missing and no nimbus_migrate_version in version.json"
    step "Fetching nimbus-migrate $nm_ver from framework-backend"
    tmp="$(mktemp -d)"
    gh release download "$nm_ver" --repo aegion-dynamic/framework-backend \
      --pattern framework-backend_nimbus-migrate_Linux_x86_64.tar.gz --dir "$tmp"
    tar -xzf "$tmp"/*.tar.gz -C "$tmp"
    install -m 755 "$(find "$tmp" -name nimbus-migrate -type f | head -1)" "$PROJECT/backend/nimbus-migrate"
    rm -rf "$tmp"
  fi
  for f in "backend/$BIN" backend/nimbus-migrate "backend/libs/$LIBS/librust.so"; do
    [ -f "$PROJECT/$f" ] || die "after build-backend, $f is still missing"
  done
  echo "$want" >"$STAMP"
fi

# ---- 2b. first-time schema + RBAC seed (needs the binaries from step 3) -----------------------
if $needs_init; then
  step "Fresh database: applying migrations + RBAC seed"
  (
    cd "$PROJECT"
    set -a; . "$ENV_FILE"; set +a
    export DATABASE_URL="postgres://${POSTGRES_USER:-postgres}:${POSTGRES_PASSWORD:-postgres}@localhost:5432/${POSTGRES_DB}?sslmode=disable"
    if ! out="$(atlas migrate apply --env remote 2>&1)"; then
      if grep -q 'connected database is not clean' <<<"$out"; then
        first="$(ls backend/migrations/*.sql | head -1)"
        atlas migrate apply --env remote --baseline "$(basename "$first" | grep -oE '^[0-9]+')"
        atlas migrate apply --env remote
      else
        printf '%s\n' "$out" >&2; exit 1
      fi
    else
      printf '%s\n' "$out"
    fi
    # v0.12+ nimbus-migrate has subcommands (`seed --config`); older ones take plain Go flags (`-config`).
    if ./backend/nimbus-migrate -h 2>&1 | grep -q '<command>'; then
      migrate_args=(seed --config ./backend/config --env .devcontainer/.env)
    else
      migrate_args=(-config ./backend/config -env .devcontainer/.env)
    fi
    AWS_ACCESS_KEY_ID="${MINIO_ROOT_USER:-minio}" AWS_SECRET_ACCESS_KEY="${MINIO_ROOT_PASSWORD:-minio123}" \
      POSTGRES_HOSTNAME=localhost \
      ./backend/nimbus-migrate "${migrate_args[@]}"
  )
  psql_shared -d postgres -c "COMMENT ON DATABASE \"$cur_db\" IS 'nimbus-seeded'" >/dev/null
fi

# ---- 3b. frontend env + deps (what `make dev` step 5 does; only fills what is missing) --------
if [ "$MODE" != backend ] && [ -d "$PROJECT/frontend" ]; then
  if [ ! -f "$PROJECT/frontend/.env.local" ]; then
    step "Writing frontend/.env.local"
    (
      set -a; . "$ENV_FILE"; set +a
      {
        echo "NEXTAUTH_URL=http://localhost:3000"
        echo "NEXTAUTH_SECRET=$(openssl rand -hex 32)"
        echo "NEXT_PUBLIC_BACKEND_URL=http://localhost:8080"
        echo "NEXT_PUBLIC_GRAPHQL_URL=http://localhost:8080/graphql"
        echo "NEXT_TELEMETRY_DISABLED=1"
        if [ -n "${COGNITO_CLIENT_ID:-}" ] && [ -n "${COGNITO_ISSUER_URL:-}" ]; then
          echo "COGNITO_CLIENT_ID=${COGNITO_CLIENT_ID}"
          echo "COGNITO_ISSUER=${COGNITO_ISSUER_URL}"
          echo "COGNITO_TOKEN_ENDPOINT=${COGNITO_ISSUER_URL}/oauth2/token"
        fi
        [ -z "${COGNITO_USER_POOL_ID:-}" ] || echo "COGNITO_USER_POOL_ID=${COGNITO_USER_POOL_ID}"
        [ -z "${AWS_ENDPOINT_URL_COGNITO_IDENTITY_PROVIDER:-}" ] || echo "AWS_ENDPOINT_URL_COGNITO_IDENTITY_PROVIDER=${AWS_ENDPOINT_URL_COGNITO_IDENTITY_PROVIDER}"
      } >"$PROJECT/frontend/.env.local"
    )
  fi
  if [ ! -d "$PROJECT/frontend/node_modules" ]; then
    step "Installing frontend deps (npm ci)"
    (cd "$PROJECT/frontend" && npm ci)
  fi
fi

# ---- 4. start ---------------------------------------------------------------------------------
cd "$PROJECT"
case "$MODE" in
  backend)
    free_port 8080
    exec make start-backend
    ;;
  frontend)
    free_port 3000
    exec make start-frontend-dev
    ;;
  all)
    free_port 8080; free_port 3000
    step "Starting backend (make start-backend, :8080)"
    nohup make start-backend >"$LOGS/backend.log" 2>&1 &
    step "Starting frontend (make start-frontend-dev, :3000)"
    nohup make start-frontend-dev >"$LOGS/frontend.log" 2>&1 &
    for _ in $(seq 1 60); do
      code="$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/ 2>/dev/null || true)"
      [ -n "$code" ] && [ "$code" != "000" ] && break
      sleep 1
    done
    [ -n "${code:-}" ] && [ "$code" != "000" ] || echo "  warning: backend not answering after 60s — see $LOGS/backend.log" >&2
    # Cognito sample personas (opt-in in `make dev`): seed once per fresh DB, needs the backend up.
    if $needs_init && grep -q '^seed-users:' Makefile && [ "${code:-000}" != "000" ]; then
      step "Seeding sample users (make seed-users)"
      make seed-users || echo "  warning: seed-users failed — rerun 'make seed-users' once the backend is healthy" >&2
    fi
    printf '\n  %s up (%s). Logs: %s/{backend,frontend}.log\n  App: http://localhost:3000\n' "$NAME" "$STACK" "$LOGS"
    ;;
esac
