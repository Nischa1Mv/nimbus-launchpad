#!/bin/bash
# Lists TCP LISTEN ports with process name, pid and project dir (cwd of pid).
# --count prints just the number of listening ports (for the bar widget).
# --json  prints the same data as a JSON array (for the ports panel).
# --nimbus-json  prints Nimbus projects (under NIMBUS_DIR) with per-service
#                (backend :8080 / frontend :3000) running state + pid, and
#                whether that project's Makefile has start-backend /
#                start-frontend-dev targets.
# --stop <container|shared-infra>  stops a docker container (or the whole
#                nimbus-shared stack) that owns a port; volumes/data are kept.
# --infra-status prints whether the shared-infra docker stack is up.
# --start-backend <project-dir>   delegates to shared-infra/run-project.sh
#                (infra up -> per-project DB -> binaries via `make build-backend`
#                if missing/stale -> frees :8080 -> `make start-backend`).
# --start-frontend <project-dir>  same script: frees :3000, `make start-frontend-dev`.
# --personal-json  prints personal projects (under PERSONAL_DIR, each with a
#                .devports file: "<backend|frontend> <port> <make target>")
#                in the same shape as --nimbus-json.
# --start-personal <project-dir> <backend|frontend>  runs `make up` (the
#                project's own docker services), then that service's target.
# --background <one of the --start-* commands above>  runs it detached, output
#                to LOG_DIR/<project>-<backend|frontend>.log (the popup's Log button tails it).

set -euo pipefail

# Where the Nimbus projects live is user config (written by install.sh), not hardcoded.
REPO_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
CONFIG="${NIMBUS_DEV_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/nimbus-launchpad/config}"
[ -f "$CONFIG" ] && . "$CONFIG"
NIMBUS_DIR="${NIMBUS_DIR:-}"
PERSONAL_DIR="${PERSONAL_DIR:-}"
if [ -z "$NIMBUS_DIR" ] || [ ! -d "$NIMBUS_DIR" ]; then
  echo "NIMBUS_DIR not set or missing (config: $CONFIG). Run $REPO_DIR/install.sh" >&2
  exit 1
fi
SHARED_INFRA="$REPO_DIR/shared-infra"
LOG_DIR="$HOME/.local/state/nimbus-launchpad/logs"

# <service> <field> from a project's .devports (field 2 = port, 3 = make target)
devport() { awk -v s="$2" -v f="$3" '$1 == s { print $f; exit }' "$1/.devports"; }

# Friendly names for well-known ports. Shared infra runs with network_mode: host,
# so `docker ps` shows no ports for it -> static map. Containers that DO publish
# ports (other projects' stacks) override these with their container name.
declare -A NAME=(
  [8080]=backend [3000]=frontend [6006]=storybook
  [5432]=postgres [9000]=minio-s3 [9001]=minio-console
  [1025]=mailpit-smtp [8025]=mailpit-ui [9229]=cognito-local [6379]=redis
)
declare -A DOCKER=()
SHARED_UP=false
[ -n "$(docker ps -q --filter label=com.docker.compose.project=nimbus-shared 2>/dev/null)" ] && SHARED_UP=true
INFRA_PORTS=" 5432 9000 9001 1025 8025 9229 "
while IFS=$'\t' read -r cname cports; do
  for spec in $(grep -oP '(?:0\.0\.0\.0|\[::\]|127\.0\.0\.1):\K[0-9]+(-[0-9]+)?(?=->)' <<<"$cports" | sort -u); do
    for ((p = ${spec%-*}; p <= ${spec#*-}; p++)); do NAME[$p]="$cname"; DOCKER[$p]="$cname"; done
  done
done < <(docker ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null)

rows=""
while IFS= read -r line; do
  local_addr=$(awk '{print $4}' <<<"$line")
  port=${local_addr##*:}
  [[ "$port" =~ ^[0-9]+$ ]] || continue
  pid=$(grep -oP 'pid=\K[0-9]+' <<<"$line" || true)
  proc=$(sed -n 's/.*"\([^"]*\)".*/\1/p' <<<"$line")
  proj="-"
  if [ -n "$pid" ] && [ -r "/proc/$pid/cwd" ]; then
    proj=$(basename "$(readlink -f "/proc/$pid/cwd" 2>/dev/null)")
  fi
  [ -n "${NAME[$port]:-}" ] && proc="${proc:+$proc }(${NAME[$port]})"
  stop=""
  if [ -n "${DOCKER[$port]:-}" ]; then stop="${DOCKER[$port]}"
  elif $SHARED_UP && [[ "$INFRA_PORTS" == *" $port "* ]]; then stop="shared-infra"; fi
  rows+="${port}\t${proc:--}\t${pid:--}\t${proj}\t${stop}\n"
done < <(ss -ltnp 2>/dev/null | awk 'NR>1')

# Always show the fixed Nimbus app + shared-infra ports even when nothing is
# listening, so it's clear which ports a project start uses / what is down.
for nport in 8080 3000 6006; do
  echo -e "$rows" | grep -q "^${nport}"$'\t' || rows+="${nport}\t${NAME[$nport]} (free)\t-\t-\n"
done
for nport in 5432 9000 1025 8025 9229; do
  echo -e "$rows" | grep -q "^${nport}"$'\t' || rows+="${nport}\t${NAME[$nport]} (down)\t-\t-\n"
done

rows=$(echo -e "$rows" | sort -n -u -k1,1)

case "${1:-}" in
  --count)
    echo "$rows" | grep -vcE '\((free|down)\)' || echo 0
    ;;
  --json)
    echo "$rows" | grep . | jq -R -s -c '
      split("\n") | map(select(length > 0) | split("\t")) |
      map({port: (.[0]|tonumber), process: .[1], pid: .[2], project: .[3], stop: (.[4] // "")})
    '
    ;;
  --nimbus-json)
    backend_pid=$(ss -ltnp 2>/dev/null | awk '$4 ~ /:8080$/' | grep -oP 'pid=\K[0-9]+' | head -1 || true)
    frontend_pid=$(ss -ltnp 2>/dev/null | awk '$4 ~ /:3000$/' | grep -oP 'pid=\K[0-9]+' | head -1 || true)
    backend_cwd=""; frontend_cwd=""
    [ -n "$backend_pid" ] && [ -r "/proc/$backend_pid/cwd" ] && backend_cwd=$(readlink -f "/proc/$backend_pid/cwd" 2>/dev/null)
    [ -n "$frontend_pid" ] && [ -r "/proc/$frontend_pid/cwd" ] && frontend_cwd=$(readlink -f "/proc/$frontend_pid/cwd" 2>/dev/null)

    printf '['
    first=1
    for dir in "$NIMBUS_DIR"/*/; do
      [ -f "$dir/Makefile" ] || continue
      name=$(basename "$dir")
      path=$(readlink -f "$dir")

      has_backend=false
      grep -qE '^start-backend:' "$dir/Makefile" && has_backend=true
      has_frontend=false
      grep -qE '^start-frontend-dev:' "$dir/Makefile" && has_frontend=true

      backend_running=false
      backend_running_pid="-"
      [[ -n "$backend_cwd" && ( "$backend_cwd" == "$path"/* || "$backend_cwd" == "$path" ) ]] && { backend_running=true; backend_running_pid="$backend_pid"; }

      frontend_running=false
      frontend_running_pid="-"
      [[ -n "$frontend_cwd" && ( "$frontend_cwd" == "$path"/* || "$frontend_cwd" == "$path" ) ]] && { frontend_running=true; frontend_running_pid="$frontend_pid"; }

      [ "$first" = 1 ] && first=0 || printf ','
      jq -nc \
        --arg name "$name" --arg path "$path" \
        --argjson hasBackend "$has_backend" --argjson hasFrontend "$has_frontend" \
        --argjson backendRunning "$backend_running" --arg backendPid "$backend_running_pid" \
        --argjson frontendRunning "$frontend_running" --arg frontendPid "$frontend_running_pid" \
        '{name:$name, path:$path, kind:"nimbus", hasBackend:$hasBackend, hasFrontend:$hasFrontend,
          backendRunning:$backendRunning, backendPid:$backendPid,
          frontendRunning:$frontendRunning, frontendPid:$frontendPid}'
    done
    printf ']\n'
    ;;
  --personal-json)
    printf '['
    first=1
    for dir in ${PERSONAL_DIR:+"$PERSONAL_DIR"/*/}; do
      [ -f "$dir/.devports" ] || continue
      path=$(readlink -f "$dir")
      row=$(jq -nc --arg name "$(basename "$dir")" --arg path "$path" '{name:$name, path:$path, kind:"personal"}')
      for svc in backend frontend; do
        port=$(devport "$path" "$svc" 2)
        has=false; running=false; spid="-"
        if [ -n "$port" ]; then
          has=true
          pid=$(ss -ltnp 2>/dev/null | awk -v p=":$port$" '$4 ~ p' | grep -oP 'pid=\K[0-9]+' | head -1 || true)
          cwd=""; [ -n "$pid" ] && [ -r "/proc/$pid/cwd" ] && cwd=$(readlink -f "/proc/$pid/cwd" 2>/dev/null)
          [[ -n "$cwd" && ( "$cwd" == "$path"/* || "$cwd" == "$path" ) ]] && { running=true; spid="$pid"; }
        fi
        Svc=${svc^}
        row=$(jq -c --argjson has "$has" --argjson running "$running" --arg pid "$spid" \
          ". + {has$Svc: \$has, ${svc}Running: \$running, ${svc}Pid: \$pid}" <<<"$row")
      done
      [ "$first" = 1 ] && first=0 || printf ','
      printf '%s' "$row"
    done
    printf ']\n'
    ;;
  --background)
    shift
    case "$1" in
      --start-personal) svc="${3:?}" ;;
      --start-backend) svc=backend ;;
      --start-frontend) svc=frontend ;;
      *) echo "--background takes a --start-* command"; exit 1 ;;
    esac
    mkdir -p "$LOG_DIR"
    base="$LOG_DIR/$(basename "$(readlink -f "${2:?}")")-$svc"
    log="$base.log"
    echo "==> $(date '+%F %T') $*" > "$log"
    # setsid (no -f) makes this backgrounded process its own session+group
    # leader, so `kill -TERM -<pid>` from the Cancel button reaches every
    # descendant (make, go run, the actual server) in one shot.
    setsid "$0" "$@" >>"$log" 2>&1 </dev/null &
    echo $! > "$base.pid"
    ;;
  --start-personal)
    project="$(cd "${2:?Usage: --start-personal <project-dir> <backend|frontend>}" && pwd)"
    svc="${3:?Usage: --start-personal <project-dir> <backend|frontend>}"
    target=$(devport "$project" "$svc" 3)
    [ -n "$target" ] || { echo "No $svc line in $project/.devports"; exit 1; }
    cd "$project"
    echo "==> make up (docker services for $(basename "$project"))"
    make up
    echo "==> make $target"
    exec make "$target"
    ;;
  --stop)
    target="${2:?Usage: --stop <container-name|shared-infra>}"
    if [ "$target" = shared-infra ]; then
      docker compose -p nimbus-shared -f "$SHARED_INFRA/docker-compose.yml" stop
    else
      docker stop "$target"
    fi
    ;;
  --infra-status)
    running=false
    [ -n "$(docker compose -p nimbus-shared -f "$SHARED_INFRA/docker-compose.yml" ps -q db 2>/dev/null)" ] && running=true
    jq -nc --argjson running "$running" '{running:$running}'
    ;;
  --start-backend)
    exec "$SHARED_INFRA/run-project.sh" "${2:?Usage: --start-backend <project-dir>}" backend
    ;;
  --start-frontend)
    exec "$SHARED_INFRA/run-project.sh" "${2:?Usage: --start-frontend <project-dir>}" frontend
    ;;
  *)
    printf 'PORT\tPROCESS\tPID\tPROJECT\n%s\n' "$rows" | column -t -s $'\t'
    ;;
esac
