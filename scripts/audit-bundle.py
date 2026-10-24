#!/usr/bin/env python3
"""Static, fail-closed runtime inventory audit. Never launches app or engine.

Usage: python3 scripts/audit-bundle.py /absolute/path/Cortala.app
The main executable is the sole app-native exception to the runtime manifest;
its signature is verified with the outer bundle. This is not malware analysis.
"""
import hashlib
import json
import pathlib
import re
import subprocess
import sys

MACHO = {bytes.fromhex(value) for value in (
    'feedface', 'cefaedfe', 'feedfacf', 'cffaedfe',
    'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}
SYSTEM = ('/usr/lib/', '/System/Library/')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def command(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT,
                                   env={'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'LC_ALL': 'C'})


def dependencies(path):
    return [line.strip().split(' (compatibility')[0]
            for line in command('/usr/bin/otool', '-L', str(path)).splitlines()
            if ' (compatibility version ' in line]


def rpaths(path):
    return re.findall(r'cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (.+?) \(offset',
                      command('/usr/bin/otool', '-l', str(path)))


def audit(app):
    app = app.resolve(strict=True)
    require(app.is_dir(), 'App must be a directory')

    def inside(path):
        resolved = path.resolve(strict=True)
        require(resolved.is_relative_to(app), 'Path escapes app bundle')
        return resolved

    def relative_file(value):
        require(isinstance(value, str), 'Manifest path must be text')
        path = pathlib.PurePosixPath(value)
        require(not path.is_absolute() and '..' not in path.parts and path.as_posix() == value,
                'Invalid relative manifest path')
        candidate = app / value
        require(not candidate.is_symlink(), 'Manifest payload must not be a symlink')
        require(inside(candidate).is_file(), 'Manifest file missing')
        return candidate

    # Check every link, including directory links, before following any payload.
    for path in app.rglob('*'):
        if path.is_symlink():
            inside(path)
    manifest_path = relative_file('Contents/Resources/runtime-manifest.json')
    require(manifest_path.stat().st_size <= 2_000_000, 'Runtime manifest too large')
    manifest = json.loads(manifest_path.read_text())
    require(manifest.get('format_version') == 1, 'Unsupported runtime manifest')
    components = manifest.get('components')
    license_hashes = manifest.get('license_sha256')
    require(isinstance(components, list) and isinstance(license_hashes, dict), 'Malformed runtime manifest')
    expected = {'Contents/MacOS/Cortala'}
    runtime = set()
    for entry in components:
        name = entry['path']
        require(name not in expected, 'Duplicate or forbidden runtime path')
        require(name.startswith(('Contents/Frameworks/', 'Contents/Resources/bin/')),
                'Unexpected runtime destination')
        payload = relative_file(name)
        for field in ('source_package', 'source_version'):
            require(isinstance(entry[field], str) and re.fullmatch(r'[A-Za-z0-9_.+~-]+', entry[field]),
                    'Invalid package/version metadata')
        for field in ('input_sha256', 'output_sha256'):
            require(isinstance(entry[field], str) and re.fullmatch(r'[0-9a-f]{64}', entry[field]),
                    'Invalid manifest hash')
        require(digest(payload) == entry['output_sha256'], 'Runtime payload hash mismatch: ' + name)
        notices = entry['license_files']
        first_party = entry.get('first_party') is True
        require(not first_party or (name == 'Contents/Resources/bin/justwisper-live-native' and entry['source_package'] == 'Cortala' and entry['source_version'] == 'live-protocol-1'), 'Unexpected first-party runtime')
        require(isinstance(notices, list) and (bool(notices) or first_party), 'Runtime publisher license missing')
        require(first_party or any('LICENSE' in pathlib.PurePosixPath(notice).name.upper() or
                    'COPYING' in pathlib.PurePosixPath(notice).name.upper() for notice in notices),
                'Publisher license text missing')
        for notice in notices:
            require(notice.startswith('Contents/Resources/ThirdPartyNotices/'), 'Invalid notice destination')
            license_file = relative_file(notice)
            require(license_file.stat().st_size > 0, 'Empty publisher notice')
            require(digest(license_file) == license_hashes.get(notice), 'Publisher notice hash mismatch')
        require(dependencies(payload) == entry['dependencies'], 'Dependency inventory mismatch: ' + name)
        require(rpaths(payload) == entry['rpaths'], 'Rpath inventory mismatch: ' + name)
        runtime.add(name)
        expected.add(name)

    actual = set()
    for path in app.rglob('*'):
        if path.is_symlink() or not path.is_file():
            continue
        with path.open('rb') as handle:
            if handle.read(4) in MACHO:
                actual.add(path.relative_to(app).as_posix())
    require(actual == expected, 'Native inventory differs: ' + ', '.join(sorted(actual ^ expected)))

    for name in sorted(actual):
        payload = app / name
        search = rpaths(payload)

        def expand(value):
            if value.startswith('@loader_path/'):
                return payload.parent / value[len('@loader_path/'):]
            if value.startswith('@executable_path/'):
                base = payload.parent if name == 'Contents/Resources/bin/whisper-cli-native' else app / 'Contents/MacOS'
                return base / value[len('@executable_path/'):]
            if value == '@loader_path':
                return payload.parent
            if value == '@executable_path':
                return app / 'Contents/MacOS'
            raise ValueError('Unsupported relative loader path: ' + value)

        for value in search:
            if value.startswith(SYSTEM):
                continue
            require(not value.startswith('/'), 'Non-system absolute runtime search path')
            inside(expand(value))
        for value in dependencies(payload):
            if value.startswith(SYSTEM):
                continue
            require(not value.startswith('/'), 'Non-system absolute dylib dependency')
            if value.startswith('@rpath/'):
                tail = value[len('@rpath/'):]
                candidates = [expand(prefix) / tail for prefix in search if not prefix.startswith(SYSTEM)]
                require(any(candidate.exists() and inside(candidate).relative_to(app).as_posix() in expected
                            for candidate in candidates), 'Unresolved bundle dependency: ' + value)
            else:
                target = inside(expand(value)).relative_to(app).as_posix()
                require(target in expected, 'Dependency is outside native inventory')
    command('/usr/bin/codesign', '--verify', '--deep', '--strict', str(app))
    print(f'Static bundle audit passed: main app + {len(runtime)} runtime native payloads; publisher notices and hashes verified. Ad-hoc signing is not publisher authentication or notarization.')


if __name__ == '__main__':
    try:
        require(len(sys.argv) == 2, 'Usage: audit-bundle.py APP_PATH')
        audit(pathlib.Path(sys.argv[1]))
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as error:
        print('Bundle audit failed: ' + str(error), file=sys.stderr)
        sys.exit(1)
