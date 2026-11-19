#!/bin/bash
# Pack the build tree into part files ready for upload.
set -euo pipefail

ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
BUILD="$ROOT/chromium"
OUTD="$ROOT/cpout"

rm -rf "$OUTD"
mkdir -p "$OUTD"

if [ ! -d "$BUILD/src" ]; then
  echo "[checkpoint] nothing to save"
  exit 0
fi

df -h "$BUILD" || true
echo "[checkpoint] packing (streamed, no temporary tarball)"
# Streamed so the peak disk usage stays at (tree) instead of (tree + archive).
tar -C "$BUILD" -cf - src .vpython-root 2>/dev/null \
  | zstd -3 -T0 \
  | split -b 4000M -d -a 1 - "$OUTD/part"

ls -lh "$OUTD"
shopt -s nullglob
parts=("$OUTD"/part*)
echo "[checkpoint] ${#parts[@]} part(s)"
if [ ${#parts[@]} -gt 6 ]; then
  echo "[checkpoint] ERROR: more than 6 parts; increase the upload steps" >&2
  exit 1
fi
