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

gh release create "$TAG" \
  "$DIST"/*.apk "$DIST"/SHA256SUMS.txt "$DIST"/build-info.txt \
  "${ARGS[@]}" 2>&1 | tee -a "$ROOT/build.log"
