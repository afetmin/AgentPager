#!/usr/bin/env python3
"""Build the fork's Windows payload or assemble verified flat release assets."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
from tempfile import TemporaryDirectory
from urllib.request import urlopen
from zipfile import ZIP_DEFLATED, ZipFile

ROOT = Path(__file__).resolve().parents[1]
SETUP = 'AgentPager-Windows-Setup.exe'
PORTABLE = 'AgentPager-Windows-Portable.zip'
ANDROID = 'AgentPager-Android.apk'
BROWSER = 'AgentPager-ChatGPT-Web-Chrome-Edge.zip'
SOURCE = 'AgentPager-Source.zip'
ASSETS = {SETUP, PORTABLE, ANDROID, BROWSER, SOURCE}
BRIDGE = 'AgentPagerBridge.exe'
ANDROID_ID = 'io.github.ealin1994.agentpager'
HEX_DIGEST = r'[0-9a-f]{64}'
# Host and runtime package texts are byte-identical for this pinned .NET build.
HOST_NOTICE_HASHES = {
    'LICENSE.TXT': 'd7a68596ab69b06f51ca278a6545148e4269a9381c26d597c13df5d88e08cf5b',
    'THIRD-PARTY-NOTICES.TXT': 'b60b2912da28eaa6518593c9e2efb5334ee062d3c42e80d8fdfa806b3dc52977',
}
NU = {
    'microsoft.netcore.app.runtime.win-x64/8.0.25': ('LICENSE.TXT', 'THIRD-PARTY-NOTICES.TXT'),
    'microsoft.netcore.app.host.win-x64/8.0.25': ('LICENSE.TXT', 'THIRD-PARTY-NOTICES.TXT'),
    'microsoft.windowsdesktop.app.runtime.win-x64/8.0.25': ('LICENSE',),
    'microsoft.aspnetcore.app.runtime.win-x64/8.0.25': ('THIRD-PARTY-NOTICES.TXT',),
    'system.drawing.common/6.0.0': ('LICENSE.TXT', 'THIRD-PARTY-NOTICES.TXT'),
    'microsoft.win32.systemevents/6.0.0': ('LICENSE.TXT', 'THIRD-PARTY-NOTICES.TXT'),
    'qrcoder/1.8.0': ('LICENSE.txt',),
}
TERMS = {
    'aspnet-LICENSE.txt': ('aspnetcore-8.0.25/LICENSE.txt',
        'https://raw.githubusercontent.com/dotnet/aspnetcore/v8.0.25/LICENSE.txt',
        'cfc21f5e8bd655ae997eec916138b707b1d290b83272c02a95c9f821b8c87310'),
    'wpf-NOTICES.txt': ('wpf-8.0.25/THIRD-PARTY-NOTICES.txt',
        'https://raw.githubusercontent.com/dotnet/wpf/v8.0.25/THIRD-PARTY-NOTICES.TXT',
        'd23dba2fee20c6b59d8f7088ee9ed372459c952a319b7ca90f3eec370cc76eb9'),
    'CsWinRT-LICENSE.txt': ('CsWinRT-LICENSE.txt',
        'https://raw.githubusercontent.com/microsoft/CsWinRT/ad5cc38488473cf994ee1b4948cad9d4e908077a/LICENSE',
        '9906940f61b1f0b533fa7d99baf55178b2808fbe113ea51dfbfad8572ccd5f2b'),
    'Windows-SDK-license.html': ('Windows-SDK-License.rtf',
        'https://aka.ms/WinSDKLicenseURL',
        'dd07eb178e00c6bba4148457fc00ff77cd4887eb521d504186fe59c9ec8bbe62'),
}


def sha(stream):
    digest = hashlib.sha256()
    for block in iter(lambda: stream.read(1024 * 1024), b''):
        digest.update(block)
    return digest.hexdigest()


def sha_file(path):
    with path.open('rb') as stream:
        return sha(stream)


def copy(src, dst):
    if src.is_symlink() or not src.is_file() or not src.stat().st_size:
        raise ValueError(f'Missing, empty or symlink input: {src}')
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(src, dst)


def git(root, *args):
    return subprocess.check_output(['git', *args], cwd=root, text=True).strip()


def archive_source(root, commit, output):
    commit = git(root, 'rev-parse', '--verify', '--end-of-options', f'{commit}^{{commit}}')
    subprocess.run(['git', 'archive', '--format=zip', '--prefix=AgentPager-Source/',
                    '-o', str(output.resolve()), commit], cwd=root, check=True)
    with ZipFile(output) as archive:
        if archive.testzip() is not None:
            raise ValueError('Source archive failed CRC verification')


def stage_release(out, entries):
    if set(entries) != ASSETS:
        raise ValueError(f'Expected exactly these release inputs: {", ".join(sorted(ASSETS))}')
    if out.exists() or out.is_symlink():
        raise FileExistsError(out)
    out.parent.mkdir(parents=True, exist_ok=True)
    with TemporaryDirectory(prefix='.agentpager-stage-', dir=out.parent) as temporary:
        stage = Path(temporary) / 'release'
        for name, path in entries.items():
            copy(path, stage / name)
        with (stage / 'SHA256SUMS.txt').open('w', encoding='ascii', newline='\n') as manifest:
            for name in sorted(ASSETS):
                manifest.write(f'{sha_file(stage / name)}  {name}\n')
        stage.rename(out)


def windows_terms(args):
    args.out.mkdir()
    for name, (_, url, expected) in TERMS.items():
        with urlopen(url, timeout=30) as response:
            data = response.read(1024 * 1024)
        if hashlib.sha256(data).hexdigest() != expected:
            raise ValueError(f'Windows term changed upstream; review the supplier notice: {name}')
        (args.out / name).write_bytes(data)


def payload(args):
    # Refuse SDK output that is no longer a single self-contained executable.
    if {p.name for p in args.exe.parent.iterdir()} != {BRIDGE} or args.exe.name != BRIDGE:
        raise ValueError(f'Expected a fresh publish directory containing only {BRIDGE}')
    args.payload.mkdir()
    copy(args.exe, args.payload / BRIDGE)
    for name in ('LICENSE', 'NOTICE.md'):
        copy(ROOT / name, args.payload / name)
    for name in ('FUSION-PIXEL-NOTICE.txt', 'OFL-1.1.txt', 'SILKSCREEN-NOTICE.txt'):
        copy(ROOT / 'LICENSES' / name, args.payload / 'LICENSES' / name)
    third = args.payload / 'THIRD-PARTY'
    copy(ROOT / 'docs/THIRD-PARTY.md', third / 'README.md')
    for package, files in NU.items():
        for name in files:
            source = args.nuget / package / name
            # On Windows the SDK may supply the RID-specific apphost itself.
            if not source.is_file() and package.startswith('microsoft.netcore.app.host.'):
                source = args.nuget / 'microsoft.netcore.app.runtime.win-x64/8.0.25' / name
                if sha_file(source) != HOST_NOTICE_HASHES[name]:
                    raise ValueError(f'Bundled apphost notice mismatch: {name}')
            copy(source, third / package / name)
    for src, (dst, _, expected) in TERMS.items():
        copy(args.terms / src, third / dst)
        if sha_file(third / dst) != expected:
            raise ValueError(f'Windows term does not match the reviewed supplier notice: {src}')
    with ZipFile(args.portable, 'x', ZIP_DEFLATED) as archive:
        for path in sorted(args.payload.rglob('*')):
            if path.is_file():
                archive.write(path, path.relative_to(args.payload).as_posix())
    with ZipFile(args.portable) as archive:
        if archive.testzip() is not None:
            raise ValueError('Portable archive failed CRC verification')


def verify_windows(directory, commit, version):
    # This establishes linkage/tamper detection, not authentication of a runner.
    receipt = json.loads((directory / 'windows-smoke.json').read_text(encoding='utf-8-sig'))
    if (receipt.get('schema') != 1 or receipt.get('commit') != commit or
            receipt.get('version') != version or receipt.get('install_uninstall_passed') is not True):
        raise ValueError('Windows smoke receipt does not match this commit/version')
    for asset in (SETUP, PORTABLE):
        if sha_file(directory / asset) != receipt.get('assets', {}).get(asset):
            raise ValueError(f'Windows smoke receipt hash mismatch: {asset}')
    with ZipFile(directory / PORTABLE) as archive:
        if archive.namelist().count(BRIDGE) != 1 or archive.testzip() is not None:
            raise ValueError('Invalid Windows portable archive')
        with archive.open(BRIDGE) as bridge:
            if sha(bridge) != receipt.get('installed_bridge_sha256'):
                raise ValueError('Portable Bridge does not match the installed Bridge recorded by smoke')


def verify_apk(args, apk):
    expected = args.android_cert_sha256.lower()
    if re.fullmatch(HEX_DIGEST, expected) is None:
        raise ValueError('Provide the retained release certificate SHA-256 as 64 hex digits')
    result = subprocess.check_output([args.apksigner, 'verify', '--verbose', '--print-certs',
                                      str(apk)], text=True, stderr=subprocess.STDOUT)
    digests = re.findall(r'^Signer #\d+ certificate SHA-256 digest: ([a-fA-F0-9]{64})\s*$',
                         result, flags=re.MULTILINE)
    if ([d.lower() for d in digests] != [expected] or
            not re.search(r'^Verified using v[23](?:\.1)? scheme .*: true\s*$', result, re.MULTILINE) or
            re.search(r'^Signer #\d+ certificate DN: .*CN=Android Debug(?:,|$)', result, re.MULTILINE | re.I)):
        raise ValueError('Android APK must use the expected non-debug release certificate and v2/v3 signing')
    badging = subprocess.check_output([args.aapt2, 'dump', 'badging', str(apk)], text=True)
    package = re.search(r"^package: name='([^']+)' versionCode='(\d+)' versionName='([^']+)'",
                        badging, re.MULTILINE)
    if (not package or package[1] != ANDROID_ID or int(package[2]) < 1 or
            package[3] != args.version or 'application-debuggable' in badging.splitlines()):
        raise ValueError('APK has the wrong fork ID, version or debuggable flag')


def assemble(args):
    if git(ROOT, 'status', '--porcelain', '--untracked-files=normal'):
        raise ValueError('Assemble from a clean commit (including browser extension source)')
    commit = git(ROOT, 'rev-parse', 'HEAD')
    if re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?', args.version) is None:
        raise ValueError('Expected a release version such as 0.4.3-rc.2')
    with TemporaryDirectory(prefix='agentpager-assemble-') as temporary:
        scratch = Path(temporary)
        for name in (SETUP, PORTABLE, 'windows-smoke.json'):
            copy(args.windows / name, scratch / name)
        verify_windows(scratch, commit, args.version)
        copy(args.apk, scratch / ANDROID)
        verify_apk(args, scratch / ANDROID)
        subprocess.run([sys.executable, str(ROOT / 'scripts/package-browser.py'), '--out', str(scratch)],
                       cwd=ROOT, check=True)
        archive_source(ROOT, commit, scratch / SOURCE)
        stage_release(args.out, {name: scratch / name for name in ASSETS})
    print(f'Prepared {len(ASSETS)} standalone assets and SHA256SUMS.txt in {args.out}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    windows = commands.add_parser('windows-payload')
    for name in ('exe', 'terms', 'payload', 'portable'):
        windows.add_argument(f'--{name}', required=True, type=Path)
    windows.add_argument('--nuget', type=Path, default=Path.home() / '.nuget/packages')

    windows.set_defaults(run=payload)
    terms = commands.add_parser('windows-terms')
    terms.add_argument('--out', required=True, type=Path)
    terms.set_defaults(run=windows_terms)
    release = commands.add_parser('assemble')
    for name in ('out', 'windows', 'apk', 'apksigner', 'aapt2'):
        release.add_argument(f'--{name}', required=True, type=Path)
    for name in ('version', 'android-cert-sha256'):
        release.add_argument(f'--{name}', required=True)
    release.set_defaults(run=assemble)
    args = parser.parse_args()
    try:
        args.run(args)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'{error}\n')


if __name__ == '__main__':
    main()
