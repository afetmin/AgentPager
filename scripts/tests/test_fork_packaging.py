import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts/package-fork-release.py'
NAMES = {'AgentPager-Windows-Setup.exe', 'AgentPager-Windows-Portable.zip',
         'AgentPager-Android.apk', 'AgentPager-ChatGPT-Web-Chrome-Edge.zip',
         'AgentPager-Source.zip', 'SHA256SUMS.txt'}


def module():
    spec = importlib.util.spec_from_file_location('fork_release', SCRIPT)
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


class InstallerContract(unittest.TestCase):
    def test_fork_uninstall_is_separate_and_file_only(self):
        installer = ROOT / 'windows/installer/AgentPager.Fork.iss'
        self.assertTrue(installer.is_file(), 'no fork installer definition')
        contents = installer.read_text(encoding='utf-8')
        upstream = (installer.parent / 'AgentPager.iss').read_text(encoding='utf-8')
        self.assertNotEqual(next(x for x in contents.splitlines() if x.startswith('AppId=')),
                            next(x for x in upstream.splitlines() if x.startswith('AppId=')))
        self.assertIn('PrivilegesRequired=lowest', contents)
        self.assertIn('Uninstallable=yes', contents)
        self.assertNotIn('\\Programs\\AgentPager\n', contents)
        for directive in ('[UninstallRun]', '[UninstallDelete]', '[Registry]', '--uninstall-hook'):
            self.assertNotIn(directive.lower(), contents.lower())


class FlatPackaging(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.work = Path(self.scratch.name)

    def test_release_has_only_standalone_assets_and_complete_hashes(self):
        fork = module()
        inputs = self.work / 'inputs'
        inputs.mkdir()
        for name in NAMES - {'SHA256SUMS.txt'}:
            (inputs / name).write_bytes(name.encode())
        out = self.work / 'release'
        fork.stage_release(out, {p.name: p for p in inputs.iterdir()})
        self.assertEqual({p.name for p in out.iterdir()}, NAMES)
        self.assertEqual((out / 'SHA256SUMS.txt').read_text().splitlines(),
                         [f'{hashlib.sha256((out / n).read_bytes()).hexdigest()}  {n}'
                          for n in sorted(NAMES - {'SHA256SUMS.txt'})])

    def test_missing_or_unexpected_release_input_does_not_leave_output(self):
        fork = module()
        out = self.work / 'release'
        for entries in ({}, {'Android-Release-Unsigned.apk': self.work / 'missing'}):
            with self.assertRaises(ValueError):
                fork.stage_release(out, entries)
            self.assertFalse(out.exists())

    def test_native_receipt_binds_both_windows_artifacts_to_commit_and_installed_bytes(self):
        fork = module()
        setup = self.work / fork.SETUP
        portable = self.work / fork.PORTABLE
        setup.write_bytes(b'fixture Setup')
        bridge = b'fixture Bridge'
        with ZipFile(portable, 'w') as zip_file:
            zip_file.writestr(fork.BRIDGE, bridge)
        receipt_file = self.work / 'windows-smoke.json'
        receipt = {'schema': 1, 'commit': 'fixture', 'version': '0.4.3-rc.2',
                   'install_uninstall_passed': True,
                   'assets': {p.name: fork.sha_file(p) for p in (setup, portable)},
                   'installed_bridge_sha256': hashlib.sha256(bridge).hexdigest()}
        receipt_file.write_text(json.dumps(receipt))
        fork.verify_windows(self.work, 'fixture', '0.4.3-rc.2')
        with self.assertRaisesRegex(ValueError, 'commit/version'):
            fork.verify_windows(self.work, 'other-source', '0.4.3-rc.2')
        receipt['installed_bridge_sha256'] = 'not-the-portable-bridge'
        receipt_file.write_text(json.dumps(receipt))
        with self.assertRaisesRegex(ValueError, 'does not match the installed Bridge'):
            fork.verify_windows(self.work, 'fixture', '0.4.3-rc.2')
        setup.write_bytes(b'substituted Setup')
        with self.assertRaisesRegex(ValueError, 'hash mismatch'):
            fork.verify_windows(self.work, 'fixture', '0.4.3-rc.2')

    def test_committed_source_ignores_dirty_files(self):
        fork = module()
        def git(*args):
            return subprocess.check_output(['git', *args], cwd=self.work, text=True).strip()
        git('init', '-q')
        source = self.work / 'source.txt'
        source.write_bytes(b'committed')
        git('add', source.name)
        git('-c', 'user.name=fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'fixture')
        source.write_bytes(b'dirty')
        (self.work / 'untouched.txt').write_text('not committed')
        output = self.work / 'source.zip'
        fork.archive_source(self.work, git('rev-parse', 'HEAD'), output)
        with ZipFile(output) as zip_file:
            self.assertEqual(zip_file.namelist(), ['AgentPager-Source/', 'AgentPager-Source/source.txt'])
            self.assertEqual(zip_file.read('AgentPager-Source/source.txt'), b'committed')


if __name__ == '__main__':
    unittest.main()
