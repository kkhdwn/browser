# Patches

Each `.patch` file is applied on top of the pinned Chromium checkout by
`../apply.sh`, in filename order. Nothing here is a fork: the tree is fetched
from `chromium.googlesource.com` at build time and patched in place.

Rules:

- One feature per patch, numbered `NNNN-short-name.patch`.
- Generate with `git format-patch` or `git diff >`-style output from a real
  checkout, never hand-edited hunks.
- Keep patches small and rebasable. Every Chromium stable bump (every 2-4
  weeks) requires the series to apply cleanly; `upstream-watch` opens an issue
  when it does not.
- No code copied from other browsers. Aerium (GPL-3.0) is used only as an
  architectural reference; our patches are written from scratch so this
  repository stays BSD-3-Clause.

Current series:

1. `0001-brand-the-launcher-label` — launcher label is "Browser" instead of
   the Chromium resource.
2. `0002-allow-user-downloaded-crx` — a `.crx` the user downloaded (GitHub
   releases, vendor site) can be installed; the permission prompt still has to
   be accepted.
3. `0003-omnibox-without-vector-icons` — omnibox built without the desktop
   vector icon resources.
4. `0004-searchbox-without-vector-icons` — same for the searchbox.
5. `0005-startup-diagnostics` — breadcrumbs, Java stack traces and native
   stderr are written to `Download/browser-*.{txt,log}`.
6. `0006-register-diagnostics` — adds `BrowserDiagnostics` to
   `java_sources.gni`.
7. `0007-hook-diagnostics` — installs the handler in
   `ChromeApplicationImpl.onCreate`.
8. `0008-disable-android-gpu-sandbox-feature` — the experimental Android GPU
   sandbox is not force-enabled; on some Android 12 devices it keeps the GPU
   process from starting, which Chromium treats as fatal.
9. `0009-apply-switches-before-feature-list` — GPU switches are appended right
   after `CommandLineInitUtil.initCommandLine`, before the feature list is
   created. Appending them in `onCreate` is too late.

Planned:

10. Unpacked extension import from a `.zip` into app storage.
11. Phone layout fixes for the desktop-android surfaces.
12. Icon/branding pass and in-app updater against GitHub Releases.
