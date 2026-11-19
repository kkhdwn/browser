#!/bin/bash
# Apply the patch series to a Chromium checkout.
#
# Usage: ./apply.sh [path/to/chromium/src]
#
# Every patch is a plain `git format-patch` style file. They are applied with
# --3way so a patch that only needs fuzz still lands, and a patch that truly
# does not apply fails loudly instead of being skipped.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${1:-$ROOT/chromium/src}"

cd "$SRC"

shopt -s nullglob
patches=("$ROOT"/patches/*.patch)
if [ ${#patches[@]} -eq 0 ]; then
  echo "[apply] no patches yet, building stock Chromium"
  exit 0
fi

for patch in "${patches[@]}"; do
  echo "[apply] $(basename "$patch")"
  if ! git apply --3way --whitespace=nowarn "$patch"; then
    echo "[apply] FAILED: $(basename "$patch")" >&2
    exit 3
  fi
done

echo "[apply] ${#patches[@]} patch(es) applied"
