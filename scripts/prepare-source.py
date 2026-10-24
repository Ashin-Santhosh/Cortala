#!/usr/bin/env python3
"""Create a reviewed-candidate source snapshot without private Git history or builds.

Run the secret scanner on the output before publishing; this is an allowlist,
not a claim that arbitrary source files cannot contain sensitive text.
"""
import hashlib
import json
import pathlib
import shutil
import subprocess

root = pathlib.Path(__file__).resolve().parent.parent
output = root / 'dist/public-source/JustWhisper'
prefixes = {'Sources', 'Tests', 'scripts', 'tools', 'native', 'desktop', 'docs',
            'ThirdPartyNotices', 'Assets', 'benchmarks', '.github'}
root_files = {'README.md', 'LICENSE', 'LICENSE.md', 'COPYRIGHT', 'CONTRIBUTING.md',
              'SECURITY.md', '.gitignore', 'Package.swift', 'Package.resolved'}
allowed = {'.swift', '.py', '.sh', '.plist', '.md', '.txt', '.json', '.jsonl',
           '.png', '.cpp', '.h', '.cjs', '.js', '.css', '.html', '.yml', '.yaml', '.toml'}
files = subprocess.check_output(['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'], cwd=root).decode().split('\0')
selected = []
for name in sorted(set(filter(None, files))):
    relative = pathlib.PurePosixPath(name)
    if relative.parts[0] not in prefixes and name not in root_files:
        continue
    source = root / name
    if source.is_symlink() or not source.is_file() or source.stat().st_size > 20_000_000:
        raise SystemExit(f'Unexpected source entry: {name}')
    publisher_notice = relative.parts[0] == 'ThirdPartyNotices' and source.name.endswith('-LICENSE')
    if name not in root_files and source.suffix not in allowed and source.name not in {'CMakeLists.txt', 'NOTICE', 'LICENSE', 'COPYING'} and not publisher_notice:
        raise SystemExit(f'Unreviewed source type: {name}')
    selected.append((name, source))
if output.exists():
    shutil.rmtree(output)
output.mkdir(parents=True)
manifest = []
for name, source in selected:
    target = output / name
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, target)
    target.chmod(0o755 if source.stat().st_mode & 0o111 else 0o644)
    manifest.append({'file': name, 'sha256': hashlib.sha256(target.read_bytes()).hexdigest()})
(output / 'SOURCE-MANIFEST.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(f'Prepared {len(selected)} source files without .git, builds, recordings, credentials or model weights.')
print(output)
