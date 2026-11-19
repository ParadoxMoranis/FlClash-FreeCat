## Unreleased

- Correct the first FreeCat panel hostname to `tccdnclient.miaowuppaa.com`, retaining the existing fallback order.
- FreeCat profiles now use `find-process-mode: always` in both generated configuration and live updates so subscription process rules can match. This source-specific behavior also takes precedence over a saved `off`; ordinary profiles retain their selected mode.
- Match only known placeholder prefixes at the start of node names, preserving real nodes whose names contain notice or website text.

## Changes in v0.9.7

- FreeCat subscription requests now use the observed official 3.2.0 subscription User-Agent. The same value supplies FreeCat's default `global-ua`, while an explicit `global-ua` is retained. The panel login/token flow and subscription decryption remain unchanged; the 3.2.0 findings do not establish a new panel User-Agent.
- Manual FreeCat delay tests default to `http://cp.cloudflare.com/generate_204` with a 5000 ms timeout when no timeout has been saved, matching the observed 3.2.0 IPC request. Explicit URLs and timeouts take precedence. Previously saved timeouts, including 8000 ms, are retained; select 5000 ms manually for a strict comparison. Ordinary subscriptions retain their 8000 ms default.
- Subscription group health-check URLs and intervals, DNS configuration, node addresses, ports, passwords, SNI and certificate-verification fields remain under the existing subscription and user override rules. Manual tests do not replace group health checks.
- FreeCat Trojan nodes using the default TCP transport retain the `chrome120` compatibility default when the subscription supplies no `client-fingerprint`. Existing FreeCat profiles receive it when loaded, without signing in again or refreshing. Explicit fingerprints and other transports and protocols remain as configured; ordinary subscriptions retain their existing behavior.
- This release includes the complete 3.2.0 adaptation prepared for v0.9.6. That tag produced platform artifacts but was not published because the full test gate identified an internal constant exposed as public; its visibility is now corrected.

The official 3.2.0 evidence does not establish which TLS ClientHello fingerprint the official client uses. `chrome120` is this fork's compatibility choice: controlled tests against four fixed node addresses returned successful HTTP probes for 11/12 `chrome120` attempts and 1/12 default attempts. Endpoint timeouts can still occur; an HTTP delay result does not prove HTTPS connectivity or full equivalence with the official client.


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

Windows packages have no publisher code signature. macOS uses ad-hoc signing without an Apple Developer certificate or notarization; system security approval may be required. Android signing details for this run appear below and in `ANDROID-SIGNING.txt`; APKs built without the complete release-signing secrets use a temporary debug key and the separate `com.follow.clash.dev` application ID. The debug key may change between builds, so an update may require uninstalling the previous APK and losing its local app data.

## Release and site maintenance

Branch pushes and manual runs on branches build downloadable Actions artifacts without requiring a release tag or signing secrets. Publishing requires running on a `v<version>` tag that exactly matches the version in `pubspec.yaml`, excluding its `+build` suffix, and successful checks plus every platform package. Push the tag to start publication; a manual run selected on an existing matching tag also enters the release job. A prerelease tag must have the same prerelease suffix in `pubspec.yaml`. Release uploads, generated AUR download links and the packaged client's update URLs use the current repository.

GitHub Pages is disabled unless the repository variable `ENABLE_PAGES` is exactly `true`. Before enabling it, audit `site/` for inherited upstream download URLs, branding and claims, and configure the repository's Pages source as GitHub Actions. The Pages workflow supplies this repository as `SITE_REPOSITORY` and its Pages address as `SITE_URL`; inherited hardcoded site content still needs review.
