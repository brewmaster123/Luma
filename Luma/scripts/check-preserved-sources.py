#!/usr/bin/env python3
"""Check known unchanged files against 0.9.1 hashes; no baseline checkout needed."""
from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parents[1]
baseline = json.loads((ROOT / 'Docs/preserved-sources.json').read_text(encoding='utf-8-sig'))
results = []
for item in baseline['files']:
    path = ROOT / item['path']
    actual = hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None
    results.append({'path': item['path'], 'unchanged': actual == item['sha256']})
report = {'baseline': baseline['baseline'], 'kind': 'sha256-regression-check',
          'passed': all(item['unchanged'] for item in results), 'files': results}
(ROOT / 'Docs/preserved-sources-checks.json').write_text(
    json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
failed = [item['path'] for item in results if not item['unchanged']]
if failed:
    raise SystemExit('FAIL: preserved files changed: ' + ', '.join(failed))
print(f"PASS: {len(results)} preserved files match 0.9.1, including planner, REM, theme, diary and audio.")
