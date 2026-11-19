# Build log

Chronological notes on what broke and how it was fixed. Every fix must land as
a commit so the next build picks it up.

## 2026-11-19 — initial pipeline

- Baseline: Chromium `158.0.8127.43` (Android stable, previous of `159.0.8154.18`).
- Confirmed upstream: `enable_desktop_android_extensions = is_desktop_android`
  in `extensions/buildflags/buildflags.gni`, and Chromium 158 already ships
  `chrome/browser/ui/android/toolbar/.../extensions/` plus
  `chrome/browser/ui/android/extensions/` (action popups, install dialog).
  Therefore no extension porting patches are needed for a first APK.
- Args start without LTO/PGO/siso on purpose: 4 vCPU runners, 16 GB RAM.
- First run: pending.
