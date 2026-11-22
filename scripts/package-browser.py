#!/usr/bin/env python3
"""Build locally installable/testable AgentPager browser extension archives."""
import argparse
import json
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile

ROOT = Path(__file__).resolve().parents[1]
EXT = ROOT / 'tools/ChatGPTWebMonitor'
GECKO_ID = 'agentpager-chatgpt-web@agentpager.invalid'


def pack(output: Path, include_firefox: bool = False) -> None:
    output.mkdir(parents=True, exist_ok=True)
    for browser in ('Chrome-Edge', 'Firefox') if include_firefox else ('Chrome-Edge',):
        manifest = json.loads((EXT / 'manifest.json').read_text(encoding='utf-8'))
        suffix = 'zip'
        if browser == 'Firefox':
            suffix = 'xpi'
            manifest.pop('minimum_chrome_version', None)
            manifest['background'] = {'scripts': ['background.js']}
            manifest['browser_specific_settings'] = {'gecko': {
                'id': GECKO_ID, 'strict_min_version': '140.0',
                # Title and hashed conversation identity are sent to the local companion.
                'data_collection_permissions': {'required': ['websiteContent', 'browsingActivity']},
            }}
        destination = output / f'AgentPager-ChatGPT-Web-{browser}.{suffix}'
        with ZipFile(destination, 'w', ZIP_DEFLATED) as archive:
            archive.writestr('manifest.json', json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
            for name in ('background.js', 'content.js', 'popup.js', 'popup.html', 'icon.png'):
                archive.write(EXT / name, name)
            for name in ('LICENSE', 'NOTICE.md'):
                archive.write(ROOT / name, name)
            for name in ('docs/RELEASE.en.md', 'docs/RELEASE.zh-CN.md'):
                archive.write(ROOT / name, name)
        with ZipFile(destination) as archive:
            if archive.testzip() is not None:
                raise RuntimeError(f'invalid archive: {destination}')
        print(destination)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, default=ROOT / 'dist/extensions')
    parser.add_argument('--include-firefox', action='store_true', help='Also build an unsigned developer-only XPI')
    args = parser.parse_args()
    pack(args.out, args.include_firefox)
