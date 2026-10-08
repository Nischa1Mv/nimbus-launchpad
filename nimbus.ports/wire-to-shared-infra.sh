#!/bin/bash
# Converts a Nimbus project's OWN isolated dev stack (own db/minio/mailpit/
# cognito-local containers on non-default host ports, built for macOS/Windows/
# Linux portability) onto the shared-infra stack in
# shared-infra (this repo's shared-infra/ folder) instead.
#
# What it does:
#   1. Backs up .devcontainer/docker-compose.yml and .env(.example)
#   2. Removes the db/minio/minio-init/mailpit/cognito-init/cognito-local
#      services + their volumes from docker-compose.yml (app service kept)
#   3. Rewrites .env(.example) hostnames (db/minio/mailpit/cognito-local ->
#      localhost) so the natively-run backend/frontend reach shared-infra's
#      containers instead — shared-infra publishes the SAME standard ports
#      (5432/9000/1025/9229) these apps already expect internally, only the
#      per-project isolated compose used non-default HOST ports to avoid
#      collisions, which no longer applies once its own db/minio are gone.
#
# What it does NOT do (check manually after running):
#   - Anything not matching the db/minio/mailpit/cognito-local hostname
#     pattern in .env (custom var names, secrets, other services)
#   - Committing anything — this only edits your local working tree
#
# Only makes sense for a project whose docker-compose.yml does NOT already
# use `network_mode: host` (i.e. it currently runs its own isolated stack).
#
# Usage: wire-to-shared-infra.sh <project-dir>

set -euo pipefail

PROJECT="$(cd "${1:?Usage: wire-to-shared-infra.sh <project-dir>}" && pwd)"
COMPOSE="$PROJECT/.devcontainer/docker-compose.yml"
STAMP=$(date +%Y%m%d%H%M%S)

[ -f "$COMPOSE" ] || { echo "error: $COMPOSE not found" >&2; exit 1; }

if grep -v '^\s*#' "$COMPOSE" | grep -q "network_mode: *host"; then
  echo "error: $(basename "$PROJECT") already looks wired to a shared/host-network stack — nothing to convert" >&2
  exit 1
fi

echo "==> Backing up docker-compose.yml and env files"
cp "$COMPOSE" "$COMPOSE.bak.$STAMP"
for envfile in "$PROJECT/.devcontainer/.env" "$PROJECT/.devcontainer/.env.example"; do
  [ -f "$envfile" ] && cp "$envfile" "$envfile.bak.$STAMP"
done

echo "==> Removing db/minio/mailpit/cognito-local services from docker-compose.yml"
python3 - "$COMPOSE" <<'PYEOF'
import sys, yaml

path = sys.argv[1]
with open(path) as f:
    doc = yaml.safe_load(f)

drop = {"db", "minio", "minio-init", "mailpit", "cognito-init", "cognito-local"}
services = doc.get("services", {})
for name in list(services):
    if name in drop:
        del services[name]

for svc in services.values():
    deps = svc.get("depends_on")
    if isinstance(deps, dict):
        svc["depends_on"] = {k: v for k, v in deps.items() if k not in drop}
        if not svc["depends_on"]:
            del svc["depends_on"]
    elif isinstance(deps, list):
        svc["depends_on"] = [d for d in deps if d not in drop]
        if not svc["depends_on"]:
            del svc["depends_on"]

if "volumes" in doc:
    kept = {k: v for k, v in doc["volumes"].items() if k not in {"postgres-data", "minio_data", "mailpit_data", "cognito_data"}}
    if kept:
        doc["volumes"] = kept
    else:
        del doc["volumes"]

with open(path, "w") as f:
    yaml.safe_dump(doc, f, sort_keys=False, default_flow_style=False)
PYEOF

echo "==> Pointing .env hostnames at shared-infra (localhost)"
for envfile in "$PROJECT/.devcontainer/.env" "$PROJECT/.devcontainer/.env.example"; do
  [ -f "$envfile" ] || continue
  sed -i -E \
    -e 's/^(POSTGRES_HOSTNAME)=.*/\1=localhost/' \
    -e 's/^(SMTP_HOST)=.*/\1=localhost/' \
    -e 's#(://)(minio|cognito-local|db|mailpit)([:/])#\1localhost\3#g' \
    "$envfile"
done

echo
echo "Done. Review the diff before trusting it:"
echo "  diff -u '$COMPOSE.bak.$STAMP' '$COMPOSE'"
echo
echo "Manual check: grep for any remaining db/minio/mailpit/cognito-local"
echo "references this script's patterns didn't catch:"
echo "  grep -rniE '\\b(db|minio|mailpit|cognito-local)\\b' '$PROJECT/.devcontainer/.env' 2>/dev/null"
echo
echo "Nothing was committed — this only touched your local working tree."
