#!/usr/bin/env python3
"""Set the app's minimum macOS to the highest bundled native requirement."""
import pathlib
import plistlib
import re
import subprocess
import sys

app = pathlib.Path(sys.argv[1]).resolve(strict=True)
requirements = []
for file in app.rglob('*'):
    if not file.is_file() or file.is_symlink():
        continue
    with file.open('rb') as stream:
        magic = stream.read(4)
    if magic not in (b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe'):
        continue
    result = subprocess.run(['xcrun', 'vtool', '-show-build', str(file)], capture_output=True, text=True, check=True)
    requirements.extend(tuple(map(int, value.split('.'))) for value in re.findall(r'\bminos\s+([0-9.]+)', result.stdout))
if not requirements:
    raise SystemExit('No native deployment requirements found')
minimum = '.'.join(map(str, max(requirements)))
plist = app / 'Contents/Info.plist'
with plist.open('rb') as stream:
    info = plistlib.load(stream)
info['LSMinimumSystemVersion'] = minimum
with plist.open('wb') as stream:
    plistlib.dump(info, stream)
print(f'Packaged minimum macOS: {minimum}')
