<div align="center">

<img src="assets/images/icon.png" alt="FlClash" width="88">

# FlClash-FreeCat

A community fork of [FlClash](https://github.com/chen08209/FlClash) with optional FreeCat subscriptions.
Standard subscription links, local profiles, routing and TUN retain their FlClash behavior. This project is not
affiliated with FreeCat or the upstream FlClash maintainers.

**English** · [简体中文](README_zh_CN.md)

[![Build](https://github.com/ParadoxMoranis/FlClash-FreeCat/actions/workflows/build.yaml/badge.svg)](https://github.com/ParadoxMoranis/FlClash-FreeCat/actions/workflows/build.yaml)
[![Release](https://img.shields.io/github/v/release/ParadoxMoranis/FlClash-FreeCat)](https://github.com/ParadoxMoranis/FlClash-FreeCat/releases)
[![License](https://img.shields.io/github/license/ParadoxMoranis/FlClash-FreeCat)](LICENSE)

[Download](#download) · [Release and AUR guide](RELEASING.md) · [Build from source](#build-from-source)

</div>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="snapshots/preview-dark.png">
    <img alt="FlClash dashboard on a MacBook and a phone" src="snapshots/preview.png" width="92%">
  </picture>
</p>

## Features

- **One app for Android, Windows, macOS and Linux**, with x64 and ARM64 builds on the desktop.
- **mihomo (Clash.Meta) core** with rule routing, proxy groups, latency tests, system proxy and TUN mode.
- **Profiles** from a subscription link or a file, with a built-in editor, override scripts, and custom rules,
  proxies and proxy groups.
- **Live views** of connections, requests, DNS queries and logs.
- **Material You design with Apple-style interaction**: dynamic color, light and dark themes, continuous corners,
  sheets that snap between heights, and layouts that adapt from phones to desktops.
- **Backup and restore** through WebDAV or a local file.
- **Platform touches**: a Quick Settings tile, per-app proxy and Android TV support on Android; a tray menu and
  global hotkeys on the desktop.
- **Open source and ad-free**, licensed under GPL-3.0.

## Download

Download this fork from [GitHub Releases](https://github.com/ParadoxMoranis/FlClash-FreeCat/releases).
Every branch push also uploads test packages under the corresponding [Actions run](https://github.com/ParadoxMoranis/FlClash-FreeCat/actions/workflows/build.yaml).

| Platform | Packages | Notes |
| --- | --- | --- |
| Android | APK for `arm64-v8a`, `armeabi-v7a` and `x86_64` | Most phones use `arm64-v8a`. Keep the same signing key for updates. |
| Windows 10 and later | Installer (`.exe`) or portable `.zip`, for x64 and ARM64 | Pick ARM64 on Snapdragon and other ARM laptops. |
| macOS 12 and later | DMG for Apple Silicon and Intel | Unsigned builds may require approval in Privacy & Security. |
| Linux | `.deb`, `.rpm`, AppImage and `.tar.gz`, for x64 and ARM64 | Stable releases also include a checksum-pinned AUR source package. |


**Linux tray icon**

The `.deb` package installs its own dependencies. With the AppImage or the `.rpm`, install the AyatanaAppIndicator
library so the tray icon can show:

```bash
sudo apt-get install libayatana-appindicator3-1   # Debian and Ubuntu
sudo dnf install libayatana-appindicator-gtk3     # Fedora
```

**Unattended desktop**

FlClash starts the core only after the disclaimer is accepted. Where nobody can click it, such as a container, set
`FLCLASH_ACCEPT_DISCLAIMER=1` in the app's environment to accept it on first launch.

## Usage

**Import a profile from a link.** Opening a link in this form imports the subscription into FlClash. The `clashmeta://`
and `flclash://` schemes work the same way.

```text
clash://install-config?url=<URL-encoded subscription link>
```

**FreeCat subscriptions (optional).** Choose **Profiles → Add → FreeCat**, then sign in with your own email and
password. Leave Host empty to try the built-in panel hosts, or supply your own HTTPS panel. The password is used
only for that login; the token and subscription address stay in the operating system's secure storage. Ordinary
link and file imports keep their existing behavior.

Use the existing refresh and automatic update controls. To sign in again or switch accounts, open the profile's
context menu and choose **FreeCat**; it updates that profile while retaining your selections. Restoring a backup on
another device requires signing in again. Exported profile YAML still contains node credentials. On Linux, unlock
a Secret Service keyring such as GNOME Keyring or KWallet before signing in.

FreeCat manual delay tests default to the official `http://cp.cloudflare.com/generate_204` endpoint. A user-selected
test URL and timeout take precedence. Automatic group health checks keep the subscription's URLs and intervals.
An HTTP delay result does not establish HTTPS connectivity; see [probe findings](FREECAT_PROBE_FINDINGS.md).

**Automate on Android.** Tasker, MacroDroid and similar apps can start, stop or toggle the proxy by starting an
activity with one of these actions:

```text
com.follow.clash.action.START
com.follow.clash.action.STOP
com.follow.clash.action.TOGGLE
```

From a computer, the same works over adb:

```bash
adb shell am start -a com.follow.clash.action.TOGGLE
```

## Build from source

You need [Flutter](https://docs.flutter.dev/get-started/install) 3.47 (release builds use 3.47.6),
[Go](https://go.dev/dl/) 1.27 and [Rust](https://rustup.rs/) installed through rustup. Each platform builds on its own
host, except Android, which builds anywhere.

```bash
git clone --recursive https://github.com/ParadoxMoranis/FlClash-FreeCat.git
cd FlClash-FreeCat
flutter pub get
dart setup.dart android   # or windows, macos, linux
```

Packages land in `dist/`. The Go core and the Rust libraries are compiled as part of the Flutter build.

| Platform | Also needed |
| --- | --- |
| Android | Android SDK with the NDK. Add `--arch arm64` to build a single ABI. |
| Windows | GCC (MinGW-w64) for the core and [Inno Setup](https://jrsoftware.org/isinfo.php) 6 for the installer. |
| macOS | Xcode and Node.js. The script installs `appdmg` through npm. |
| Linux | Debian or Ubuntu. The script installs the build packages with apt and downloads `appimagetool`. |

Run `dart setup.dart --help` for the remaining options, such as `--targets` to build only some package formats.

## Support

Report issues for this fork in [GitHub Issues](https://github.com/ParadoxMoranis/FlClash-FreeCat/issues).
Never include a password, token, subscription address or complete node configuration in a report.

## License

FlClash-FreeCat is released under the [GPL-3.0 license](LICENSE). The FlClash code and bundled third-party
components retain their original copyright and license notices. See [UPSTREAM.md](UPSTREAM.md) for provenance.
