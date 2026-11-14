#!/usr/bin/env bash
# validate-release-manifest.sh — schema + immutable digests + no placeholders,
# using the orchestrator's own validator (junction-ci). Also checks that the
# checked-out tag commit contains this manifest.
set -euo pipefail
MANIFEST="${1:?manifest path}"
junction-ci validate-release -file "$MANIFEST" -strict=true
tag="$(git describe --tags --exact-match HEAD)"
[ "releases/${tag}.yaml" = "$MANIFEST" ] || { echo "::error::tag $tag does not match $MANIFEST"; exit 1; }
