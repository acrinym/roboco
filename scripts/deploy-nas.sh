#!/usr/bin/env bash
# RoboCo NAS deploy - Option 0: pre-build and pre-pull while the old stack
# keeps serving, then swap only what changed.
#
# Run ON the NAS, as root:
#   sudo bash /volume1/roboco/scripts/deploy-nas.sh
#
# Why this shape: the 20+ minute deploy was mostly image BUILDS (the
# orchestrator and agent images build from source) plus sequential bring-up.
# Builds and pulls touch images, never containers, so doing them first -
# while the old stack is still running - takes all the wait time off the
# critical path. `up -d --wait` then recreates only services whose image or
# config actually changed: postgres, redis, minio, and ollama stay untouched
# and serving throughout, and the script returns only once the new
# generation passes its healthchecks. Downtime collapses to the restart of
# the changed app-tier services (typically a few minutes).
#
# Escalating to blue-green later (shared postgres, two app-tier compose
# projects, nginx upstream flip) builds on this exact script: blue is
# "run this script", green is the same with a second project name.

set -euo pipefail

STACK_DIR=${STACK_DIR:-/volume1/roboco}
COMPOSE_FILE=${COMPOSE_FILE:-$STACK_DIR/docker-compose.yaml}
# 0 = wait indefinitely (very old compose without --wait-timeout support).
WAIT_TIMEOUT=${WAIT_TIMEOUT:-900}

cd "$STACK_DIR"

echo "[deploy] building changed images (old stack keeps serving)..."
docker compose -f "$COMPOSE_FILE" build

echo "[deploy] pulling registry images (old stack keeps serving)..."
docker compose -f "$COMPOSE_FILE" pull --ignore-buildable 2>/dev/null ||
  docker compose -f "$COMPOSE_FILE" pull || true

echo "[deploy] recreating changed services and waiting for health..."
WAIT_ARGS=(--wait)
if [ "$WAIT_TIMEOUT" -gt 0 ]; then
  WAIT_ARGS+=(--wait-timeout "$WAIT_TIMEOUT")
fi
docker compose -f "$COMPOSE_FILE" up -d "${WAIT_ARGS[@]}"

echo "[deploy] applying schema migrations (idempotent)..."
docker compose -f "$COMPOSE_FILE" exec -T orchestrator alembic upgrade head ||
  echo "[deploy] WARNING: alembic failed; check orchestrator logs"

echo "[deploy] current state:"
docker compose -f "$COMPOSE_FILE" ps
echo "[deploy] done."
