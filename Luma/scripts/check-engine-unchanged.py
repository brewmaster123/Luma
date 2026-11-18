#!/usr/bin/env python3
"""0.9.8/0.9.9: verifies that everything recorded as "the same as in 0.9.7" still is.

0.9.9: AppModel.swift has three small recorded additions (renaming a sound, installing a Lumenoir melody,
importing while the quiet rain plays). It is listed under "engine_changed" with its reason and is pinned to its
new content, so any other edit of it still fails this check.

The signal engine of 0.9.7 (alarms, the queue, the night sound, storage, the Watch plan) is carried
into 0.9.8 file for file. Docs/unchanged-since-0.9.7.json lists those files with their SHA-256;
this check fails if one of them has been edited, and if a file changed on purpose is missing.
Reads files only; writes a short report to Docs/engine-unchanged-checks.json.
"""
from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parents[1]


def digest(path, mode):
    data = path.read_bytes()
    if mode == 'lf-text':
        data = data.replace(b'\r\n', b'\n')
    elif mode != 'raw':
        raise ValueError('Unsupported hash mode: %s' % mode)
    return hashlib.sha256(data).hexdigest()


def main():
    manifest = json.loads((ROOT / 'Docs/unchanged-since-0.9.7.json').read_text(encoding='utf-8-sig'))
    failed = []
    for item in manifest['unchanged']:
        path = ROOT / item['path']
        if not path.resolve().is_relative_to(ROOT.resolve()):
            failed.append(item['path'] + ' (outside the project)')
        elif not path.is_file():
            failed.append(item['path'] + ' (missing)')
        elif digest(path, item['hash_mode']) != item['sha256']:
            failed.append(item['path'] + ' (changed)')
    for relative in list(manifest['changed']) + list(manifest['added']):
        if not (ROOT / relative).is_file():
            failed.append(relative + ' (missing)')
    # 0.9.9: an engine file changed on purpose is pinned to its new content: any further edit fails here.
    pinned = {}
    for item in manifest.get('engine_changed', []):
        path = ROOT / item['path']
        if not item.get('reason'):
            failed.append(item['path'] + ' (engine change without a recorded reason)')
        if not path.is_file():
            failed.append(item['path'] + ' (missing)')
        elif digest(path, item['hash_mode']) != item['sha256']:
            failed.append(item['path'] + ' (changed after its recorded engine change)')
        pinned[item['path']] = item
    # The files that make the signals work must be among the unchanged ones. Only AppModel.swift may instead be
    # a recorded, pinned engine change (0.9.9: three small additions; see its reason in the manifest).
    unchanged = {item['path'] for item in manifest['unchanged']}
    for relative in ['Sources/Platform/AppModel.swift', 'Sources/iPhone/SystemAlarmService.swift',
                     'Sources/iPhone/AlarmKitScheduler.swift', 'Sources/iPhone/AlarmKitSoundBuilder.swift',
                     'Sources/LumaCore/SystemAlarmPlan.swift', 'Sources/LumaCore/IndirectMethod.swift',
                     'Sources/Platform/PhoneAudio.swift', 'Sources/Platform/LocalStore.swift',
                     'Sources/iPhone/WatchCueLink.swift', 'Sources/LumaCore/WatchCuePlan.swift',
                     'Sources/iPhone/LumaApp.swift']:
        allowed = relative == 'Sources/Platform/AppModel.swift' and relative in pinned
        if relative not in unchanged and not allowed:
            failed.append(relative + ' (must be recorded as unchanged)')
    report = {'base': manifest['base'], 'version': manifest['version'], 'passed': not failed,
              'unchanged_files': len(manifest['unchanged']), 'engine_changed': sorted(pinned),
              'changed_on_purpose': manifest['changed'], 'failed': failed}
    (ROOT / 'Docs/engine-unchanged-checks.json').write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8', newline='\n')
    if failed:
        raise SystemExit('FAIL: differs from %s: %s' % (manifest['base'], '; '.join(failed)))
    print('PASS: %d files are the same as in %s; %d changed on purpose, %d added.'
          % (len(manifest['unchanged']), manifest['base'], len(manifest['changed']), len(manifest['added'])))


if __name__ == '__main__':
    main()
