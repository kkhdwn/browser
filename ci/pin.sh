#!/bin/bash
# Move chromium.pin forward after a successful release build of a new version.
set -euo pipefail

ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
PIN="$(tr -d '[:space:]' < "$ROOT/chromium.pin")"
NEW="$(echo "${VERSION:-}" | tr -d '[:space:]')"

if [ -z "$NEW" ] || [ "$NEW" = "$PIN" ]; then
  echo "[pin] nothing to do (pin=$PIN)"
  exit 0
fi

cd "$ROOT"
printf '%s\n' "$NEW" > chromium.pin
SHA="$(gh api "repos/$GITHUB_REPOSITORY/contents/chromium.pin" --jq .sha 2>/dev/null || true)"
if [ -z "$SHA" ]; then
  echo "[pin] cannot read current sha; leaving the working tree change only"
  exit 0
fi
gh api -X PUT "repos/$GITHUB_REPOSITORY/contents/chromium.pin" \
  -f message="chromium: bump to $NEW (built successfully)" \
  -f content="$(base64 -w0 chromium.pin)" \
  -f sha="$SHA" \
  -f branch=main >/dev/null
echo "[pin] chromium.pin -> $NEW"
