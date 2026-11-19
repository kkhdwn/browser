#!/bin/bash
# Pack the build tree into part files ready for upload.
#
# This must never be the reason a build is lost: it is best effort, and the
# next stage can always start from an older checkpoint (or from scratch).
set -uo pipefail

ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
BUILD="$ROOT/chromium"
OUTD="$ROOT/cpout"

rm -rf "$OUTD"
mkdir -p "$OUTD"

# Only the build output is checkpointed. The source tree is re-fetched in the
# next stage (about twelve minutes) which is far cheaper than moving 70 GB of
# source plus output through the artifact service within the job timeout.
if [ ! -d "$BUILD/src/out/Default/obj" ]; then
  echo "[checkpoint] no compiled output yet, nothing worth saving"
  exit 0
fi

FREE_GB=$(df -BG --output=avail "$BUILD" | tail -1 | tr -dc '0-9')
echo "[checkpoint] free space on build volume: ${FREE_GB}G"
if [ "${FREE_GB:-0}" -lt 12 ]; then
  echo "[checkpoint] less than 12G free, skipping the checkpoint to keep the job alive"
  exit 0
fi

printf '%s\n' "${VERSION:-unknown}" > "$BUILD/.ckpt-version"
echo "[checkpoint] packing (streamed, no temporary tarball)"
set -o pipefail
tar -C "$BUILD" -cf - .ckpt-version src/out 2>/dev/null \
  | nice -n 10 zstd -6 -T2 \
  | split -b 3000M -d -a 1 - "$OUTD/part"

ls -lh "$OUTD" || true
shopt -s nullglob
parts=("$OUTD"/part*)
echo "[checkpoint] ${#parts[@]} part(s)"
if [ ${#parts[@]} -gt 6 ]; then
  echo "[checkpoint] more than 6 parts; dropping the newest ones is unsafe, so failing soft"
  rm -rf "$OUTD"
  exit 0
fi
