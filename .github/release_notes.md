## Downloads

These packages are built from this independent FlClash-FreeCat repository. Choose the architecture for your device:

| Platform | Architectures | Files |
| --- | --- | --- |
| Android | arm64-v8a, armeabi-v7a, x86_64 | APK |
| Windows | amd64, arm64 | Setup EXE and portable ZIP |
| Linux | amd64, arm64 | DEB, RPM, AppImage and complete bundle TAR.GZ |
| macOS | Intel amd64, Apple Silicon arm64 | DMG |

Check downloads against `SHA256SUMS` with `sha256sum -c SHA256SUMS` after downloading the corresponding files. The checksum list covers all release assets except itself.

The Linux bundle archive extracts directly to `FlClash`, `FlClashCore`, `FlClashHelperService`, `manifest.json`, `lib/` and `data/`. Keep the complete bundle together. The Core and Helper must retain their original bytes because the Helper verifies the Core SHA256. Linux secret storage requires libsecret and an unlocked Secret Service keyring, such as GNOME Keyring or a compatible provider. TUN authorization also needs the appropriate system service and elevation support.

Stable releases include `flclash-freecat-bin-<version>.tar.gz`, containing the AUR source package and exact checksums for both Linux architectures. This artifact prepares an AUR submission; the workflow does not publish to AUR. Prereleases omit the AUR source package.

Windows and macOS packages are not code-signed or notarized by this workflow. Android signing details for this run appear below and in `ANDROID-SIGNING.txt`; APKs built without the complete release-signing secrets use a temporary debug key and the separate `com.follow.clash.dev` application ID.

## Release and site maintenance

Branch pushes and manual runs build downloadable Actions artifacts without requiring a release tag or signing secrets. Publishing requires a `v<version>` tag that exactly matches the version in `pubspec.yaml`, excluding its `+build` suffix, and successful checks plus every platform package. A prerelease tag must have the same prerelease suffix in `pubspec.yaml`.

GitHub Pages is disabled unless the repository variable `ENABLE_PAGES` is exactly `true`. Before enabling it, audit `site/` for inherited upstream download URLs, branding and claims, and configure the repository's Pages source as GitHub Actions. The Pages workflow supplies this repository as `SITE_REPOSITORY` and its Pages address as `SITE_URL`; inherited hardcoded site content still needs review.
