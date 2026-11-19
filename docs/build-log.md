# Build log

Chronological notes on what broke and how it was fixed. Every fix lands as a
commit so the next run picks it up.

## 2026-11-19 — initial pipeline

- Baseline: Chromium `158.0.8127.43` (Android stable; `159.0.8154.18` also out).
- Confirmed upstream: `enable_desktop_android_extensions = is_desktop_android`
  in `extensions/buildflags/buildflags.gni`. Chromium 158 already ships
  `chrome/browser/ui/android/toolbar/.../extensions/` and
  `chrome/browser/ui/android/extensions/` (action popups, install dialog), plus
  `base/android/.../VirtualDocumentPath.java`. No extension porting needed.
- `minSdk` is Chromium's `default_min_sdk_version = 29`; Android 10+.
- `gn gen` accepts the full arg set: 93,254 targets from 4,940 files.

### Failure 1 — `python3_bin_reldir.txt not found`

`DEPOT_TOOLS_UPDATE=0` was exported before the first `gclient` call, which also
disables depot_tools' bootstrap, so `fetch`/`gclient` died immediately.
Fix: run `ensure_bootstrap` explicitly, then export `DEPOT_TOOLS_UPDATE=0`.
Also replaced `fetch android` with a shallow bootstrap at the pinned tag
(`git init` + `git fetch --depth 1 refs/tags/<ver>` + `.gclient` with
`managed: False` + `gclient sync --no-history --nohooks`), which avoids
fetching main first.

### Failure 2 — chain continued after a deterministic failure

The failure-classification step ran after checkpoint packing, so a stage that
failed before packing produced no `deterministic` output and the next stage
started from scratch. Fix: classify immediately after prepare, and require
`needs.<prev>.result != 'skipped'` in every chained stage.

### Failure 3 — `autoninja: No such file or directory`

Prepare and compile run as two invocations of `ci/stage.sh` (`prepare` then
`build`). The depot_tools `PATH` export was inside the `prepare`-only block, so
the compile invocation could not find `autoninja`. Fix: set the toolchain
`PATH`/`JAVA_HOME` before the mode guard, and add a preflight check that fails
with a clear message if `autoninja` or `build.ninja` is missing.

### Notes for the next runs

- Prepare takes ~15-55 minutes depending on network; compile budget is
  `350 - 60` minutes per stage.
- Checkpoints are streamed (`tar | zstd -5 | split -b 4000M`), so peak disk is
  the tree plus the parts, not tree plus archive.
- Checkpoint is skipped (soft) when the build volume has less than 20 GB free
  or when no `out/Default/obj` exists yet.
- Logs are uploaded before packing, so a crash during packing cannot hide the
  real error.
