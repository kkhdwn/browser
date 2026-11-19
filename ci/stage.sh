#!/bin/bash
# Build one resumable stage of the Android APK.
#
# The source tree (including out/) lives on the large build volume and is
# checkpointed between jobs. A stage either finishes the APK, or compiles for
# as long as the job timeout allows and hands the tree to the next stage.
set -uo pipefail

ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
BUILD="$ROOT/chromium"
SRC="$BUILD/src"
OUT="$SRC/out/Default"
DIST="$ROOT/dist"
STATE="$BUILD/.build-state"
LOG="$ROOT/build.log"
FAILFILE="$ROOT/failure-kind"

ARCH="${ARCH:-arm64}"
KIND="${KIND:-beta}"
JOB_TIMEOUT_MIN="${JOB_TIMEOUT_MIN:-350}"
CKPT_RESERVE_MIN="${CKPT_RESERVE_MIN:-60}"
NINJA_JOBS="${NINJA_JOBS:-2}"
STAGE="${STAGE:-1}"
FRESH="${FRESH:-false}"
START_TS="${STAGE_START_TS:-$(date +%s)}"

case "$ARCH" in
  arm64) ABI="arm64-v8a" ;;
  x64)   ABI="x86_64" ;;
  *) echo "unsupported arch: $ARCH" >&2; exit 2 ;;
esac

CARGS="$ROOT/args.gn"
PIN="$(tr -d '[:space:]' < "$ROOT/chromium.pin")"
VERSION="${VERSION:-$PIN}"
VERSION="$(echo "$VERSION" | tr -d '[:space:]')"
[ -z "$VERSION" ] && VERSION="$PIN"

mkdir -p "$BUILD" "$DIST"
exec > >(tee -a "$LOG") 2>&1
trap 'sync' EXIT

log() { echo "[$(date -u +%H:%M:%S)] $*"; }
mark() { echo "$1" > "$FAILFILE"; }
fail() { mark "$1"; log "FATAL ($1): ${*:2}"; exit 1; }
remaining() { echo $(( START_TS + (JOB_TIMEOUT_MIN - CKPT_RESERVE_MIN) * 60 - $(date +%s) )); }

echo "finished=false" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "stage=$STAGE arch=$ARCH abi=$ABI version=$VERSION kind=$KIND" | tee "$ROOT/stage-info.txt"
df -h / "$BUILD" 2>/dev/null || true

# ---------------------------------------------------------------------------
# fresh start
# ---------------------------------------------------------------------------
if [ "$FRESH" = "true" ] && [ -d "$SRC" ]; then
  log "fresh=true: deleting source tree"
  rm -rf "$SRC" "$BUILD/depot_tools" "$STATE"
fi

# ---------------------------------------------------------------------------
# depot_tools + caches (kept outside src so the checkpoint owns them)
# ---------------------------------------------------------------------------
export DEPOT_TOOLS_UPDATE=0
if [ ! -d "$BUILD/depot_tools" ]; then
  log "cloning depot_tools"
  git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git \
    "$BUILD/depot_tools" || fail fetch "depot_tools clone"
fi
export PATH="$BUILD/depot_tools:$PATH"
export VPYTHON_VIRTUALENV_ROOT="$BUILD/.vpython-root"
export CIPD_CACHE_DIR="$BUILD/.cipd-cache"
export TMPDIR="$BUILD/.tmp"
export XDG_CACHE_HOME="$BUILD/.cache"
mkdir -p "$VPYTHON_VIRTUALENV_ROOT" "$CIPD_CACHE_DIR" "$TMPDIR" "$XDG_CACHE_HOME"

# ---------------------------------------------------------------------------
# system dependencies (every stage runs on a brand new VM)
# ---------------------------------------------------------------------------
log "installing host packages"
sudo apt-get update -qq || fail infra "apt update"
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  git curl lsb-release file python3 python3-pip zstd unzip xz-utils \
  pkg-config libglib2.0-dev >/dev/null || fail infra "apt install"
sudo apt-get clean
sudo rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# chromium checkout at the pinned version
# ---------------------------------------------------------------------------
if [ ! -d "$SRC/.git" ]; then
  log "fetching Chromium (first stage, this takes a while)"
  cd "$BUILD" || fail infra "cd build"
  fetch --nohooks --no-history android || fail fetch "gclient fetch"
fi

cd "$SRC" || fail infra "cd src"

if ! git rev-parse -q --verify "refs/tags/$VERSION" >/dev/null; then
  log "fetching tag $VERSION"
  git fetch --depth 1 origin "refs/tags/$VERSION:refs/tags/$VERSION" \
    || fail fetch "git fetch $VERSION"
fi

CURRENT_TAG="$(git describe --tags --exact-match 2>/dev/null || true)"
if [ "$CURRENT_TAG" != "$VERSION" ]; then
  log "checking out $VERSION (was ${CURRENT_TAG:-unknown})"
  git checkout -f "$VERSION" || fail checkout "git checkout $VERSION"
  git clean -fdq || true
  log "syncing dependencies for $VERSION"
  gclient sync -D --no-history --force || fail sync "gclient sync"
  gclient runhooks || fail sync "gclient runhooks"
fi

# Android host tools need the full dependency set; safe to re-run.
if [ -x "$SRC/build/install-build-deps.sh" ]; then
  log "install-build-deps --android"
  sudo DEBIAN_FRONTEND=noninteractive "$SRC/build/install-build-deps.sh" --android --no-prompt \
    || fail infra "install-build-deps"
fi

# ---------------------------------------------------------------------------
# patches
# ---------------------------------------------------------------------------
PATCH_SHA="$(cat "$ROOT"/patches/*.patch 2>/dev/null | sha256sum | awk '{print $1}')"
WANT="$VERSION|$PATCH_SHA"
HAVE="$(cat "$STATE" 2>/dev/null || true)"
if [ "$HAVE" != "$WANT" ]; then
  log "patch state changed; resetting tree and applying patches"
  git checkout -f -- . || fail patch "git checkout -- ."
  git clean -fdq || true
  bash "$ROOT/apply.sh" "$SRC" || fail patch "patch series does not apply"
  printf '%s' "$WANT" > "$STATE"
else
  log "patches already applied for this version"
fi

# ---------------------------------------------------------------------------
# gn + compile
# ---------------------------------------------------------------------------
mkdir -p "$OUT"
sed "s/__TARGET_CPU__/$ARCH/" "$CARGS" > "$OUT/args.gn"
log "gn gen"
gn gen "$OUT" || fail gn "gn gen failed"
cp "$OUT/args.gn" "$DIST/args.used.gn"

REMAIN="$(remaining)"
if [ "$REMAIN" -lt 240 ]; then
  log "only $((REMAIN/60)) min left; skipping compile to save the checkpoint"
else
  log "compiling chrome_public_apk with -j$NINJA_JOBS for up to $((REMAIN/60)) min"
  rc=0
  timeout --signal=INT --kill-after=120 "$REMAIN" \
    autoninja -C "$OUT" -j "$NINJA_JOBS" chrome_public_apk || rc=$?
  case "$rc" in
    0) log "compile complete" ;;
    124|130|137) log "time budget hit; checkpointing partial build" ;;
    *) fail compile "ninja exited $rc" ;;
  esac
fi

# ---------------------------------------------------------------------------
# APK: sign, version, done
# ---------------------------------------------------------------------------
APK="$(ls -1 "$OUT"/apks/ChromePublic.apk 2>/dev/null | head -1)"
if [ -z "$APK" ]; then
  APK="$(find "$OUT" -maxdepth 3 -name '*.apk' -print -quit 2>/dev/null || true)"
fi
if [ -z "$APK" ]; then
  log "no APK yet at stage $STAGE"
  echo "finished=false" >> "${GITHUB_OUTPUT:-/dev/null}"
  mark none
  exit 0
fi

log "APK produced: $APK"
export JAVA_HOME="$SRC/third_party/jdk/current"
export PATH="$JAVA_HOME/bin:$PATH"
BT="$(ls -d "$SRC"/third_party/android_sdk/public/build-tools/*/ 2>/dev/null | sort -V | tail -1)"
[ -n "$BT" ] || fail sign "no Android build-tools found"
[ -n "${KEYSTORE_B64:-}" ] || fail sign "KEYSTORE_B64 secret missing"

KS="$RUNNER_TEMP/browser.p12"
printf '%s' "$KEYSTORE_B64" | base64 -d > "$KS" || fail sign "keystore decode"
chmod 600 "$KS"

MAJOR="${VERSION%%.*}"
REST="${VERSION#*.}"
PATCH="${VERSION##*.}"
RUN_NO="${GITHUB_RUN_NUMBER:-1}"
VCODE=$(( MAJOR * 10000000 + PATCH * 10000 + RUN_NO % 10000 ))
VNAME="${VERSION}-b${RUN_NO}"
APKNAME="browser-${VNAME}-${ABI}.apk"

"${BT}zipalign" -p -f 4 "$APK" "$DIST/aligned.apk" || fail sign "zipalign"
"${BT}apksigner" sign \
  --ks "$KS" --ks-type PKCS12 \
  --ks-pass "pass:${KEYSTORE_PASSWORD:?}" \
  --key-pass "pass:${KEY_PASSWORD:-${KEYSTORE_PASSWORD:?}}" \
  --ks-key-alias "${KEY_ALIAS:-kkhdwn}" \
  --min-sdk-version 26 \
  --out "$DIST/$APKNAME" "$DIST/aligned.apk" || fail sign "apksigner sign"
"${BT}apksigner" verify --print-certs "$DIST/$APKNAME" | head -5 || fail sign "apksigner verify"
rm -f "$DIST/aligned.apk"

printf '%s\n' "$VNAME" > "$DIST/version.txt"
printf '%s\n' "$VCODE" > "$DIST/version-code.txt"
printf '%s\n' "$ABI" > "$DIST/abi.txt"
printf 'versionName=%s\nversionCode=%s\nchromium=%s\nabi=%s\n' "$VNAME" "$VCODE" "$VERSION" "$ABI" > "$DIST/build-info.txt"
(cd "$DIST" && sha256sum "$APKNAME" > SHA256SUMS.txt && cat SHA256SUMS.txt)

mark none
{
  echo "finished=true"
  echo "version=$VNAME"
  echo "apk=$APKNAME"
} >> "${GITHUB_OUTPUT:-/dev/null}"
log "done: $APKNAME"
