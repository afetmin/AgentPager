#!/usr/bin/env python3
"""Assemble a local AgentPager candidate without publishing or using signing keys."""
import argparse
import hashlib
import importlib.util
from pathlib import Path
import re
import shutil
import subprocess
from tempfile import TemporaryDirectory
from zipfile import ZIP_DEFLATED, ZIP_STORED, ZipFile

ROOT = Path(__file__).resolve().parents[1]
VERSION = '0.4.3-rc.1'
PREFIX = 'AgentPager-' + VERSION
NL = ('LICENSE', 'NOTICE.md')
DOCS = ('RELEASE.zh-CN.md', 'RELEASE.en.md', 'BUILD.md', f'VERIFY-{VERSION}.md')
NU = {
    'microsoft.netcore.app.runtime.win-x64/8.0.25': ('LICENSE.TXT', 'THIRD-PARTY-NOTICES.TXT'),
    'microsoft.netcore.app.host.win-x64/8.0.25': ('LICENSE.TXT', 'THIRD-PARTY-NOTICES.TXT'),
    'microsoft.windowsdesktop.app.runtime.win-x64/8.0.25': ('LICENSE',),
    'microsoft.aspnetcore.app.runtime.win-x64/8.0.25': ('THIRD-PARTY-NOTICES.TXT',),
    'system.drawing.common/6.0.0': ('LICENSE.TXT', 'THIRD-PARTY-NOTICES.TXT'),
    'microsoft.win32.systemevents/6.0.0': ('LICENSE.TXT', 'THIRD-PARTY-NOTICES.TXT'),
    'qrcoder/1.8.0': ('LICENSE.txt',),
}
WIN_TERMS = {
    'aspnet-LICENSE.txt': 'aspnetcore-8.0.25/LICENSE.txt',
    'wpf-NOTICES.txt': 'wpf-8.0.25/THIRD-PARTY-NOTICES.txt',
    'CsWinRT-LICENSE.txt': 'CsWinRT-LICENSE.txt',
    'Windows-SDK-license.html': 'Windows-SDK-License.rtf',
}
ANDROID_TERMS = ('APACHE-2.0.txt', 'libyuv-LICENSE.txt', 'libyuv-PATENTS.txt')
PRIVATE = re.compile(rb'-----BEGIN (?:[A-Z]+ )?PRIVATE KEY-----|\bsk-(?:proj-|live-)?[A-Za-z0-9_-]{30,}\b|\bgh[pousr]_[A-Za-z0-9]{30,}\b')
DENY = {'.db', '.jsonl', '.log', '.pfx', '.key', '.pem', '.jks', '.keystore', '.apk', '.exe', '.dll', '.zip'}


def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def copy(src, dst):
    dst.parent.mkdir(parents=True, exist_ok=True)
    if not src.is_file() or not src.stat().st_size:
        raise ValueError(f'Missing input: {src}')
    shutil.copyfile(src, dst)


def docs(destination):
    for name in NL:
        copy(ROOT / name, destination / name)
    for name in DOCS:
        copy(ROOT / 'docs' / name, destination / name)
    shutil.copytree(ROOT / 'LICENSES', destination / 'LICENSES')


def zipped(destination, root, compression=ZIP_DEFLATED, prefix=''):
    with ZipFile(destination, 'w', compression) as z:
        for p in sorted(root.rglob('*')):
            if p.is_file():
                z.write(p, prefix + p.relative_to(root).as_posix())
    with ZipFile(destination) as z:
        bad = z.testzip()
        if bad is not None:
            raise ValueError(f'Corrupt entry in {destination.name}: {bad}')


def source_path_list():
    command = ['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard']
    paths = sorted(set(subprocess.check_output(command, cwd=ROOT).split(b'\0')) - {b''})
    for raw in paths:
        rel = Path(raw.decode())
        path = ROOT / rel
        if path.is_symlink() or not path.is_file() or rel.suffix.lower() in DENY or rel.name.startswith('.env'):
            raise ValueError(f'Unexpected source input: {rel}')
        if path.stat().st_size <= 2_000_000 and path.suffix.lower() not in {'.ttf', '.otf', '.jar', '.ico', '.png'}:
            if PRIVATE.search(path.read_bytes()):
                raise ValueError(f'Potential sensitive material: {rel}')
        yield path, rel


def pack(args):
    if args.out.exists():
        raise FileExistsError(args.out)
    upstream = subprocess.check_output(['git', 'show', '2651fd4a9fee61553ad3b59f52692e00385a5487:LICENSE'], cwd=ROOT)
    if (ROOT / 'LICENSE').read_bytes() != upstream:
        raise ValueError('The upstream license has changed')
    with TemporaryDirectory(prefix='agentpager-stage-', dir=args.out.parent) as scratch:
        stage = Path(scratch)
        dist, windows = stage / 'dist', stage / 'windows'
        dist.mkdir()
        docs(dist)
        docs(windows)
        copy(args.exe, windows / 'AgentPagerBridge.exe')
        third = windows / 'THIRD-PARTY'
        for package, entries in NU.items():
            for name in entries:
                copy(args.nuget / package / name, third / package / name)
        for incoming, outgoing in WIN_TERMS.items():
            copy(args.terms / incoming, third / outgoing)
        for name in ANDROID_TERMS:
            copy(args.terms / name, dist / 'THIRD-PARTY' / 'Android' / name)
        for name, path in [('Debug', args.debug_deps), ('Release', args.release_deps)]:
            coords = set()
            for line in path.read_text().splitlines():
                m = re.search(r'--- ([\w.-]+):([\w.-]+):([^\s]+)(?: -> ([\w.\-]+))?', line)
                if m and '(c)' not in line:
                    if 'FAILED' in line:
                        raise ValueError('Unresolved Android dependency')
                    coords.add(f'{m[1]}:{m[2]}:{m[4] or m[3]}')
            if not coords:
                raise ValueError(f'No Android dependencies found in {path}')
            (dist / 'THIRD-PARTY' / 'Android' / f'{name}-dependencies.txt').write_text('\n'.join(sorted(coords)) + '\n')
        copy(ROOT / 'docs' / 'THIRD-PARTY.md', dist / 'THIRD-PARTY' / 'README.md')
        copy(ROOT / 'docs' / 'THIRD-PARTY.md', third / 'README.md')
        copy(args.apk, dist / 'Android-Test.apk')
        copy(args.release_apk, dist / 'Android-Release-Unsigned.apk')
        spec = importlib.util.spec_from_file_location('package_browser', ROOT / 'scripts/package-browser.py')
        browser = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(browser)
        browser.pack(dist)
        zipped(dist / f'{PREFIX}-Windows-x64.zip', windows)
        with ZipFile(dist / f'{PREFIX}-Source.zip', 'w', ZIP_DEFLATED) as z:
            paths = list(source_path_list())
            for path, rel in paths:
                z.write(path, f'{PREFIX}-Source/{rel.as_posix()}')
        with ZipFile(dist / f'{PREFIX}-Source.zip') as z:
            assert z.testzip() is None and len(z.namelist()) == len(paths)
            for path, rel in paths:
                assert hashlib.sha256(z.read(f'{PREFIX}-Source/{rel.as_posix()}')).hexdigest() == sha(path), rel
        print(f'Verified {len(paths)} source files')
        entries = sorted(p for p in dist.rglob('*') if p.is_file())
        (dist / 'SHA256SUMS.txt').write_text(''.join(f'{sha(p)}  {p.relative_to(dist).as_posix()}\n' for p in entries))
        bundle = stage / f'{PREFIX}-Test-Bundle.zip'
        zipped(bundle, dist, ZIP_STORED, PREFIX + '/')
        args.out.mkdir()
        for p in dist.iterdir():
            p.rename(args.out / p.name)
        bundle.rename(args.out / bundle.name)
        for p in sorted(args.out.iterdir()):
            if p.is_file():
                print(f'{p.name}: {p.stat().st_size} bytes  {sha(p)}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('out', 'exe', 'apk', 'release-apk', 'terms', 'debug-deps', 'release-deps'):
        parser.add_argument(f'--{name}', required=True, type=Path)
    parser.add_argument('--nuget', type=Path, default=Path.home() / '.nuget/packages')
    pack(parser.parse_args())
