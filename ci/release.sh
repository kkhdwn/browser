#!/bin/bash
# Publish the signed APK as a GitHub release.
set -euo pipefail

ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
DIST="$ROOT/dist"
ABI="$(cat "$DIST/abi.txt")"
VNAME="$(cat "$DIST/version.txt")"
VCODE="$(cat "$DIST/version-code.txt")"
TAG="v${VNAME}-${ABI}"

{
  echo "Chromium ${VERSION:-?} built for ${ABI}."
  echo
  echo '```'
  cat "$DIST/build-info.txt"
  echo '```'
  echo
  echo "Signed with the project release key. Verify with \`apksigner verify --print-certs\`."
  echo "SHA-256 checksums are attached as SHA256SUMS.txt."
} > "$ROOT/release-notes.md"

ARGS=(--title "Browser ${VNAME} (${ABI})" --notes-file "$ROOT/release-notes.md" --target "$GITHUB_SHA" --latest=false)
if [ "${KIND:-beta}" = "beta" ]; then
  ARGS+=(--prerelease)
fi
if [ "${KIND:-beta}" = "release" ] && [ "$ABI" = "arm64-v8a" ]; then
  ARGS+=(--latest)
fi

# api.github.com occasionally times out from the runners; a failed publish must
# not throw away an APK that already compiled and signed.
for attempt in 1 2 3; do
  if gh release create "$TAG" \
      "$DIST"/*.apk "$DIST"/SHA256SUMS.txt "$DIST"/build-info.txt \
      "${ARGS[@]}" 2>&1 | tee -a "$ROOT/build.log"; then
    break
  fi
  echo "[release] publish attempt $attempt failed; retrying" | tee -a "$ROOT/build.log"
  sleep $(( attempt * 30 ))
  [ "$attempt" = "3" ] && exit 1
done
