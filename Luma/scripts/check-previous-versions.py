#!/usr/bin/env python3
"""Read-only integrity audit of adjacent historical directories (workspace only)."""
from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parents[1]
WORKSPACE = ROOT.parents[1]
items = json.loads((ROOT / 'Docs/previous-versions-sha256.json').read_text(encoding='utf-8-sig'))
expected = {item['path']: item for item in items}
folders = {Path(item['path']).parts[0] for item in items}
actual = {p.relative_to(WORKSPACE).as_posix()
          for folder in folders for p in (WORKSPACE / folder).rglob('*') if p.is_file()}
changes = []
for relative, item in expected.items():
    path = WORKSPACE / relative
    if not path.is_file():
        changes.append({'path': relative, 'error': 'missing'})
        continue
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    if path.stat().st_size != item['size'] or digest.hexdigest() != item['sha256']:
        changes.append({'path': relative, 'error': 'content changed'})
new = sorted(actual - expected.keys())
report = {'kind': 'historical-directories-sha256-audit', 'checked_files': len(expected),
          'passed': not changes and not new, 'changes': changes, 'unexpected_new_files': new}
(ROOT / 'Docs/previous-versions-verification.json').write_text(
    json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
if not report['passed']:
    raise SystemExit(json.dumps(report, ensure_ascii=False))
print(f"PASS: {len(expected)} historical files unchanged; no additions or removals in previous directories.")
