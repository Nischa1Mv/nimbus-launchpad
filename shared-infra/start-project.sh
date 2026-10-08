#!/usr/bin/env bash
# Start a Nimbus / Nimbus+Meredian project (shared infra + per-project DB + binaries + backend +
# frontend). Thin wrapper: all logic lives in run-project.sh.
#
# Usage: run from the project's repo root, or pass its path:
#   /mnt/Work/work/Nimbus/shared-infra/start-project.sh [project-dir]
set -euo pipefail
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run-project.sh" "${1:-.}" all
