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

Planned:

3. Unpacked extension import from a `.zip` into app storage.
4. Phone layout fixes for the desktop-android surfaces.
5. Icon/branding pass and in-app updater against GitHub Releases.
