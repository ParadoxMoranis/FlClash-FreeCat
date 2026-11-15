#!/usr/bin/env python3
"""Generate an AUR source package from two verified Linux release bundles."""

import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import posixpath
import re
import shlex
import shutil
import tarfile
import tempfile
import zlib


PKGNAME = 'flclash-freecat-bin'
ARCHITECTURES = {'x86_64': 'amd64', 'aarch64': 'arm64'}
TEMPLATES = Path(__file__).resolve().parents[1] / 'packaging' / 'aur'
SOURCE_FILES = ('PKGBUILD', '.SRCINFO', 'flclash.desktop', 'flclash-freecat.install')
REQUIRED_FILES = (
    'FlClash',
    'FlClashCore',
    'FlClashHelperService',
    'manifest.json',
    'lib/libapp.so',
    'lib/librust_api.so',
    'lib/libflutter_linux_gtk.so',
    'data/icudtl.dat',
    'data/flutter_assets/assets/images/icon.png',
)
TAG_PATTERN = re.compile(r'v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', re.ASCII)
REPOSITORY_PATTERN = re.compile(
    r'[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?/[A-Za-z0-9_.-]{1,100}',
    re.ASCII,
)


def sha256(stream):
    digest = hashlib.sha256()
    for chunk in iter(lambda: stream.read(1024 * 1024), b''):
        digest.update(chunk)
    return digest.hexdigest()


def member_path(name):
    if (not name or name.startswith('/') or '\\' in name
            or any(ord(character) < 32 or ord(character) == 127 for character in name)
            or '..' in PurePosixPath(name).parts):
        raise ValueError(f'Unsafe archive path: {name!r}')
    return str(PurePosixPath(name))


def link_target(member, name):
    target = member.linkname
    if (not target or target.startswith('/') or '\\' in target
            or '..' in PurePosixPath(target).parts
            or any(ord(character) < 32 or ord(character) == 127 for character in target)):
        raise ValueError(f'Unsafe archive link: {name!r} -> {target!r}')
    if member.issym():
        target = posixpath.join(posixpath.dirname(name), target)
    target = posixpath.normpath(target)
    if target == '..' or target.startswith('../'):
        raise ValueError(f'Archive link escapes bundle: {name!r}')
    return member_path(target)


def validate_bundle(path):
    if not path.is_file() or path.stat().st_size == 0:
        raise ValueError(f'Missing or empty release archive: {path}')
    members = {}
    core_digest = None
    manifest = None
    with path.open('rb') as raw:
        before = os.fstat(raw.fileno())
        archive_digest = sha256(raw)
        raw.seek(0)
        with gzip.GzipFile(fileobj=raw) as compressed:
            with tarfile.open(fileobj=compressed, mode='r|') as archive:
                for member in archive:
                    name = member_path(member.name)
                    if name == '.':
                        if not member.isdir():
                            raise ValueError(f'Archive root is not a directory: {path}')
                        continue
                    if name in members:
                        raise ValueError(f'Duplicate archive path: {name}')
                    if not (member.isfile() or member.isdir() or member.issym()):
                        raise ValueError(f'Unsupported archive member: {name}')
                    if member.mode & 0o7000:
                        raise ValueError(f'Unsafe special permission bits: {name}')
                    members[name] = member
                    if member.issym():
                        link_target(member, name)
                    if name in ('FlClashCore', 'manifest.json') and member.isfile():
                        with archive.extractfile(member) as content:
                            if name == 'FlClashCore':
                                core_digest = sha256(content)
                            else:
                                if member.size > 1024 * 1024:
                                    raise ValueError(f'Core manifest is too large: {path}')
                                try:
                                    manifest = json.load(content)
                                except (ValueError, UnicodeError) as error:
                                    raise ValueError(f'Invalid core manifest in {path}') from error
            # Read through the gzip trailer, including its CRC, without extracting files.
            while compressed.read(1024 * 1024):
                pass
        after = os.fstat(raw.fileno())
        if (before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (
                after.st_size, after.st_mtime_ns, after.st_ctime_ns):
            raise ValueError(f'Release archive changed while reading: {path}')
    for name, member in members.items():
        for ancestor in PurePosixPath(name).parents:
            parent = members.get(str(ancestor))
            if parent is not None and not parent.isdir():
                raise ValueError(f'Archive path traverses a non-directory: {name}')
    for name in REQUIRED_FILES:
        member = members.get(name)
        if member is None or not member.isfile() or member.size == 0:
            raise ValueError(f'Missing or empty regular bundle file {name!r} in {path}')
    expected = manifest.get('coreSha256') if isinstance(manifest, dict) else None
    if not isinstance(expected, str) or not re.fullmatch(r'[0-9a-f]{64}', expected):
        raise ValueError(f'Invalid coreSha256 in {path}')
    if expected != core_digest:
        raise ValueError(f'Core SHA256 mismatch in {path}')
    return archive_digest


def render_srcinfo(pkgbuild):
    scalars = ('pkgdesc', 'pkgver', 'pkgrel', 'url', 'install')
    arrays = (
        'arch', 'license', 'makedepends', 'depends', 'optdepends', 'provides',
        'conflicts', 'noextract', 'options', 'source', 'sha256sums',
        'source_x86_64', 'sha256sums_x86_64', 'source_aarch64', 'sha256sums_aarch64',
    )
    assignments = dict(re.findall(
        r'^([a-zA-Z0-9_]+)=(\([^)]*\)|[^\n]*)$', pkgbuild.split('\npackage() {', 1)[0], re.MULTILINE,
    ))
    if assignments.get('pkgname') != PKGNAME or set(assignments) != {'pkgname', *scalars, *arrays}:
        raise ValueError('PKGBUILD template metadata no longer matches the .SRCINFO renderer')
    lines = [f'pkgbase = {PKGNAME}']
    for key in (*scalars, *arrays):
        value = assignments[key]
        values = shlex.split(value[1:-1] if key in arrays else value)
        if not values or (key in scalars and len(values) != 1):
            raise ValueError(f'Invalid template metadata: {key}')
        lines.extend(f'\t{key} = {item}' for item in values)
    return '\n'.join([*lines, '', f'pkgname = {PKGNAME}', ''])


def source_package(path, files):
    with path.open('wb') as raw:
        with gzip.GzipFile(filename='', fileobj=raw, mode='wb', mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode='w', format=tarfile.USTAR_FORMAT) as archive:
                directory = tarfile.TarInfo(PKGNAME)
                directory.type = tarfile.DIRTYPE
                directory.mode = 0o755
                archive.addfile(directory)
                for name in SOURCE_FILES:
                    data = files[name]
                    member = tarfile.TarInfo(f'{PKGNAME}/{name}')
                    member.mode = 0o644
                    member.size = len(data)
                    archive.addfile(member, io.BytesIO(data))


def generate(repository, tag, dist, output):
    if (not REPOSITORY_PATTERN.fullmatch(repository) or '--' in repository.split('/')[0]
            or repository.split('/')[-1] in ('.', '..')):
        raise ValueError('Repository must be a GitHub OWNER/REPO using letters, digits, dots, hyphens or underscores')
    if not TAG_PATTERN.fullmatch(tag):
        raise ValueError('AUR releases require a stable tag vX.Y.Z without leading zeroes or suffixes')
    version = tag[1:]
    dist = Path(dist).resolve()
    output = Path(output).absolute()
    if output.is_symlink():
        raise ValueError(f'Output must not be a symlink: {output}')
    output = output.resolve()
    if output == dist or output in dist.parents:
        raise ValueError('Output directory cannot contain the release input directory')
    source_tar = dist / f'{PKGNAME}-{version}.tar.gz'
    if output == source_tar or source_tar in output.parents:
        raise ValueError('Output directory cannot overlap the generated source archive')
    if output.exists() or source_tar.exists() or source_tar.is_symlink():
        raise ValueError('Output directory and source package must not already exist; choose a fresh output location')

    substitutions = {'VERSION': version, 'TAG': tag, 'REPOSITORY': repository}
    for release_arch in ARCHITECTURES.values():
        path = dist / f'FlClash-{version}-linux-{release_arch}.tar.gz'
        try:
            substitutions[f'{release_arch.upper()}_SHA256'] = validate_bundle(path)
        except (OSError, tarfile.TarError, EOFError, zlib.error) as error:
            raise ValueError(f'Cannot validate release archive {path}: {error}') from error
    files = {}
    for name, key in (('flclash.desktop', 'DESKTOP_SHA256'), ('flclash-freecat.install', 'INSTALL_SHA256')):
        files[name] = (TEMPLATES / name).read_bytes()
        substitutions[key] = hashlib.sha256(files[name]).hexdigest()
    template = (TEMPLATES / 'PKGBUILD.in').read_text(encoding='utf-8')
    pkgbuild = re.sub(r'@([A-Z0-9_]+)@', lambda match: substitutions[match[1]], template)
    files['PKGBUILD'] = pkgbuild.encode('utf-8')
    files['.SRCINFO'] = render_srcinfo(pkgbuild).encode('utf-8')

    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.aur-output-', dir=output.parent) as output_temp:
        with tempfile.TemporaryDirectory(prefix='.aur-source-', dir=dist) as source_temp:
            staged_output = Path(output_temp) / 'aur'
            package_dir = staged_output / PKGNAME
            package_dir.mkdir(parents=True)
            for name, data in files.items():
                (package_dir / name).write_bytes(data)
            staged_tar = Path(source_temp) / source_tar.name
            source_package(staged_tar, files)
            if output.exists() or source_tar.exists() or source_tar.is_symlink():
                raise ValueError('Output appeared during generation; refusing to overwrite it')
            staged_output.rename(output)
            try:
                staged_tar.rename(source_tar)
            except BaseException:
                shutil.rmtree(output)
                raise
    return output / PKGNAME, source_tar


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repository', required=True, help='GitHub OWNER/REPO hosting the release')
    parser.add_argument('--tag', required=True, help='Stable release tag vX.Y.Z')
    parser.add_argument('--dist', required=True, type=Path, help='Directory containing both Linux release archives')
    parser.add_argument('--output', required=True, type=Path, help='New directory for the generated AUR package tree')
    args = parser.parse_args(argv)
    try:
        package_dir, source_tar = generate(args.repository, args.tag, args.dist, args.output)
    except (OSError, ValueError, tarfile.TarError, EOFError, zlib.error) as error:
        parser.exit(1, f'error: {error}\n')
    print(f'AUR package directory: {package_dir}')
    print(f'AUR source package: {source_tar}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
