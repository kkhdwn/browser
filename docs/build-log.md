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

## 2026-11-22 — startup SIGTRAP on Android 12, first analysis

First run of a shipped APK on real hardware (`b28`, Redmi 9A / `citrus_id`,
Android 12 / SDK 31, arm64-v8a, PowerVR GE8320).

Symptom: installs, `ChromeTabbedActivity` is created, started and resumed,
first draw completes at 726 ms, then the process dies at 3.4 s.

```
F libc   : Fatal signal 5 (SIGTRAP), code 1 (TRAP_BRKPT) in tid 16052 (.kkhdwn.browser)
```

`Download/browser-native.log` written by patch 0005 held the reason, which
never reaches logcat because the browser's stderr is redirected there:

```
[ERROR:gpu/ipc/service/gpu_init.cc:224] Vulkan not supported with in process gpu
[FATAL:content/browser/gpu/gpu_data_manager_impl_private.cc:385] GPU process isn't usable. Goodbye.
```

Cause: `b28` still carried the diagnostic `--in-process-gpu` switch
(commit `64675c3`). With the GPU service inside the browser process, GPU init
runs against the browser's command line. The `--use-vulkan=none` and
`--disable-features=Vulkan` switches were appended from `onCreate`, i.e. after
the feature list had already been initialized, so Vulkan was still on. In-process
GPU plus Vulkan is refused (`gpu_init.cc:224`), `GpuDataManagerImpl` gives up,
and `IMMEDIATE_CRASH()` turns that into SIGTRAP.

Fix, already on `main` as `3dbf2d4`:

- the in-process GPU switch is gone — the GPU service runs in its own process,
  where Vulkan can be turned off properly;
- `0009-apply-switches-before-feature-list` appends the GPU switches directly
  after `CommandLineInitUtil.initCommandLine` and before the feature list is
  created, so `--use-vulkan=none`, `--use-angle=gles` and
  `--disable-features=Vulkan,SkiaGraphite` actually take effect;
- `0008` keeps the experimental Android GPU sandbox off, so the GPU process is
  not refused at launch on Android 12.

Verification: build dispatched on the fixed tree; the APK has to stay up past
60 s with the launcher label visible and `chrome://version` reachable. If the
GPU process still refuses to start, the next lever is `--disable-gpu` plus
software compositing, not another sandbox tweak.

This analysis was only half right: dropping the in-process switch did bring the
GPU process up, but it still died. See the next entry.

## 2026-11-22 — resolved: the ES 3.0 context is refused on this driver

`b36`, carrying `0010-allow-es-version-fallback`, stays up on the test phone
(`citrus_id`, Android 12, Adreno 610 / Vulkan 1.1.128). The line that decides
it all sits in `gpu/config/gpu_info_collector.cc`:

```cpp
- attribs.allow_es_version_fallback = false;
+ attribs.allow_es_version_fallback = true;
```

ANGLE runs its Vulkan backend here and answers `Requested version is not
supported` / `EGL_BAD_ATTRIBUTE` for the ES 3.0 context the GPU info collection
asks for. With the fallback disabled that single refusal ends in
`IntentionallyCrashBrowserForUnusableGpuProcess()`; with it enabled the context
falls back to ES 2.0 and the GPU process survives.

Measured on the phone after installing `b36`:

- browser process, `:privileged_process0` (GPU) and three renderers alive past
  45 s;
- `logcat -b crash` empty;
- `mCurrentFocus` is the browser window, the UI renders.

What did not work, and why: `--in-process-gpu` moved the failure into
`gpu_init.cc`; disabling the Vulkan feature made GL selection return
`(gl=none,angle=none)`; `--use-gl` / `--use-angle` values are not accepted for
the ANGLE pair in this build; `--disable-gpu` crashed somewhere else. None of
those could fix it, because the decision happens on a hard-coded attribute
inside GPU init, not on the command line.

The phone also demonstrated that the separate GPU process does start here —
`io.dioide.aerium` (Chromium 155) runs a working `:privileged_process0` — so the
problem was never the device, the sandbox, or the process model.

## 2026-11-22 — extensions in the phone toolbar

`b38` onwards hosts the extensions UI in the phone toolbar. Three things were
missing, all in the layout/plumbing rather than in the extension code:

- `toolbar_phone.xml` had no `extensions_toolbar_container_stub`, so
  `ToolbarManager` never created a coordinator and `assumeNonNull()` on the
  result crashed the browser with an NPE when the menu item was tapped
  (`0011`, `0012`);
- `ToolbarManager` cast the toolbar to `ToolbarTablet` when creating the
  coordinator, which cannot work on a phone (`0013`);
- an action popup could only anchor to a pinned action's button, so an unpinned
  extension did nothing when tapped in the menu (`0014` anchors the popup to the
  extensions menu button instead).

Newly installed extensions are no longer pinned automatically:
`--disable-features=ExtensionsPinnedByDefault` in `0009`, matching the
`ToolbarActionsModel` check that pins on install.

Verified on the device with `b40`: uBlock Origin Lite unpinned still opens its
popup from the extensions menu, a freshly installed Dark Reader stays out of the
toolbar, and launching the browser no longer writes anything to `Download/`
(the diagnostics patches are gone from the series).


