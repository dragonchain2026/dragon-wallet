"""Release failure guards, using synthetic credentials and tool output only."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import release


class ReleaseTests(unittest.TestCase):
    def test_tag_mismatch_fails(self):
        with patch.dict(os.environ, GITHUB_REF='refs/tags/v9.9.9'):
            with self.assertRaisesRegex(RuntimeError, 'tag'):
                release.version()

    def test_missing_configuration_never_starts_flutter(self):
        with tempfile.TemporaryDirectory() as folder, patch.dict(os.environ, DRAGON_SIGNING_DIR=folder, DRAGON_PROFILE_FILE=folder + '/missing.json'), patch.object(release.subprocess, 'run') as run:
            with self.assertRaisesRegex(RuntimeError, 'required'):
                release.build()
            run.assert_not_called()

    def test_secret_restoration_refuses_local_execution(self):
        with patch.dict(os.environ, GITHUB_ACTIONS='false'):
            with self.assertRaisesRegex(RuntimeError, 'GitHub Actions'):
                release.prepare()

    def test_signature_version_and_native_checks(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'scripts').mkdir()
            (root / 'scripts/release-certificate.sha256').write_text('ab' * 32)
            (root / 'pubspec.yaml').write_text('version: 1.0.0+1\n')
            tools = root / 'sdk/build-tools/36.0.0'
            tools.mkdir(parents=True)
            for tool in ['apksigner', 'aapt']:
                (tools / tool).touch()
            apk = root / 'release.apk'
            def make_apk(missing_jni=False):
                with zipfile.ZipFile(apk, 'w') as archive:
                    for abi in ['arm64-v8a', 'armeabi-v7a', 'x86_64']:
                        archive.writestr(f'lib/{abi}/libapp.so', b'synthetic')
                        if not missing_jni:
                            archive.writestr(f'lib/{abi}/libdragon_keys_jni.so', b'synthetic')
            signature = subprocess.CompletedProcess([], 0, 'Signer #1 certificate SHA-256 digest: ' + 'ab' * 32)
            badging = subprocess.CompletedProcess([], 0, "package: name='org.dragonwallet.dragon_wallet' versionCode='1' versionName='1.0.0'")
            make_apk()
            with patch.object(release, 'ROOT', root), patch.dict(os.environ, ANDROID_HOME=str(root / 'sdk'), GITHUB_REF='refs/tags/v1.0.0'), patch.object(release.subprocess, 'check_output', return_value='synthetic-commit'):
                with patch.object(release.subprocess, 'run', side_effect=[signature, badging]):
                    report = release.verify(apk)
                    self.assertEqual(report['version_code'], 1)
                    self.assertEqual(len(report['native_abis']), 3)
                with patch.object(release.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, '')):
                    with self.assertRaisesRegex(RuntimeError, 'certificate'):
                        release.verify(apk)
                wrong_version = subprocess.CompletedProcess([], 0, badging.stdout.replace("versionCode='1'", "versionCode='2'"))
                with patch.object(release.subprocess, 'run', side_effect=[signature, wrong_version]):
                    with self.assertRaisesRegex(RuntimeError, 'version'):
                        release.verify(apk)
                make_apk(missing_jni=True)
                with patch.object(release.subprocess, 'run', side_effect=[signature, badging]):
                    with self.assertRaises(KeyError):
                        release.verify(apk)

    def test_release_tag_must_match_built_commit(self):
        with patch.object(release.subprocess, 'check_output', side_effect=[b'one', b'two']), patch.object(release.subprocess, 'run') as run:
            with self.assertRaisesRegex(RuntimeError, 'built commit'):
                release.publish()
            run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
