#!/bin/bash
# Restore a checkpoint split into part files downloaded into ./cp.
set -uo pipefail

ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
BUILD="$ROOT/chromium"
VERSION="${VERSION:-$(tr -d '[:space:]' < "$ROOT/chromium.pin" 2>/dev/null || true)}"
mkdir -p "$BUILD"

shopt -s nullglob
parts=("$ROOT"/cp/part*)
if [ ${#parts[@]} -eq 0 ]; then
  echo "[restore] no checkpoint for this stage"
  exit 0
fi

echo "[restore] unpacking ${#parts[@]} part(s)"
# Delete each part right after it has been consumed so the 25 GB checkpoint
# never competes with the source tree for disk space.
for f in "${parts[@]}"; do
  cat "$f"
  rm -f "$f"
done | zstd -d -T0 | tar -x -C "$BUILD" -f - || {
  echo "[restore] checkpoint is unusable; starting without it" >&2
  rm -rf "$BUILD/src"
  exit 0
}

rm -rf "$ROOT/cp"

CKPT_VERSION="$(cat "$BUILD/.ckpt-version" 2>/dev/null || true)"
if [ -n "${VERSION:-}" ] && [ -n "$CKPT_VERSION" ] \
   && [ "$CKPT_VERSION" != "unknown" ] && [ "$CKPT_VERSION" != "$VERSION" ]; then
  echo "[restore] checkpoint is for Chromium $CKPT_VERSION, wanted $VERSION: discarding it"
  rm -rf "$BUILD/src" "$BUILD/.ckpt-version"
fi
df -h "$BUILD" || true
echo "[restore] done"
