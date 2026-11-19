#!/bin/bash
# Produce a compact failure summary and open/refresh a build issue.
set -uo pipefail

ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
LOG="$ROOT/build.log"
KIND="$(cat "$ROOT/failure-kind" 2>/dev/null || echo unknown)"
SUMMARY="$ROOT/failure-summary.txt"

{
  echo "stage: ${STAGE:-?} arch: ${ARCH:-?} version: ${VERSION:-?}"
  echo "kind: $KIND"
  echo
  echo "=== last 120 log lines ==="
  tail -n 120 "$LOG" 2>/dev/null
  echo
  echo "=== first matching errors ==="
  grep -nE "FAILED:|error:|Error:|PATCH_FAILED|ninja: build stopped|No space left|Killed" "$LOG" 2>/dev/null | tail -n 60
} > "$SUMMARY"

sed -i -E 's/(ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]+)/***/g' "$SUMMARY"
cat "$SUMMARY"

if [ -n "${GH_TOKEN:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
  title="Build failed: stage ${STAGE:-?} ${ARCH:-?} (${KIND})"
  {
    echo "Workflow run: ${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID:-}"
    echo
    echo '```'
    head -c 40000 "$SUMMARY"
    echo '```'
  } > "$ROOT/issue-body.md"
  gh label create build-failure -R "$GITHUB_REPOSITORY" --color B60205 \
    --description "Automated build failure" 2>/dev/null || true
  gh issue create -R "$GITHUB_REPOSITORY" \
    --title "$title" --body-file "$ROOT/issue-body.md" \
    --label build-failure 2>/dev/null \
    || gh issue create -R "$GITHUB_REPOSITORY" --title "$title" --body-file "$ROOT/issue-body.md" \
    || echo "[diagnose] could not open issue"
fi
