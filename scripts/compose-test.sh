#!/usr/bin/env bash
# compose-test.sh — docs/14 contract. Runs in workspace/project (the candidate
# harness SHA). Builds the images a suite uses from the exact candidate checkouts, starts the
# Compose stack under a unique project name, runs the required suites from
# integration/test-suites.yaml, writes JUnit + integration-result.json with the
# candidate hash, and always tears down.
set -euo pipefail

: "${CANDIDATE_MANIFEST:?}" "${ARTIFACTS:?}" "${RUN_ID:?}" "${RUN_ATTEMPT:=1}"
WORKSPACE="$(cd .. && pwd)"
HASH="$(jq -r .candidate_set_hash "$CANDIDATE_MANIFEST")"
PROJECT="ci-${RUN_ID}-${RUN_ATTEMPT}"
# Package caches persisted across runs by integration.yml; suites mount them into
# containers (-v "$JUNCTION_NPM_CACHE":/tmp/.npm). Created here so Docker does not
# create them root-owned.
export JUNCTION_NPM_CACHE="${JUNCTION_NPM_CACHE:-$HOME/.npm}"
export JUNCTION_GO_MODCACHE="${JUNCTION_GO_MODCACHE:-$HOME/go/pkg/mod}"
export JUNCTION_GO_CACHE="${JUNCTION_GO_CACHE:-$HOME/.cache/go-build}"
mkdir -p "$ARTIFACTS/junit" "$JUNCTION_NPM_CACHE" "$JUNCTION_GO_MODCACHE" "$JUNCTION_GO_CACHE"

# Seconds per phase, in artifacts/timings.tsv and the run summary.
TIMINGS="$ARTIFACTS/timings.tsv"
: > "$TIMINGS"
since=$SECONDS
mark() { printf '%s\t%s\n' "$1" "$((SECONDS - since))" >> "$TIMINGS"; since=$SECONDS; }

cleanup() {
  docker compose -p "$PROJECT" -f integration/compose.yaml down -v --remove-orphans >/dev/null 2>&1 || true
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
  { echo "| Phase | Seconds |"; echo "|---|---|"; awk -F'\t' '{print "| " $1 " | " $2 " |"}' "$TIMINGS"; } >> "$GITHUB_STEP_SUMMARY"
}
trap cleanup EXIT

suites="$(jq -r '.required_suite_ids[]?' "$CANDIDATE_MANIFEST")"
suite_cmds=""
for suite in $suites; do suite_cmds+="$(yq -r ".suites.\"$suite\".command" integration/test-suites.yaml)"$'\n'; done
# An image is used when the harness (integration/, suite definitions and examples aside) or a
# selected suite's command names its variable.
uses() { grep -rqF --exclude=test-suites.yaml --exclude="*.example.yaml" "$1" integration/ || grep -qF "$1" <<< "$suite_cmds"; }

# Build each deployable candidate that something uses from its exact checkout;
# tag with the candidate SHA (never :latest).
for repo in $(jq -r '.repositories[].repo' "$CANDIDATE_MANIFEST"); do
  sha="$(jq -r --arg r "$repo" '.repositories[] | select(.repo==$r) | .candidate_sha' "$CANDIDATE_MANIFEST")"
  [ -f "$WORKSPACE/$repo/Dockerfile" ] || continue
  var="$(echo "$repo" | tr '[:lower:]-' '[:upper:]_')_CANDIDATE_IMAGE"
  if ! uses "$var"; then
    echo "skip $repo image: neither integration/ nor a selected suite uses \$$var"
    continue
  fi
  img="ci-local/${repo}:${sha}"
  echo "::group::build $repo image"
  since=$SECONDS
  docker build -t "$img" "$WORKSPACE/$repo"
  echo "::endgroup::"
  mark "build $repo image"
  export "$var=$img"
done
# Components not touched by the feature run at their current main image
# (sha-tagged by repo CI). `junction-ci checkout` already checked them out at
# their default-branch head and recorded the SHA in checkout-report.json; use
# the same SHA so the image and workspace/<repo> agree. Empty repos are skipped.
untouched="{}"
REPORT="$ARTIFACTS/checkout-report.json"
IFS=',' read -ra pairs <<< "${JUNCTION_REPO_MAP:-}"
for kv in "${pairs[@]}"; do
  repo="${kv%%=*}"; full="${kv#*=}"
  jq -e --arg r "$repo" '.repositories[] | select(.repo==$r)' "$CANDIDATE_MANIFEST" >/dev/null && continue
  var="$(echo "$repo" | tr '[:lower:]-' '[:upper:]_')_CANDIDATE_IMAGE"
  [ -n "${!var:-}" ] && continue
  main=""
  [ -f "$REPORT" ] && main="$(jq -r --arg r "$repo" '.checkouts[]? | select(.repo==$r and .source=="default-branch") | .sha' "$REPORT")"
  [ -n "$main" ] || [ -f "$REPORT" ] || main="$(git ls-remote "https://github.com/${full}.git" HEAD | cut -f1)"
  [ -n "$main" ] || continue
  img="ghcr.io/${full,,}:sha-${main}"
  export "$var=$img"
  untouched="$(jq --arg r "$repo" --arg s "$main" '. + {($r): $s}' <<< "$untouched")"
  uses "$var" || continue
  # Pulled here so a refused pull names its fix instead of failing inside `compose up`.
  if ! out="$(docker pull -q "$img" 2>&1)"; then
    echo "$out"
    if grep -qiE 'unauthorized|denied' <<< "$out"; then
      echo "::error::cannot pull $img (untouched component $repo): package ${full#*/} must grant ${GITHUB_REPOSITORY:-the project repo} read access (package settings > Manage Actions access > Add repository, role Read), and $repo's CI must have pushed sha-$main"
    else
      echo "::error::cannot pull $img (untouched component $repo at main): did $repo's CI push sha-$main?"
    fi
    exit 1
  fi
done
echo "$untouched" > "$ARTIFACTS/untouched-components.json"

since=$SECONDS
docker compose -p "$PROJECT" -f integration/compose.yaml up -d --wait
mark "compose up"

status=0
for suite in $suites; do
  cmd="$(yq -r ".suites.\"$suite\".command" integration/test-suites.yaml)"
  stage="$(yq -r ".suites.\"$suite\".stage" integration/test-suites.yaml)"
  timeout_s="$(yq -r ".suites.\"$suite\".timeout_seconds // 600" integration/test-suites.yaml)"
  [ "$stage" = "repo-ci" ] && continue   # repo-local suites already ran in per-repo CI on the same SHAs
  # Keep this marker: the orchestrator classifies a failure of this step
  # before the first "suite <id>" group as a setup failure, not a test failure.
  echo "::group::suite $suite"
  if ! COMPOSE_PROJECT_NAME="$PROJECT" JUNIT_OUTPUT="$ARTIFACTS/junit/$suite.xml" timeout "$timeout_s" bash -c "$cmd"; then
    status=1
    echo "::error::suite $suite failed"
  fi
  echo "::endgroup::"
  mark "suite $suite"
done

docker compose -p "$PROJECT" -f integration/compose.yaml logs --no-color > "$ARTIFACTS/compose.log" 2>&1 || true
conclusion=success; [ $status -eq 0 ] || conclusion=failure
jq -n --arg h "$HASH" --arg c "$conclusion" --arg run "$RUN_ID" --argjson suites "$(printf '%s\n' $suites | jq -R . | jq -s .)" \
  '{candidate_set_hash:$h, conclusion:$c, workflow_run_id:($run|tonumber), suites:$suites}' > "$ARTIFACTS/integration-result.json"
exit $status
