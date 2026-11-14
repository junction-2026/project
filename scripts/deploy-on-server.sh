#!/usr/bin/env bash
# deploy-on-server.sh — the part of deploy-release.sh that runs on the project
# server (sent over SSH; docs/07 "Stateful components"). Starts the release's
# digest-pinned images and records the server's state around it.
#   $1 release being deployed   $2 release currently deployed (may be empty)
#   $3 states to restore first, "name=snapshot-id,…" (rollback with state only)
#
# The server owner declares state with hooks, /opt/junction/state.d/<name>/:
#   version                  prints an opaque state version (e.g. a migration id)
#   snapshot <outgoing-rel>  takes a snapshot, prints its id
#   restore <snapshot-id>    restores that snapshot
#   backward-compatible      (optional file) state changes never block an image rollback
# No hook directory: exactly the old behaviour.
set -euo pipefail
RELEASE="${1:?release}"; OUTGOING="${2:-}"; RESTORE="${3:-}"
ROOT="${JUNCTION_ROOT:-/opt/junction}"
rel="$ROOT/releases/$RELEASE"; env_file="$rel/images.env"
safe='^[A-Za-z0-9._/:+-]*$'   # versions and snapshot ids travel through logs, workflow inputs and SSH

names=()
for d in "$ROOT"/state.d/*/; do
  n="$(basename "$d")"
  [ -x "$d/version" ] && [ -x "$d/snapshot" ] || continue
  [[ "$n" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || { echo "::error::state hook directory '$n': use lowercase letters, digits, - and _"; exit 1; }
  names+=("$n")
done

declare -A before snap
hook() { # hook <state> <command> [arg]: last output line, checked
  local out
  out="$("$ROOT/state.d/$1/$2" "${@:3}" | tail -n 1)"
  [[ "$out" =~ $safe ]] || { echo "::error::state $1: '$2' printed an unusable value" >&2; return 1; }
  printf '%s' "$out"
}

# Printed on every exit, also a failed deploy: the orchestrator reads this line
# from the job log to know what the deploy did to the server's state.
report() {
  local json="" n after bc
  for n in "${names[@]}"; do
    after="$(hook "$n" version 2>/dev/null || true)"
    bc=false; [ -e "$ROOT/state.d/$n/backward-compatible" ] && bc=true
    json+="${json:+,}\"$n\":{\"before\":\"${before[$n]:-}\",\"version\":\"$after\",\"snapshot\":\"${snap[$n]:-}\",\"backward_compatible\":$bc}"
  done
  printf '{%s}\n' "$json" > "$rel/state.json" 2>/dev/null || true
  echo "junction-state: {$json}"
}
trap report EXIT

# A snapshot of every state before anything changes; a failing hook stops the deploy.
for n in "${names[@]}"; do
  before[$n]="$(hook "$n" version)"
  snap[$n]="$(hook "$n" snapshot "$OUTGOING")"
done

cd "$ROOT/compose"
cp "$ROOT/state/deployment.json" "$ROOT/state/previous.json" 2>/dev/null || true
docker compose --env-file "$env_file" pull
if [ -n "$RESTORE" ]; then
  [[ "$RESTORE" =~ ^[a-z0-9][a-z0-9_-]*=[A-Za-z0-9._/:+-]+(,[a-z0-9][a-z0-9_-]*=[A-Za-z0-9._/:+-]+)*$ ]] || { echo "::error::malformed restore list"; exit 1; }
  IFS=, read -ra pairs <<< "$RESTORE"
  for p in "${pairs[@]}"; do
    [ -x "$ROOT/state.d/${p%%=*}/restore" ] || { echo "::error::state ${p%%=*} has no restore hook"; exit 1; }
  done
  # Create the old release's containers stopped, then restore: a hook that
  # restarts its service starts the old image on the restored state, never
  # the newer image (which could migrate the restored state forward again).
  docker compose --env-file "$env_file" stop
  docker compose --env-file "$env_file" up --no-start --remove-orphans
  for p in "${pairs[@]}"; do
    echo "restoring state ${p%%=*} from snapshot ${p#*=}"
    "$ROOT/state.d/${p%%=*}/restore" "${p#*=}"
  done
fi
# Migrations must be expand-only / idempotent; a migration container may run here (policy).
docker compose --env-file "$env_file" up -d --remove-orphans --wait
printf '{"release_id":"%s","status":"pending_smoke"}' "$RELEASE" > "$ROOT/state/deployment.json"
