# Install and update

## First install

1. Download `browser-<chromium version>-b<build>-arm64-v8a.apk` from the latest
   [release](https://github.com/kkhdwn/browser/releases/latest).
2. Open it on the phone and allow "install unknown apps" for the app that opens
   it (Files, Chrome, or your file manager).
3. Play Protect may warn that the app is unknown. The APK is signed with the
   project's own key; the SHA-256 is published next to the APK.

Requirements: Android 10 (API 29) or newer, `arm64-v8a`. The `x86_64` build is
for emulators and Chromebooks only.

## Updates

The package name (`com.kkhdwn.browser`) and the signing key never change, so a
newer APK installs over the old one and keeps all data.

Two ways to update:

- **Obtainium** (recommended today): add
  `https://github.com/kkhdwn/browser` as an app source. Obtainium checks the
  GitHub releases and installs new versions.
- **Manual**: download the newest APK from Releases and install it.

Android always asks for confirmation before installing an update; no app can
install silently without the install permission being granted to it.

## Verifying a download

```bash
sha256sum -c SHA256SUMS.txt
apksigner verify --print-certs browser-*.apk
```

The certificate digest must stay the same between releases. If it changes, do
not install: the APK was not built by this repository.
