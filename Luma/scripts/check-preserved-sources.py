#!/usr/bin/env python3
"""Verify preserved inputs; canonical LF for declared text, exact bytes for binary."""
from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parents[1]
TEXT_SUFFIXES = {'.swift', '.py', '.sh', '.json', '.pbxproj', '.xcscheme',
                 '.xcconfig', '.plist', '.entitlements', '.xcprivacy',
                 '.md', '.txt', '.yml', '.yaml'}

def hash_content(data, mode):
    if mode == 'lf-text':
        data = data.replace(b'\r\n', b'\n')
    elif mode != 'raw':
        raise ValueError(f'Unsupported hash mode: {mode}')
    return hashlib.sha256(data).hexdigest()

def verify_file(root, item):
    relative = item['path']
    mode = item.get('hash_mode', 'raw')
    result = {'path': relative, 'hash_mode': mode, 'unchanged': False}
    path = root / relative
    try:
        if not path.resolve().is_relative_to(root.resolve()):
            raise ValueError('Path is outside the project')
        if mode == 'lf-text' and path.suffix.lower() not in TEXT_SUFFIXES:
            raise ValueError('Text normalization is forbidden for this binary/unknown file type')
        if not path.is_file():
            raise FileNotFoundError('Preserved file is missing')
        result['unchanged'] = hash_content(path.read_bytes(), mode) == item['sha256']
        if not result['unchanged']:
            result['error'] = 'Content hash mismatch'
    except (OSError, ValueError) as error:
        result['error'] = str(error)
    return result

def verify_manifest(root, baseline):
    schema = baseline.get('schema', 1)
    if schema not in (1, 2):
        raise ValueError(f'Unsupported manifest schema: {schema}')
    if schema == 2 and any('hash_mode' not in item for item in baseline['files']):
        raise ValueError('Schema 2 requires an explicit hash mode for every file')
    return [verify_file(root, item) for item in baseline['files']]

def main():
    baseline = json.loads((ROOT / 'Docs/preserved-sources.json').read_text(encoding='utf-8-sig'))
    results = verify_manifest(ROOT, baseline)
    report = {'baseline': baseline['baseline'], 'kind': 'sha256-with-explicit-text-normalization',
              'manifest_schema': baseline.get('schema', 1),
              'passed': all(item['unchanged'] for item in results), 'files': results}
    (ROOT / 'Docs/preserved-sources-checks.json').write_text(
        json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8', newline='\n')
    failed = [item['path'] for item in results if not item['unchanged']]
    if failed:
        raise SystemExit('FAIL: preserved files changed: ' + ', '.join(failed))
    print(f"PASS: {len(results)} preserved inputs match {baseline['baseline']}; text CRLF/LF normalized, binary bytes exact.")

if __name__ == '__main__':
    main()
