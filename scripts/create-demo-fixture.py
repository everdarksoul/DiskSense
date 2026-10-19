#!/usr/bin/env python3
"""Create synthetic files for screenshots. Never point this at user data."""
import argparse
from pathlib import Path
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('root', nargs='?', type=Path)
args = parser.parse_args()
root = args.root or Path(tempfile.mkdtemp(prefix='LintGoblin-Demo-'))
marker = root / '.disksense-demo-fixture'
if root.exists() and any(root.iterdir()) and not marker.exists():
    parser.error('Refusing to overwrite a non-demo directory')
root.mkdir(parents=True, exist_ok=True)
marker.write_text('Synthetic demonstration data, safe to remove as a complete folder.\n')
block = bytes(range(256)) * 4096
files = {
    'Movies/Road-trip.mov': 72,
    'Movies/Interview.mov': 44,
    'Downloads/Road-trip-copy.mov': 72,
    'Downloads/Installer.dmg': 36,
    'Projects/Build cache/Generated.bin': 26,
    'Documents/Archive.zip': 18,
    'Documents/Notes.txt': 1,
    'Pictures/Holiday.heic': 24,
    '.cache/Temporary.dat': 10,
}
for relative, size in files.items():
    target = root / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    with target.open('wb') as output:
        for n in range(size):
            output.write(block if 'Road-trip' in relative else bytes([(n + size) % 256]) * len(block))
print(root)
