#!/usr/bin/env python3
"""Export reviewed project files, never the local working directory as a whole."""
from pathlib import Path
import hashlib
import subprocess
import zipfile

root = Path(__file__).resolve().parents[1]
files = [root / name for name in (
    '.gitignore', 'README.md', 'VALIDATION.md', 'GITHUB_RELEASE.md',
    'build.sh', 'build-installer.sh', 'test.sh', 'bundle_licenses.py',
)]
for directory, suffixes in {
    'Sources': {'.swift'}, 'Tests': {'.swift', '.py'},
    'Scripts': {'.py'}, 'Resources': {'.png', '.svg', '.txt', '.plist'},
}.items():
    files.extend(p for p in (root / directory).iterdir()
                 if p.is_file() and p.suffix in suffixes)
for name in ('ipatool', 'unfairplay'):
    vendor = root / 'vendor' / name
    tracked = subprocess.check_output(
        ['git', '-C', str(vendor), 'ls-files', '-z']).decode().split('\0')
    files.extend(vendor / path for path in tracked if path)
# This integration test is a local addition to the upstream snapshot.
files.append(root / 'vendor/ipatool/cmd/appstoreplusplus_auth_test.go')
entries = {}
for path in sorted(set(files)):
    relative = path.relative_to(root)
    assert not path.is_symlink(), f'Symlink excluded: {relative}'
    assert path.is_file(), f'Missing source: {relative}'
    assert not set(relative.parts) & {
        '.git', '.toolchain', 'build', 'dist', '.gomodcache', '.gocache',
        '.gopath', '.appstoreplusplus', 'captures', 'models',
    }, f'Private directory excluded: {relative}'
    assert path.suffix.lower() not in {
        '.ipa', '.bin', '.pkg', '.zip', '.keychain', '.db', '.log',
    }, f'Non-source file excluded: {relative}'
    entries[str(relative)] = path.read_bytes()
manifest = ''.join(f'{hashlib.sha256(data).hexdigest()}  {name}\n'
                   for name, data in sorted(entries.items()))
entries['SOURCE_SHA256SUMS.txt'] = manifest.encode()
output = root / 'dist/AppStorePlusPlus-1.3.0-GitHub-source.zip'
output.parent.mkdir(exist_ok=True)
with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as archive:
    for name, data in sorted(entries.items()):
        info = zipfile.ZipInfo(name)
        info.compress_type = zipfile.ZIP_DEFLATED
        mode = 0o755 if name.endswith('.sh') else 0o644
        info.external_attr = (0o100000 | mode) << 16
        archive.writestr(info, data)
with zipfile.ZipFile(output) as archive:
    assert archive.testzip() is None
    assert set(archive.namelist()) == set(entries)
    for name, data in entries.items():
        assert archive.read(name) == data
print(f'Verified {len(entries)} source files: {output}')
