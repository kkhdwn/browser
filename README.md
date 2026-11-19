# Browser

An Android browser built straight from Chromium, with Chrome Web Store
extensions enabled, built and released entirely by GitHub Actions.

- **Not a fork.** This repository contains a build configuration, a patch
  series, and CI. Chromium itself is fetched from `chromium.googlesource.com`
  at the pinned version during the build.
- **Extensions come from Chromium itself.** Chromium's desktop-android
  configuration (`is_desktop_android = true`) compiles the full extensions
  stack for Android: `chrome://extensions`, the extension toolbar, action
  popups, the install dialog, and CRX handling. We do not reimplement that.
- **No code runs on a developer machine.** Every build runs on GitHub-hosted
  `ubuntu-24.04` runners, split into resumable stages because a full Chromium
  build does not fit in a single six-hour job.

## Layout

```
chromium.pin        Chromium version to build
args.gn             GN args (target_cpu is substituted per architecture)
apply.sh            apply patches/ to a checkout
patches/            our patch series
ci/stage.sh         one resumable build stage (fetch, patch, gn, ninja, sign)
ci/*.sh             checkpoint, restore, diagnose, release, pin helpers
.github/workflows/  build chain + upstream stable watcher
```

## How the build works

1. `build.yml` dispatches a chain of up to 12 `stage.yml` jobs, one per
   architecture.
2. The first stage fetches Chromium at `chromium.pin`, installs Android build
   dependencies, applies the patch series, runs `gn gen`, and compiles
   `chrome_public_apk` until the job time budget runs out.
3. Before the budget ends, the source tree (including `out/`) is packed with
   zstd, split into 4 GB parts, and uploaded as artifacts. The next stage
   restores it and continues compiling.
4. The stage that produces `ChromePublic.apk` zipaligns it, signs it with the
   release key from secrets, records `versionName`/`versionCode`, publishes a
   GitHub release, and attaches SHA-256 checksums.
5. `upstream-watch.yml` checks `chromiumdash` daily. When Android stable moves
   ahead of `chromium.pin` it opens an issue, and (with repository variable
   `AUTO_BUILD=1`) starts a release build for the new version. A successful
   release build moves the pin forward automatically.

## Versioning

`versionName = <chromium version>-b<run number>`, for example
`158.0.8127.43-b12`.

`versionCode = major * 10000000 + patch * 10000 + (run number % 10000)`,
which is strictly increasing for every build and stays below Android's limit.
Updates only install over an older APK when the signing key is identical, so
the keystore in secrets must never be regenerated.

## Secrets

| Secret | Purpose |
| --- | --- |
| `KEYSTORE_B64` | base64 of the PKCS#12 release keystore |
| `KEYSTORE_PASSWORD` | keystore password |
| `KEY_ALIAS` | key alias inside the keystore |
| `KEY_PASSWORD` | key password |
| `AUTOMATION_TOKEN` | PAT used by `upstream-watch` to dispatch builds |

## Local build (optional)

A local build needs Linux, ~100 GB of disk and about 16 GB of RAM:

```bash
./build.sh          # not provided: CI is the supported path
```

The supported path is GitHub Actions. That is deliberate: the whole point is
that no build environment lives on a workstation.

## Licensing

Our build scripts, CI and patches are BSD-3-Clause. Chromium is BSD-3-Clause
as well; see `NOTICE`. We do not use code from GPL-licensed browsers.
