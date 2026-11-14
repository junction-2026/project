#!/usr/bin/env bash
# deploy-release.sh — docs/07 + docs/14 contract. Idempotently deploys the
# digest-pinned components of a release manifest to the project server via
# remote Docker Compose. Does NOT mark success (smoke-and-report.sh does).
#   * same release already healthy  -> no-op (D002 / edge 54)
#   * older release than deployed   -> refused unless ROLLBACK=true (edge 55)
#   * database is never restored automatically (edge 56)
set -euo pipefail
MANIFEST="${1:?manifest path}"
: "${DEPLOY_HOST:?}" "${DEPLOY_USER:?}" "${DEPLOY_SSH_KEY:?}"
ROLLBACK="${ROLLBACK:-false}"
RESTORE_STATE="${RESTORE_STATE:-}"   # "name=snapshot-id,…": rollback with state (docs/07)
RELEASE="$(yq -r .release_id "$MANIFEST")"
# Both go into remote command lines.
[[ "$RELEASE" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "::error::unusable release id"; exit 1; }
[[ "$RESTORE_STATE" =~ ^[A-Za-z0-9._/:+=,-]*$ ]] || { echo "::error::malformed restore_state"; exit 1; }
if [ -n "$RESTORE_STATE" ] && [ "$ROLLBACK" != "true" ]; then echo "::error::restore_state needs rollback=true"; exit 1; fi

key="$(mktemp)"; trap 'rm -f "$key"' EXIT
printf '%s\n' "$DEPLOY_SSH_KEY" > "$key"; chmod 600 "$key"
mkdir -p ~/.ssh && printf '%s\n' "${DEPLOY_KNOWN_HOSTS:-}" >> ~/.ssh/known_hosts
remote() { ssh -i "$key" -o BatchMode=yes "${DEPLOY_USER}@${DEPLOY_HOST}" "$@"; }

current="$(remote 'cat /opt/junction/state/deployment.json 2>/dev/null || echo "{}"' | jq -r '.release_id // empty')"
if [ -z "$RESTORE_STATE" ] && [ "$current" = "$RELEASE" ] && remote "test -f /opt/junction/releases/$RELEASE/healthy"; then
  echo "release $RELEASE already deployed and healthy: no-op"
  remote "test -f /opt/junction/releases/$RELEASE/state.json && printf 'junction-state: ' && cat /opt/junction/releases/$RELEASE/state.json || true"
  exit 0
fi
if [ -n "$current" ] && [ "$ROLLBACK" != "true" ]; then
  newest="$(printf '%s\n%s\n' "$current" "$RELEASE" | sort -V | tail -1)"
  if [ "$newest" != "$RELEASE" ]; then
    echo "::error::refusing to move deployment backwards ($current -> $RELEASE) without explicit rollback"
    exit 1
  fi
fi

# Render a digest-only env file from the manifest (no mutable tags).
env_file="$(mktemp)"
# The runner's yq is mikefarah yq, not jq: it only reads the path, jq builds the lines.
yq -o=json '.components' "$MANIFEST" | jq -r 'to_entries[] | "\(.key | ascii_upcase | gsub("-";"_"))_IMAGE=\(.value.image)"' > "$env_file"
if grep -vq '@sha256:[0-9a-f]\{64\}$' "$env_file"; then echo "::error::non-digest image in manifest"; exit 1; fi

remote "mkdir -p /opt/junction/releases/$RELEASE"
scp -i "$key" -o BatchMode=yes "$MANIFEST" "${DEPLOY_USER}@${DEPLOY_HOST}:/opt/junction/releases/$RELEASE/manifest.yaml"
scp -i "$key" -o BatchMode=yes "$env_file" "${DEPLOY_USER}@${DEPLOY_HOST}:/opt/junction/releases/$RELEASE/images.env"
# The server part runs from deploy-on-server.sh: it snapshots the server's
# state (hooks in /opt/junction/state.d), restores it first on a rollback with
# state, starts the images and prints the "junction-state:" line the
# orchestrator reads from this log.
remote "bash -s -- '$RELEASE' '$current' '$RESTORE_STATE'" < "$(dirname "$0")/deploy-on-server.sh"
echo "deployed $RELEASE (pending smoke)"
