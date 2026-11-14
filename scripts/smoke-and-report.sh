#!/usr/bin/env bash
# smoke-and-report.sh — runs the configured smoke suite against the target.
# Pass: persist the deployed marker + update `current`. Fail: restore the
# previous healthy release's app images (never the database) and fail the job.
set -euo pipefail
MANIFEST="${1:?manifest path}"
: "${DEPLOY_HOST:?}" "${DEPLOY_USER:?}" "${DEPLOY_SSH_KEY:?}" "${SMOKE_URL:?}"
RELEASE="$(yq -r .release_id "$MANIFEST")"
key="$(mktemp)"; trap 'rm -f "$key"' EXIT
printf '%s\n' "$DEPLOY_SSH_KEY" > "$key"; chmod 600 "$key"
remote() { ssh -i "$key" -o BatchMode=yes "${DEPLOY_USER}@${DEPLOY_HOST}" "$@"; }

ok=true
for i in $(seq 1 30); do
  if curl -fsS "$SMOKE_URL/health" >/dev/null; then break; fi
  sleep 2
  [ "$i" = 30 ] && ok=false
done
if $ok && [ -x ./integration/smoke.sh ]; then
  SMOKE_URL="$SMOKE_URL" ./integration/smoke.sh || ok=false
fi

if $ok; then
  remote "set -e; touch /opt/junction/releases/$RELEASE/healthy
    ln -sfn /opt/junction/releases/$RELEASE /opt/junction/current
    printf '{\"release_id\":\"%s\",\"status\":\"healthy\"}' '$RELEASE' > /opt/junction/state/deployment.json"
  echo "release $RELEASE healthy"
  exit 0
fi

echo "::error::smoke failed for $RELEASE; restoring previous healthy application images (DB untouched)"
remote 'set -e; prev=$(readlink -f /opt/junction/current || true)
  if [ -n "$prev" ] && [ -f "$prev/images.env" ]; then
    cd /opt/junction/compose && docker compose --env-file "$prev/images.env" up -d --remove-orphans --wait
    cp /opt/junction/state/previous.json /opt/junction/state/deployment.json 2>/dev/null || true
  fi' || echo "::warning::automatic app rollback failed; operator action required"
exit 1
