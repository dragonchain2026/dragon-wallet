"""Standalone Linux release build; private configuration stays outside source control."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def digest(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def version():
    match = re.search(r'^version: (\d+\.\d+\.\d+)\+([1-9]\d*)$',
                      (ROOT / 'pubspec.yaml').read_text(), re.M)
    if not match:
        raise RuntimeError('Expected major.minor.patch+build in pubspec.yaml.')
    name, code = match.groups()
    ref = os.getenv('GITHUB_REF', '')
    if ref.startswith('refs/tags/') and ref != 'refs/tags/v' + name:
        raise RuntimeError('Release tag and application version differ.')
    if int(code) >= 2100000000:
        raise RuntimeError('Android versionCode limit reached.')
    return name, int(code)


def prepare():
    if os.getenv('GITHUB_ACTIONS') != 'true':
        raise RuntimeError('Secret restoration is only available in GitHub Actions.')
    required = ['ANDROID_KEYSTORE_BASE64', 'ANDROID_STORE_PASSWORD', 'ANDROID_KEY_PASSWORD',
                'ANDROID_KEY_ALIAS', 'ANDROID_STORE_TYPE', 'WALLET_API_TOKEN',
                'WALLET_API_URL', 'CEX_URL']
    if any(not os.getenv(key) for key in required):
        raise RuntimeError('Required release secrets or connection variables are missing.')
    # Individual values are masked by Actions, including values subsequently put in files.
    signing = Path(os.environ['RUNNER_TEMP']) / 'dragon-release-signing'
    signing.mkdir(mode=0o700)
    (signing / 'release.p12').write_bytes(base64.b64decode(os.environ['ANDROID_KEYSTORE_BASE64'], validate=True))
    def escape(value):
        return ''.join('\\u%04x' % ord(c) if ord(c) > 126 or c.isspace() else
                       '\\' + c if c in '\\:=#!' else c for c in value)
    fields = {'storeFile': 'release.p12', 'storePassword': os.environ['ANDROID_STORE_PASSWORD'],
              'keyPassword': os.environ['ANDROID_KEY_PASSWORD'], 'keyAlias': os.environ['ANDROID_KEY_ALIAS'],
              'storeType': os.environ['ANDROID_STORE_TYPE']}
    (signing / 'key.properties').write_text(''.join(f'{key}={escape(value)}\n' for key, value in fields.items()))
    profile = Path(os.environ['RUNNER_TEMP']) / 'dragon-release-profile.json'
    profile.write_text(json.dumps({key: os.getenv(key, '') for key in
                                  ['WALLET_API_URL', 'WALLET_API_TOKEN', 'CEX_URL', 'WALLET_API_LEGACY_URLS']}))
    with Path(os.environ['GITHUB_ENV']).open('a') as target:
        target.write(f'DRAGON_SIGNING_DIR={signing}\nDRAGON_PROFILE_FILE={profile}\n')
    print('Existing signing material and production profile restored outside the checkout.')


def verify(apk):
    name, code = version()
    sdk = Path(os.environ.get('ANDROID_HOME') or os.environ['ANDROID_SDK_ROOT'])
    tools = [sdk / 'build-tools/36.0.0']
    signer = next((p / 'apksigner' for p in reversed(tools) if (p / 'apksigner').is_file()), None)
    aapt = next((p / tool for p in reversed(tools) for tool in ['aapt2', 'aapt'] if (p / tool).is_file()), None)
    if not signer or not aapt:
        raise RuntimeError('Android signature/version verification tools are missing.')
    result = subprocess.run([str(signer), 'verify', '--verbose', '--print-certs', str(apk)],
                            capture_output=True, text=True)
    expected = (ROOT / 'scripts/release-certificate.sha256').read_text().strip().lower()
    certificates = re.findall(r'Signer #\d+ certificate SHA-256 digest: ([a-fA-F0-9]+)', result.stdout)
    print('APK signature check:', result.returncode, certificates, 'expected:', expected)
    if result.returncode or [c.lower() for c in certificates] != [expected]:
        raise RuntimeError('APK does not have the existing release signing certificate.')
    metadata = subprocess.run([str(aapt), 'dump', 'badging', str(apk)], capture_output=True, text=True)
    if metadata.returncode:
        raise RuntimeError('Android package metadata tool failed: ' + metadata.stderr[:2000])
    badging = metadata.stdout
    package = re.search(r"package: name='([^']+)' versionCode='(\d+)' versionName='([^']+)'", badging)
    print('APK package/version:', package.groups() if package else 'unrecognized package metadata')
    if not package or package.groups() != ('org.dragonwallet.dragon_wallet', str(code), name):
        raise RuntimeError('APK application ID or version differs from the release configuration.')
    with zipfile.ZipFile(apk) as archive:
        abis = sorted({n.split('/')[1] for n in archive.namelist() if re.fullmatch(r'lib/[^/]+/libapp\.so', n)})
        print('APK native ABIs:', abis)
        if abis != ['arm64-v8a', 'armeabi-v7a', 'x86_64']:
            raise RuntimeError('APK does not contain all supported ABIs.')
        for abi in abis:
            if not archive.getinfo(f'lib/{abi}/libdragon_keys_jni.so').file_size:
                raise RuntimeError('Wallet native library is empty.')
    report = dict(version=name, version_code=code, application_id=package.group(1),
                  sha256=digest(apk), signing_certificate_sha256=expected, native_abis=abis,
                  commit=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip())
    return report


def build():
    name, code = version()
    signing = Path(os.getenv('DRAGON_SIGNING_DIR', str(ROOT.parent / 'private/android-signing')))
    profile = Path(os.getenv('DRAGON_PROFILE_FILE', str(ROOT.parent / 'private/app/production/defines.json')))
    if not (signing / 'key.properties').is_file() or not profile.is_file():
        raise RuntimeError('Existing release signing configuration and production profile are required.')
    if sys.platform != 'linux':
        raise RuntimeError('Use Linux Flutter and Android SDKs for this release build.')
    values = json.loads(profile.read_text())
    if not isinstance(values.get('WALLET_API_TOKEN'), str) or len(values['WALLET_API_TOKEN']) < 32:
        raise RuntimeError('Production API token is missing or invalid.')
    out = ROOT / 'build/targets'
    out.mkdir(parents=True, exist_ok=True)
    artifact = out / f'dragon-wallet-{name}-release.apk'
    if artifact.exists():
        raise RuntimeError('Release APK already exists; archive it before rebuilding.')
    env = dict(os.environ, DRAGON_SIGNING_DIR=str(signing))
    subprocess.run(['flutter', 'build', 'apk', '--release', '--build-name=' + name,
                    '--build-number=' + str(code), '--dart-define-from-file=' + str(profile)],
                   env=env, cwd=ROOT, check=True)
    source = ROOT / 'build/app/outputs/flutter-apk/app-release.apk'
    report = verify(source)
    out.mkdir(parents=True, exist_ok=True)
    print('APK verification passed; exporting release files.')
    with source.open('rb') as origin, artifact.open('xb') as target:
        shutil.copyfileobj(origin, target)
    (out / 'SHA256SUMS').write_text(report['sha256'] + '  ' + artifact.name + '\n')
    (out / 'verification.json').write_text(json.dumps(report, indent=2) + '\n')
    (out / 'release-notes.md').write_text(
        f'Dragon Wallet {name}\n\nAndroid versionCode: {code}\n\n'
        'Signed with the existing release certificate. Includes arm64-v8a, armeabi-v7a and x86_64.\n\n'
        f'Source commit: `{report["commit"]}`\n\n'
        'Verify the APK using SHA256SUMS. This release resets Android versionCode to 1. '
        'Android normally refuses to install it over an existing build with a higher versionCode. '
        'Do not uninstall or clear wallet data to work around this restriction.\n')
    print(f'Verified release APK: {artifact.name}; version {name}, versionCode {code}.')


def publish():
    name, _ = version()
    tag = 'v' + name
    head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT).strip()
    tagged = subprocess.check_output(['git', 'rev-list', '-n', '1', tag], cwd=ROOT).strip()
    if head != tagged:
        raise RuntimeError('Release tag must point to the built commit.')
    # Create a draft first, so a partial upload cannot appear as a published release.
    subprocess.run(['gh', 'release', 'create', tag, '--verify-tag', '--draft', '--title', name,
                    '--notes-file', 'build/targets/release-notes.md',
                    f'build/targets/dragon-wallet-{name}-release.apk', 'build/targets/SHA256SUMS',
                    'build/targets/verification.json'], cwd=ROOT, check=True)
    print('Draft Release created; publish after downloading and verifying its assets.')


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['prepare', 'build', 'publish', 'verify'])
    parser.add_argument('--apk', type=Path)
    args = parser.parse_args()
    if args.action == 'verify':
        if not args.apk:
            parser.error('--apk is required for verification')
        print(json.dumps(verify(args.apk), indent=2))
    else:
        globals()[args.action]()


if __name__ == '__main__':
    try:
        main()
    except RuntimeError as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
    except (Exception, KeyboardInterrupt) as error:
        print('Release step failed (' + type(error).__name__ + '); private configuration is withheld.', file=sys.stderr)
        sys.exit(1)
