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
CKPT_RESERVE_MIN="${CKPT_RESERVE_MIN:-90}"
NINJA_JOBS="${NINJA_JOBS:-2}"
STAGE="${STAGE:-1}"
FRESH="${FRESH:-false}"
START_TS="${STAGE_START_TS:-$(date +%s)}"

case "$ARCH" in
  arm64) ABI="arm64-v8a" ;;
  x64)   ABI="x86_64" ;;
  *) echo "unsupported arch: $ARCH" >&2; exit 2 ;;
esac

CHROMIUM_URL="${CHROMIUM_URL:-https://chromium.googlesource.com/chromium/src.git}"
# GitHub's Chromium mirror lives in the same network as the runners and is far
# more reliable than googlesource for the initial tag fetch. Both serve the
# exact same commit for a release tag.
CHROMIUM_MIRROR="${CHROMIUM_MIRROR:-https://github.com/chromium/chromium.git}"
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

# Fetch the pinned tag, trying the GitHub mirror first and retrying each source.
fetch_version() {
  local url attempt
  for url in "$CHROMIUM_MIRROR" "$CHROMIUM_URL"; do
    for attempt in 1 2 3; do
      log "fetching tag $VERSION from $url (attempt $attempt)"
      if timeout 1800 git -C "$SRC" fetch --depth 1 "$url" \
          "refs/tags/$VERSION:refs/tags/$VERSION"; then
        return 0
      fi
      sleep $(( attempt * 20 ))
    done
  done
  return 1
}

# gclient sync is the slowest network step; retrying it is cheaper than losing
# a stage, because a shallow checkout resumes where it stopped.
gclient_sync() {
  local flags="$*" attempt
  for attempt in 1 2 3; do
    # shellcheck disable=SC2086
    if timeout 3600 gclient sync $flags; then
      return 0
    fi
    log "gclient sync failed (attempt $attempt); retrying"
    sleep $(( attempt * 30 ))
  done
  return 1
}

echo "finished=false" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "stage=$STAGE arch=$ARCH abi=$ABI version=$VERSION kind=$KIND" | tee "$ROOT/stage-info.txt"
df -h / "$BUILD" 2>/dev/null || true

MODE="${1:-all}"

# Toolchain paths must be available to both invocations: `prepare` fetches and
# configures the tree, `build` compiles and signs it in a separate process.
if [ -d "$BUILD/depot_tools" ]; then
  export PATH="$BUILD/depot_tools:$PATH"
fi
export JAVA_HOME="$SRC/third_party/jdk/current"
export PATH="$JAVA_HOME/bin:$PATH"
# Googlesource occasionally drops below 1 KB/s for a minute without being
# dead. Abort only after five minutes of near-zero progress; the hard timeout
# below still bounds a real hang.
export GIT_HTTP_LOW_SPEED_LIMIT=50
export GIT_HTTP_LOW_SPEED_TIME=300
export GIT_TERMINAL_PROMPT=0

if [ "$MODE" != "build" ]; then
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
if [ ! -d "$BUILD/depot_tools" ]; then
  log "cloning depot_tools"
  git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git \
    "$BUILD/depot_tools" || fail fetch "depot_tools clone"
fi
# depot_tools ships only wrappers; the pinned python3/cipd payload has to be
# fetched once. `ensure_bootstrap` does exactly that without touching the
# checkout, and is required before gclient/gn can run.
if [ ! -f "$BUILD/depot_tools/python3_bin_reldir.txt" ]; then
  log "bootstrapping depot_tools"
  # ensure_bootstrap is noisy: gsutil.py tries to call luci-auth before it has
  # been downloaded, prints a traceback, and then succeeds anyway. Keep that
  # out of the build log, but show it if the bootstrap actually fails.
  if ! ( cd "$BUILD/depot_tools" && timeout 900 ./ensure_bootstrap \
           > "$BUILD/bootstrap.log" 2>&1 ); then
    tail -n 40 "$BUILD/bootstrap.log" || true
    fail fetch "depot_tools bootstrap"
  fi
  if [ ! -f "$BUILD/depot_tools/python3_bin_reldir.txt" ]; then
    tail -n 40 "$BUILD/bootstrap.log" || true
    fail fetch "depot_tools bootstrap left no python3 marker"
  fi
fi
export DEPOT_TOOLS_UPDATE=0
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
# Fresh runner VMs start apt-daily/unattended-upgrades, which can hold the
# dpkg lock for a long time. Waiting for it (instead of racing it) is the
# difference between a three-minute install and a thirty-minute timeout.
export NEEDRESTART_MODE=a
log "waiting for the package manager lock"
# Timers re-arm themselves after a service is stopped, which is how a second
# unattended-upgrades run grabbed the lock mid-install. Mask them, and give apt
# its own lock timeout so it can never block a job indefinitely.
sudo systemctl mask --now apt-daily.service apt-daily-upgrade.service unattended-upgrades.service 2>/dev/null || true
sudo systemctl stop apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
sudo pkill -9 -f '[u]nattended-upgrade' 2>/dev/null || true
printf 'DPkg::Lock::Timeout "600";\nAcquire::Retries "3";\n' | sudo tee /etc/apt/apt.conf.d/99-runner-lock >/dev/null
for _ in $(seq 1 120); do
  if ! sudo fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

APT_OPTS=(-o Acquire::Retries=10 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30)

# Ubuntu's archives regularly answer 503 or serve an index that is one minute
# ahead of the pool. Both are transient; a bounded retry loop turns them into a
# delay instead of a lost stage.
apt_retry() {
  local desc="$1" limit="$2"; shift 2
  local attempt
  for attempt in 1 2 3 4 5; do
    if timeout "$limit" sudo DEBIAN_FRONTEND=noninteractive "$@"; then
      return 0
    fi
    log "apt step '$desc' failed (attempt $attempt); retrying"
    sudo apt-get -f install -y -qq "${APT_OPTS[@]}" >/dev/null 2>&1 || true
    sleep $(( attempt * 30 ))
  done
  return 1
}

apt_retry "update" 600 apt-get update -qq "${APT_OPTS[@]}" || fail infra "apt update"
apt_retry "install host packages" 900 apt-get install -y -qq "${APT_OPTS[@]}" \
  git curl lsb-release file python3 python3-pip zstd unzip xz-utils \
  pkg-config libglib2.0-dev >/dev/null || fail infra "apt install"
sudo apt-get clean
sudo rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# chromium checkout at the pinned version
# ---------------------------------------------------------------------------
# gclient state lives next to src (not inside it, so it is cheap to recreate).
cat > "$BUILD/.gclient" <<GCLIENT
solutions = [
  {
    "name": "src",
    "url": "$CHROMIUM_URL",
    "managed": False,
    "custom_deps": {},
    "custom_vars": {},
  },
]
target_os = ["android"]
GCLIENT

if [ ! -d "$SRC/.git" ]; then
  # Bootstrap straight at the pinned tag instead of fetching main and then
  # moving the whole dependency graph. This saves roughly half an hour and a
  # lot of network on every fresh stage 1.
  log "bootstrapping Chromium $VERSION (shallow)"
  mkdir -p "$SRC"
  cd "$SRC" || fail infra "cd src"
  git init -q
  git remote add origin "$CHROMIUM_URL"
  git config --local gc.auto 0
  fetch_version || fail fetch "git fetch $VERSION"
  git checkout -q "refs/tags/$VERSION" || fail checkout "git checkout $VERSION"

  cd "$BUILD" || fail infra "cd build"
  log "gclient sync (first time)"
  gclient_sync -D --no-history --nohooks || fail sync "gclient sync"
  timeout 1800 gclient runhooks || fail sync "gclient runhooks"
fi

cd "$SRC" || fail infra "cd src"

if ! git rev-parse -q --verify "refs/tags/$VERSION" >/dev/null; then
  log "fetching tag $VERSION"
  timeout 1800 git fetch --depth 1 origin "refs/tags/$VERSION:refs/tags/$VERSION" \
    || fail fetch "git fetch $VERSION"
fi

CURRENT_TAG="$(git describe --tags --exact-match 2>/dev/null || true)"
if [ "$CURRENT_TAG" != "$VERSION" ]; then
  log "checking out $VERSION (was ${CURRENT_TAG:-unknown})"
  git checkout -f "$VERSION" || fail checkout "git checkout $VERSION"
  git clean -fdq || true
  log "syncing dependencies for $VERSION"
  gclient_sync -D --no-history --force --nohooks || fail sync "gclient sync"
  timeout 1800 gclient runhooks || fail sync "gclient runhooks"
fi

# Android host tools need the full dependency set; safe to re-run.
if [ -x "$SRC/build/install-build-deps.sh" ]; then
  log "install-build-deps --android"
  ird_ok=0
  for attempt in 1 2 3; do
    if timeout 2700 sudo DEBIAN_FRONTEND=noninteractive \
        "$SRC/build/install-build-deps.sh" --android --no-prompt; then
      ird_ok=1
      break
    fi
    log "install-build-deps failed (attempt $attempt); retrying"
    sudo apt-get -f install -y -qq "${APT_OPTS[@]}" >/dev/null 2>&1 || true
    sleep $(( attempt * 60 ))
  done
  [ "$ird_ok" = "1" ] || fail infra "install-build-deps"
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
  # One prepared image for every launcher and application icon. Only files that
  # already exist are replaced, so the resource set stays exactly as declared.
  if [ -d "$ROOT/assets/icons" ]; then
    log "overlaying project icons"
    ( cd "$ROOT/assets/icons" && find . -type f -name '*.png' -print0 |
        while IFS= read -r -d '' icon; do
          dest="$SRC/${icon#./}"
          [ -f "$dest" ] && cp "$icon" "$dest"
        done )
  fi
  printf '%s' "$WANT" > "$STATE"
else
  log "patches already applied for this version"
fi

# ---------------------------------------------------------------------------
# gn + compile
# ---------------------------------------------------------------------------
# Ninja decides what to rebuild from mtimes. Restored objects stay valid if the
# freshly-checked-out sources look older than them; files touched by the patch
# series are made newer so ninja rebuilds exactly those (and their dependents).
HAD_OBJ=0
[ -d "$OUT/obj" ] && HAD_OBJ=1
CKPT_PATCHES="$(cat "$BUILD/.ckpt-patches" 2>/dev/null || true)"
CKPT_VERSION="$(cat "$BUILD/.ckpt-version" 2>/dev/null || true)"
VERSION_OK=0
if [ "$CKPT_VERSION" = "$VERSION" ]; then
  VERSION_OK=1
elif [ -z "$CKPT_VERSION" ] || [ "$CKPT_VERSION" = "unknown" ]; then
  VERSION_OK=1
  log "checkpoint has no version marker; validating it with the patch marker only"
fi

PATCH_FILES="$(grep -h '^diff --git ' "$ROOT"/patches/*.patch 2>/dev/null \
  | awk '{print $3}' | sed 's#^a/##' | sort -u)"
PREV_PATCH_FILES="$(cat "$BUILD/.ckpt-files" 2>/dev/null || true)"

if [ "$HAD_OBJ" = "1" ] && [ "$VERSION_OK" = "1" ]; then
  log "reusing restored objects (patch set unchanged: $([ "$CKPT_PATCHES" = "$PATCH_SHA" ] && echo yes || echo no))"
  find "$SRC" -path "$SRC/out" -prune -o -type f -print0 2>/dev/null \
    | xargs -0 -r touch -d '2020-01-01 00:00:00' 2>/dev/null || true
  for f in $PATCH_FILES $PREV_PATCH_FILES; do
    [ -f "$SRC/$f" ] && touch "$SRC/$f"
  done
fi

mkdir -p "$OUT"
sed "s/__TARGET_CPU__/$ARCH/" "$CARGS" > "$OUT/args.gn"
log "gn gen"
gn gen "$OUT" || fail gn "gn gen failed"
cp "$OUT/args.gn" "$DIST/args.used.gn"

# Verify the checkpoint actually reduced the work BEFORE spending hours on it.
# A dry run costs seconds and turns "did the restore work?" into a number.
if [ -f "$OUT/build.ninja" ]; then
  REMAINING="$(ninja -C "$OUT" -n chrome_public_apk 2>/dev/null | wc -l || echo 0)"
  log "[plan] $REMAINING build steps remain"
  printf 'remaining_steps=%s\nrestored_checkpoint=%s\n' "$REMAINING" \
    "${CKPT_VERSION:-none}" > "$ROOT/plan.txt"
  if [ "$HAD_OBJ" = "1" ]; then
    if [ "$REMAINING" -gt 80000 ]; then
      # Refuse to spend hours on a restore that clearly did not take effect.
      fail verify "checkpoint restored but $REMAINING steps remain (expected about 40000)"
    fi
  fi
fi

if [ "$MODE" = "prepare" ]; then
  log "prepare complete"
  echo "finished=false" >> "${GITHUB_OUTPUT:-/dev/null}"
  mark none
  exit 0
fi
fi  # MODE != build

if ! command -v autoninja >/dev/null 2>&1; then
  log "autoninja missing. PATH=$PATH"
  ls -l "$BUILD/depot_tools/autoninja" 2>&1 || true
  fail infra "autoninja missing from PATH"
fi
if [ ! -f "$OUT/build.ninja" ]; then
  fail gn "build.ninja missing: the prepare step did not complete"
fi
log "toolchain: $(command -v autoninja) | $(command -v gn || true)"

REMAIN="$(remaining)"
if [ "$REMAIN" -lt 240 ]; then
  log "only $((REMAIN/60)) min left; skipping compile to save the checkpoint"
else
  log "compiling chrome_public_apk with -j$NINJA_JOBS for up to $((REMAIN/60)) min"
  STALL_SECONDS="${STALL_SECONDS:-1500}"
  DEADLINE=$(( $(date +%s) + REMAIN ))
  log "stall watchdog: no output for $((STALL_SECONDS/60)) min fails the stage"
  autoninja -C "$OUT" -j "$NINJA_JOBS" chrome_public_apk &
  NINJA_PID=$!
  last_size=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
  last_change=$(date +%s)
  rc=0
  while kill -0 "$NINJA_PID" 2>/dev/null; do
    sleep 30
    size=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
    if [ "$size" != "$last_size" ]; then
      last_size=$size
      last_change=$(date +%s)
    fi
    now=$(date +%s)
    if [ "$now" -ge "$DEADLINE" ]; then
      log "time budget reached; stopping the compiler"
      rc=124
      break
    fi
    if [ $(( now - last_change )) -ge "$STALL_SECONDS" ]; then
      log "no compiler output for $(( (now - last_change) / 60 )) min; treating the build as stalled"
      rc=125
      break
    fi
  done
  if [ "$rc" -eq 0 ]; then
    wait "$NINJA_PID"
    rc=$?
  else
    kill -INT "$NINJA_PID" 2>/dev/null || true
    sleep 20
    kill -KILL "$NINJA_PID" 2>/dev/null || true
  fi
  # `timeout`/kill only reaches autoninja; make sure no child ninja keeps
  # writing into the tree while the checkpoint is packed.
  pkill -INT -f '[n]inja' 2>/dev/null || true
  sleep 5
  pkill -KILL -f '[n]inja' 2>/dev/null || true
  case "$rc" in
    0) log "compile complete" ;;
    124|130|137) log "time budget hit; checkpointing the partial build" ;;
    125) fail stall "no compiler progress for $((STALL_SECONDS/60)) minutes" ;;
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
