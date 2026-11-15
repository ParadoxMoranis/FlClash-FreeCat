import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('release_aur', ROOT / 'tool' / 'release_aur.py')
release_aur = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release_aur)


class ReleaseAurTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.dist = self.root / 'release files'
        self.dist.mkdir()
        self.output = self.dist / 'aur'
        self.core = b'core bytes pinned into the helper'
        self.bundle_files = {name: name.encode() for name in release_aur.REQUIRED_FILES}
        self.bundle_files['FlClashCore'] = self.core
        self.bundle_files['manifest.json'] = json.dumps({
            'coreSha256': hashlib.sha256(self.core).hexdigest(),
        }).encode()
        self.bundle_files['lib/libtray_plugin.so'] = b'plugin with build-time RPATH'
        self.bundle_files['data/flutter_assets/extra.asset'] = b'preserve the full bundle'
        self.archives = {arch: self.write_bundle(arch) for arch in ('amd64', 'arm64')}

    def write_bundle(self, arch, files=None, extra=()):
        path = self.dist / f'FlClash-0.9.4-linux-{arch}.tar.gz'
        files = self.bundle_files if files is None else files
        with tarfile.open(path, 'w:gz') as archive:
            root = tarfile.TarInfo('.')
            root.type = tarfile.DIRTYPE
            root.mode = 0o755
            archive.addfile(root)
            for name, data in files.items():
                member = tarfile.TarInfo(f'./{name}')
                member.mode = 0o755 if name.startswith('FlClash') else 0o644
                member.size = len(data)
                archive.addfile(member, io.BytesIO(data))
            for member, data in extra:
                archive.addfile(member, io.BytesIO(data) if data is not None else None)
        return path

    def generate(self, repository='ParadoxMoranis/FlClash-FreeCat', tag='v0.9.4'):
        return release_aur.generate(repository, tag, self.dist, self.output)

    def assert_no_outputs(self):
        self.assertFalse(self.output.exists())
        self.assertFalse((self.dist / 'flclash-freecat-bin-0.9.4.tar.gz').exists())
        self.assertFalse(any(path.name.startswith('.aur-') for path in self.dist.iterdir()))

    def bash_values(self, pkgbuild, variable):
        script = 'source "$1"; declare -n a="$2"; printf "%s\n" "${a[@]}"'
        result = subprocess.run(
            ['bash', '-c', script, '_', str(pkgbuild), variable],
            check=True, capture_output=True, text=True,
        )
        return result.stdout.splitlines()

    @staticmethod
    def parse_srcinfo(text):
        values = {}
        for line in text.splitlines():
            if line.strip():
                key, value = line.strip().split(' = ', 1)
                values.setdefault(key, []).append(value)
        return values

    def test_generated_recipe_checksums_architecture_and_source_tar(self):
        inputs = {arch: hashlib.sha256(path.read_bytes()).hexdigest() for arch, path in self.archives.items()}
        package_dir, source_tar = self.generate()
        self.assertEqual(package_dir, self.output / 'flclash-freecat-bin')
        self.assertEqual(source_tar, self.dist / 'flclash-freecat-bin-0.9.4.tar.gz')
        pkgbuild = package_dir / 'PKGBUILD'
        expected = {
            'pkgname': ['flclash-freecat-bin'], 'pkgver': ['0.9.4'],
            'arch': ['x86_64', 'aarch64'], 'provides': ['flclash=0.9.4'],
            'conflicts': ['flclash', 'flclash-bin', 'flclash-freecat', 'flclash-git'],
            'options': ['!strip', '!debug'], 'makedepends': ['patchelf'],
        }
        for variable, values in expected.items():
            self.assertEqual(self.bash_values(pkgbuild, variable), values)
        for dependency in ('gtk3', 'libsecret', 'libayatana-appindicator', 'libx11', 'libepoxy'):
            self.assertIn(dependency, self.bash_values(pkgbuild, 'depends'))
        for arch, release_arch in release_aur.ARCHITECTURES.items():
            self.assertEqual(self.bash_values(pkgbuild, f'source_{arch}'), [
                f'https://github.com/ParadoxMoranis/FlClash-FreeCat/releases/download/v0.9.4/FlClash-0.9.4-linux-{release_arch}.tar.gz',
            ])
            self.assertEqual(self.bash_values(pkgbuild, f'sha256sums_{arch}'), [inputs[release_arch]])
        local_sources = self.bash_values(pkgbuild, 'source')
        self.assertEqual(local_sources, ['flclash.desktop', 'flclash-freecat.install'])
        self.assertEqual(self.bash_values(pkgbuild, 'sha256sums'), [
            hashlib.sha256((package_dir / name).read_bytes()).hexdigest() for name in local_sources
        ])
        for variable, values in self.parse_srcinfo((package_dir / '.SRCINFO').read_text()).items():
            if variable != 'pkgbase':
                self.assertEqual(self.bash_values(pkgbuild, variable), values, variable)
        self.assertNotIn('SKIP', pkgbuild.read_text())
        self.assertNotIn('@VERSION@', pkgbuild.read_text())
        for arch, path in self.archives.items():
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), inputs[arch])
        with tarfile.open(source_tar, 'r:gz') as archive:
            self.assertEqual(set(archive.getnames()), {
                'flclash-freecat-bin',
                *(f'flclash-freecat-bin/{name}' for name in release_aur.SOURCE_FILES),
            })
            for name in release_aur.SOURCE_FILES:
                with archive.extractfile(f'flclash-freecat-bin/{name}') as content:
                    self.assertEqual(content.read(), (package_dir / name).read_bytes())

    def test_cli_prints_generated_paths_and_uses_selected_repository(self):
        stream = io.StringIO()
        with contextlib.redirect_stdout(stream):
            status = release_aur.main([
                '--repository', 'example/current-fork', '--tag', 'v0.9.4',
                '--dist', str(self.dist), '--output', str(self.output),
            ])
        self.assertEqual(status, 0)
        self.assertIn(str(self.output / 'flclash-freecat-bin'), stream.getvalue())
        self.assertIn('https://github.com/example/current-fork', (self.output / 'flclash-freecat-bin' / 'PKGBUILD').read_text())

    def test_missing_and_empty_archives_fail_without_outputs(self):
        for arch in ('amd64', 'arm64'):
            with self.subTest(arch=arch, issue='missing'):
                self.archives[arch].unlink()
                with self.assertRaisesRegex(ValueError, 'Missing or empty release archive'):
                    self.generate()
                self.assert_no_outputs()
            with self.subTest(arch=arch, issue='empty'):
                self.archives[arch].touch()
                with self.assertRaisesRegex(ValueError, 'Missing or empty release archive'):
                    self.generate()
                self.assert_no_outputs()
            self.write_bundle(arch)

    def test_rejects_invalid_tag_and_repository(self):
        for tag in ('0.9.4', 'v0.9', 'v01.9.4', 'v0.9.4-pre.1', 'v0.9.4+1', 'v0.9.4\n', 'v0.9.4;touch pwned'):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                self.generate(tag=tag)
        for repository in ('owner', 'owner/repo/extra', 'owner/repo;id', 'owner/$(id)', 'owner/repo\n', '-owner/repo', 'owner/..', 'owner/repo?x=1'):
            with self.subTest(repository=repository), self.assertRaises(ValueError):
                self.generate(repository=repository)
        self.assert_no_outputs()

    def test_requires_nonempty_regular_bundle_files(self):
        for name in release_aur.REQUIRED_FILES:
            for empty in (False, True):
                with self.subTest(name=name, empty=empty):
                    files = dict(self.bundle_files)
                    if empty:
                        files[name] = b''
                    else:
                        del files[name]
                    self.write_bundle('amd64', files)
                    with self.assertRaises(ValueError):
                        self.generate()
                    self.assert_no_outputs()

    def test_rejects_core_hash_mismatch_and_invalid_manifests(self):
        for manifest in (b'not json', b'[]', b'{}', b'{"coreSha256":42}', b'{"coreSha256":"bad"}', json.dumps({'coreSha256': '0' * 64}).encode()):
            with self.subTest(manifest=manifest):
                self.write_bundle('arm64', {**self.bundle_files, 'manifest.json': manifest})
                with self.assertRaisesRegex(ValueError, 'manifest|coreSha256|SHA256 mismatch'):
                    self.generate()
                self.assert_no_outputs()

    def test_rejects_archive_escape_special_files_and_duplicates(self):
        cases = []
        for name in ('../escape', '/tmp/escape', 'lib/../../escape', 'lib\\escape'):
            member = tarfile.TarInfo(name)
            member.size = 1
            cases.append((member, b'x'))
        for target in ('/tmp', '../../tmp', '../FlClashCore'):
            member = tarfile.TarInfo('lib/link')
            member.type = tarfile.SYMTYPE
            member.linkname = target
            cases.append((member, None))
        member = tarfile.TarInfo('special')
        member.type = tarfile.FIFOTYPE
        cases.append((member, None))
        member = tarfile.TarInfo('FlClashCore')
        member.size = 1
        cases.append((member, b'x'))
        member = tarfile.TarInfo('setuid')
        member.size = 1
        member.mode = 0o4755
        cases.append((member, b'x'))
        for member, data in cases:
            with self.subTest(name=member.name, target=member.linkname):
                self.write_bundle('amd64', extra=((member, data),))
                with self.assertRaises(ValueError):
                    self.generate()
                self.assert_no_outputs()

    def test_rejects_links_used_as_directory_ancestors(self):
        member = tarfile.TarInfo('lib')
        member.type = tarfile.SYMTYPE
        member.linkname = 'data'
        self.write_bundle('amd64', extra=((member, None),))
        with self.assertRaisesRegex(ValueError, 'non-directory'):
            self.generate()
        self.assert_no_outputs()

    def test_checks_without_extracting_and_accepts_internal_symlink(self):
        link = tarfile.TarInfo('lib/libalias.so')
        link.type = tarfile.SYMTYPE
        link.linkname = 'libapp.so'
        self.write_bundle('amd64', extra=((link, None),))
        with mock.patch.object(tarfile.TarFile, 'extract', side_effect=AssertionError('must not extract')), mock.patch.object(tarfile.TarFile, 'extractall', side_effect=AssertionError('must not extract')):
            self.generate()

    def test_rejects_truncated_gzip(self):
        path = self.archives['arm64']
        path.write_bytes(path.read_bytes()[:-5])
        with self.assertRaises(ValueError):
            self.generate()
        self.assert_no_outputs()

    def test_rejects_non_tar_gzip_and_hardlinks(self):
        self.archives['amd64'].write_bytes(b'not a gzip archive')
        with self.assertRaises(ValueError):
            self.generate()
        self.assert_no_outputs()
        link = tarfile.TarInfo('lib/core-alias')
        link.type = tarfile.LNKTYPE
        link.linkname = 'FlClashCore'
        self.write_bundle('amd64', extra=((link, None),))
        with self.assertRaisesRegex(ValueError, 'Unsupported archive member'):
            self.generate()
        self.assert_no_outputs()

    def test_does_not_overwrite_existing_outputs(self):
        self.output.mkdir()
        sentinel = self.output / 'keep'
        sentinel.write_bytes(b'keep')
        with self.assertRaises(ValueError):
            self.generate()
        self.assertEqual(sentinel.read_bytes(), b'keep')

    def test_existing_source_tar_and_symlink_outputs_are_preserved(self):
        source_tar = self.dist / 'flclash-freecat-bin-0.9.4.tar.gz'
        source_tar.write_bytes(b'existing source package')
        with self.assertRaises(ValueError):
            self.generate()
        self.assertEqual(source_tar.read_bytes(), b'existing source package')
        source_tar.unlink()
        self.output.symlink_to(self.root / 'missing-output')
        with self.assertRaises(ValueError):
            self.generate()
        self.assertTrue(self.output.is_symlink())

    def test_output_cannot_be_source_tar_or_below_it(self):
        source_tar = self.dist / 'flclash-freecat-bin-0.9.4.tar.gz'
        for output in (source_tar, source_tar / 'nested'):
            with self.subTest(output=output), self.assertRaises(ValueError):
                release_aur.generate('owner/repo', 'v0.9.4', self.dist, output)
        self.assert_no_outputs()

    def test_rejects_output_containing_dist(self):
        for output in (self.dist, self.root):
            with self.subTest(output=output), self.assertRaises(ValueError):
                release_aur.generate('owner/repo', 'v0.9.4', self.dist, output)
        self.assert_no_outputs()

    def test_rolls_back_if_source_tar_cannot_be_published(self):
        rename = Path.rename

        def fail_source(path, target):
            if path.name == 'flclash-freecat-bin-0.9.4.tar.gz':
                raise OSError('injected publish failure')
            return rename(path, target)

        with mock.patch.object(Path, 'rename', fail_source):
            with self.assertRaisesRegex(OSError, 'injected publish failure'):
                self.generate()
        self.assert_no_outputs()

    def test_source_tar_is_reproducible_and_excludes_release_archives(self):
        _, source_tar = self.generate()
        data = source_tar.read_bytes()
        shutil.rmtree(self.output)
        source_tar.unlink()
        _, source_tar = self.generate()
        self.assertEqual(source_tar.read_bytes(), data)

    @unittest.skipUnless(shutil.which('bash') and shutil.which('bsdtar'), 'bash and bsdtar are required')
    def test_package_preserves_bundle_and_core_with_both_architectures(self):
        package_dir, _ = self.generate()
        bin_dir = self.root / 'fake-bin'
        bin_dir.mkdir()
        patchelf = bin_dir / 'patchelf'
        patchelf.write_text(
            '#!/bin/bash\n'
            '[[ "$1" == --set-rpath && "$2" == \'$ORIGIN\' && "$3" == *plugin.so ]] || exit 1\n'
            'printf patched >> "$3"\n',
        )
        patchelf.chmod(0o755)
        for arch in ('x86_64', 'aarch64'):
            with self.subTest(arch=arch):
                srcdir = self.root / f'src-{arch}'
                pkgdir = self.root / f'pkg-{arch}'
                srcdir.mkdir()
                for source in (*self.archives.values(), package_dir / 'flclash.desktop'):
                    shutil.copyfile(source, srcdir / source.name)
                script = 'source "$1"; srcdir="$2"; pkgdir="$3"; CARCH="$4"; package'
                subprocess.run(
                    ['bash', '-e', '-c', script, '_', str(package_dir / 'PKGBUILD'), str(srcdir), str(pkgdir), arch],
                    env={**os.environ, 'PATH': f'{bin_dir}:{os.environ["PATH"]}'},
                    check=True, capture_output=True,
                )
                bundle = pkgdir / 'usr/lib/flclash'
                for name, data in self.bundle_files.items():
                    expected = data + b'patched' if name.endswith('plugin.so') else data
                    self.assertEqual((bundle / name).read_bytes(), expected, name)
                self.assertEqual((pkgdir / 'usr/bin/flclash').readlink(), Path('/usr/lib/flclash/FlClash'))
                self.assertEqual((pkgdir / 'usr/share/icons/hicolor/256x256/apps/flclash.png').read_bytes(), self.bundle_files['data/flutter_assets/assets/images/icon.png'])
                self.assertEqual((pkgdir / 'usr/share/applications/flclash.desktop').read_bytes(), (package_dir / 'flclash.desktop').read_bytes())

    @unittest.skipUnless(shutil.which('bash'), 'bash is required')
    def test_shell_syntax_desktop_and_removal_hook(self):
        package_dir, _ = self.generate()
        for name in ('PKGBUILD', 'flclash-freecat.install'):
            subprocess.run(['bash', '-n', str(package_dir / name)], check=True, capture_output=True)
        hook = (package_dir / 'flclash-freecat.install').read_text()
        self.assertIn('post_remove()', hook)
        self.assertNotIn('post_upgrade', hook)
        self.assertNotIn('post_install', hook)
        self.assertNotIn('--user', hook)
        self.assertIn('ExecStart="/usr/lib/flclash/FlClashHelperService"', hook)
        desktop = (package_dir / 'flclash.desktop').read_text()
        self.assertIn('Exec=flclash %u', desktop)
        self.assertIn('x-scheme-handler/flclash;', desktop)
        if shutil.which('desktop-file-validate'):
            subprocess.run(['desktop-file-validate', str(package_dir / 'flclash.desktop')], check=True, capture_output=True)

    @unittest.skipUnless(shutil.which('makepkg'), 'Arch makepkg is required')
    def test_makepkg_metadata_matches_and_verifies_only_local_fake_sources(self):
        if os.geteuid() == 0:
            self.skipTest('makepkg must run as an unprivileged user')
        package_dir, _ = self.generate()
        result = subprocess.run(['makepkg', '--printsrcinfo'], cwd=package_dir, check=True, capture_output=True, text=True)
        self.assertEqual(self.parse_srcinfo(result.stdout), self.parse_srcinfo((package_dir / '.SRCINFO').read_text()))
        local_build = package_dir / 'PKGBUILD'
        text = local_build.read_text()
        for path in self.archives.values():
            text = text.replace(
                f'https://github.com/ParadoxMoranis/FlClash-FreeCat/releases/download/v0.9.4/{path.name}',
                path.name,
            )
            shutil.copyfile(path, package_dir / path.name)
        local_build.write_text(text)
        config = self.root / 'makepkg.conf'
        config.write_text(
            'source /etc/makepkg.conf\n'
            'DLAGENTS=()\n'
            'BUILDENV=(!distcc !color !ccache !check !sign)\n',
        )
        subprocess.run(
            ['makepkg', '--config', str(config), '--verifysource', '--nodeps'],
            cwd=package_dir, check=True, capture_output=True,
        )


if __name__ == '__main__':
    unittest.main()
