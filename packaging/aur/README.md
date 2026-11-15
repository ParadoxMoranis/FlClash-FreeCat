# AUR binary release sources

Generate the package from the two Linux bundles already produced for a stable release:

```bash
python3 tool/release_aur.py \
  --repository ParadoxMoranis/FlClash-FreeCat \
  --tag v0.9.4 \
  --dist dist \
  --output dist/aur
```

Python 3.9 or newer and its standard library are sufficient. The output directory
and `dist/flclash-freecat-bin-0.9.4.tar.gz` must not already exist. The command
writes `dist/aur/flclash-freecat-bin/{PKGBUILD,.SRCINFO,flclash.desktop,flclash-freecat.install}`
and a source archive containing exactly those four files under
`flclash-freecat-bin/`. It neither downloads releases nor uploads to AUR.

Both `FlClash-0.9.4-linux-amd64.tar.gz` and
`FlClash-0.9.4-linux-arm64.tar.gz` must exist in `dist`. Each archive must have
`FlClash`, `FlClashCore`, `FlClashHelperService`, `manifest.json`, `lib/` and
`data/` directly at its root, as the release bundle does. Required nonempty files
include `lib/libapp.so`, `lib/librust_api.so`, `lib/libflutter_linux_gtk.so`,
`data/icudtl.dat` and `data/flutter_assets/assets/images/icon.png`. The generator
streams the archives without extracting them, checks the core against
`manifest.json`'s `coreSha256`, rejects unsafe archive members and paths, and hashes
the exact compressed release bytes. Only stable `vX.Y.Z` tags are accepted.

`PKGBUILD.in`, `flclash.desktop` and `flclash-freecat.install` are the maintained
sources. Local source checksums and `.SRCINFO` are generated alongside the
architecture-specific release URLs and checksums. `amd64` maps to Arch's `x86_64`;
`arm64` maps to `aarch64`. Do not edit a generated checksum to `SKIP`.

The binary package keeps the full bundle in `/usr/lib/flclash` and links
`/usr/bin/flclash` to its executable. `patchelf` repairs the bundled plugin
libraries' RPATHs during packaging. The core, helper and manifest remain
byte-identical, and `!strip` and `!debug` prevent makepkg from altering the
integrity-bound binaries. The recipe does not install or start a helper service;
the app requests authorization when the user enables TUN. Only complete package
removal cleans up a helper unit whose executable matches this installed bundle.
Upgrades do not stop services.

FreeCat account storage needs a running Secret Service provider. GNOME users
normally use GNOME Keyring; KDE users can enable KWallet's Secret Service support.
These are optional package dependencies, as is a polkit agent for graphical TUN
authorization. The package does not change a user's keyring or desktop settings.

On Arch, metadata and local syntax can be checked in the generated directory:

```bash
makepkg --printsrcinfo > .SRCINFO
bash -n PKGBUILD flclash-freecat.install
desktop-file-validate flclash.desktop
```

Offline unit coverage creates synthetic bundles and checks the CLI, validation,
checksums, metadata, architecture mapping and cleanup on failure. When makepkg is
available to an unprivileged test user, it also compares `--printsrcinfo` and runs
`--verifysource` against local synthetic archives with network download agents
disabled:

```bash
python3 -m unittest discover -s test/tool -p release_aur_test.py
```
