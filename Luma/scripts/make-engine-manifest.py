#!/usr/bin/env python3
"""0.9.8 maintainer tool: records which files are the same as in the version this one was built on.

Usage (from the Luma folder):
    python3 scripts/make-engine-manifest.py <path to the base version's Luma folder>

The base version is only read. The result is Docs/unchanged-since-0.9.7.json: every file that is the
same in both versions with its SHA-256 (text files are compared with CRLF turned into LF, everything
else byte for byte), and the lists of files that were changed, added or removed on purpose.
scripts/check-engine-unchanged.py then verifies the first list without needing the base version.
"""
from pathlib import Path
import hashlib
import json
import sys

ROOT = Path(__file__).resolve().parents[1]
TEXT_SUFFIXES = {'.swift', '.py', '.sh', '.json', '.pbxproj', '.xcscheme', '.xcconfig', '.plist',
                 '.entitlements', '.xcprivacy', '.md', '.txt', '.yml', '.yaml', '.strings'}
# Reports that the checks write, and the caches of tools: not part of the app.
SKIP_PARTS = {'.validation-tools', '.build', '__pycache__', 'build-logs', 'dist'}
SKIP_FILES = {'Docs/static-checks.json', 'Docs/source-grammar-checks.json',
              'Docs/preserved-sources-checks.json', 'Docs/unchanged-since-0.9.7.json',
              'Docs/engine-unchanged-checks.json'}
# Only these folders hold the app itself; documents are rewritten for every version.
SCOPE = ('Sources/', 'Tests/', 'Resources/', 'Config/', 'scripts/', 'Luma.xcodeproj/', 'Package.swift')

# Why each changed file was changed. A changed file that is not listed here stops the tool.
REASONS = {
    'Sources/LumaCore/AlarmSignalDuration.swift':
        'The signal may last 3-20 seconds (was 3-10); the interruption window covers 20 seconds. The formula is the same.',
    'Tests/LumaCoreTests/AlarmSignalDurationTests.swift': 'Tests for the 3-20 second range.',
    'Sources/iPhone/NightAudio.swift':
        'One line: the lock-screen title of the night sound is shown in the chosen language.',
    'Sources/Watch/WatchCueStore.swift':
        'Two lines: the title and text of the watch notification are looked up in the watch language.',
    'Sources/Watch/LumaWatchApp.swift': 'One line: the status text is shown in the watch language.',
    'Sources/iPhone/DesignSystem.swift':
        'New design ("Atelier Night"); the message card shows the name Lumenoir; 0.9.9: every sheet is a clear '
        'full-screen cover, so the living scene stays visible behind it (iOS 26 paints a full-height sheet grey).',
    'Sources/iPhone/PhoneRootView.swift':
        'New design; three tabs on one canvas; no introduction screen; 0.9.9: sheets as clear covers, '
        'the Lumenoir melodies are installed and the optional indirect method after an alarm is attached at launch.',
    'Sources/iPhone/IndirectMethodView.swift':
        'New design; the same calls of the app model; 0.9.9: "End session" also switches the quiet rain off '
        '(the Settings switch\'s own call) unless an alarm or a signal still needs it.',
    'Sources/iPhone/AlarmEditor.swift':
        'New design; the same save and delete logic; the app is called Lumenoir; 0.9.9: the optional switch '
        '"Indirect method after the alarm" (a UI-only preference, off by default).',
    'Sources/iPhone/SignalReadinessView.swift':
        'New design; the same permission step; the app is called Lumenoir; 0.9.9: shown as a clear cover.',
    'Sources/iPhone/SettingsView.swift':
        'New design; language row; 3-20 second control; the sound library row is removed from the page; '
        'the app is called Lumenoir; 0.9.9: the living forest behind the same cards.',
    'Sources/iPhone/SoundLibraryView.swift':
        'New design; the library is opened from the sound picker; the app is called Lumenoir; 0.9.9: three groups, '
        'the Lumenoir melodies, adding from Files through the system document picker, deleting with a confirmation, '
        'renaming.',
    'Sources/iPhone/JournalView.swift':
        'New design; the same save and delete calls; the app is called Lumenoir; 0.9.9: shown as clear covers.',
    'Sources/Platform/AppModel.swift':
        '0.9.9, three small additions recorded under "engine_changed": renameVoice (only the name of a sound '
        'changes), addBuiltInSound (a Lumenoir melody joins the sound list without becoming the chosen sound), '
        'and importMelody no longer refuses while the quiet rain plays (importing is file work only). '
        'Signals, the queue, the stop deadlines and the night sound are untouched.',
    'Resources/iOSAssets.xcassets/AppIcon.appiconset/AppIcon.png':
        'The Lumenoir icon: the strict sign the user chose on 17 Nov 2026 (1024 px, opaque RGB).',
    'Resources/WatchAssets.xcassets/AppIcon.appiconset/AppIcon.png':
        'The Lumenoir icon on the watch: the same strict sign (1024 px, opaque RGB).',
    'Sources/iPhone/JournalVoiceComposer.swift': 'New design; the same recording calls.',
    'Config/Base.xcconfig': 'Version 0.9.9 (28).',
    'Config/iOS-Info.plist':
        'English as the base language, the list of languages, the Poiret One font; '
        'the name under the icon and in the permission texts is Lumenoir.',
    'Config/Watch-Info.plist': 'English as the base language, the list of languages; the name Lumenoir.',
    'Luma.xcodeproj/project.pbxproj': 'Regenerated: new source files, font, images and language folders.',
    'scripts/project-graph.json': 'Regenerated together with the project.',
    'scripts/generate_project.py':
        'Adds the font and the language folders to the project; 0.9.9: the four Lumenoir melodies.',
    'scripts/check-static.py':
        'Expects four fonts and the 3-20 second range; 0.9.9: checks the format of the four Lumenoir melodies.',
    'scripts/check-finite-queue-on-mac.swift':
        'Queue harness: one new scenario (20 seconds accepted, 21 refused); the invalid sample 11 became 21.',
}


# 0.9.9: files of the signal engine that were changed on purpose. Each is pinned by its hash.
ENGINE_CHANGES = ['Sources/Platform/AppModel.swift']


def digest(path):
    data = path.read_bytes()
    mode = 'lf-text' if path.suffix.lower() in TEXT_SUFFIXES else 'raw'
    if mode == 'lf-text':
        data = data.replace(b'\r\n', b'\n')
    return mode, hashlib.sha256(data).hexdigest()


def listing(root):
    found = {}
    for path in sorted(root.rglob('*')):
        if not path.is_file():
            continue
        relative = path.relative_to(root).as_posix()
        if any(part in SKIP_PARTS for part in path.relative_to(root).parts) or relative in SKIP_FILES:
            continue
        if not relative.startswith(SCOPE):
            continue
        found[relative] = path
    return found


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    base = Path(sys.argv[1]).resolve()
    if not (base / 'Package.swift').is_file():
        raise SystemExit('Not a Luma folder: %s' % base)
    ours, theirs = listing(ROOT), listing(base)
    unchanged, changed, added = [], {}, []
    for relative, path in ours.items():
        if relative not in theirs:
            added.append(relative)
            continue
        mode, value = digest(path)
        if digest(theirs[relative]) == (mode, value):
            unchanged.append({'path': relative, 'hash_mode': mode, 'sha256': value})
        else:
            if relative not in REASONS:
                raise SystemExit('Changed without a recorded reason: %s' % relative)
            changed[relative] = REASONS[relative]
    removed = sorted(set(theirs) - set(ours))
    stale = sorted(set(REASONS) - set(changed))
    if stale:
        raise SystemExit('A reason is recorded for a file that is not changed: %s' % ', '.join(stale))
    # 0.9.9: a file of the signal engine that was changed on purpose is pinned to its new content,
    # so any further edit of it is caught exactly as an edit of an unchanged file would be.
    engine_changed = []
    for relative in ENGINE_CHANGES:
        if relative not in changed:
            raise SystemExit('Recorded as an engine change but not changed: %s' % relative)
        mode, value = digest(ours[relative])
        engine_changed.append({'path': relative, 'hash_mode': mode, 'sha256': value,
                               'base_sha256': digest(theirs[relative])[1], 'reason': REASONS[relative]})
    manifest = {'schema': 2, 'base': '0.9.7 (23)', 'version': '0.9.9 (28)',
                'text_normalization': 'CRLF to LF only', 'binary_normalization': 'none',
                'unchanged': unchanged, 'engine_changed': engine_changed,
                'changed': changed, 'added': added, 'removed': removed}
    (ROOT / 'Docs/unchanged-since-0.9.7.json').write_text(
        json.dumps(manifest, ensure_ascii=False, indent=1) + '\n', encoding='utf-8', newline='\n')
    print('Unchanged: %d, changed: %d, added: %d, removed: %d.'
          % (len(unchanged), len(changed), len(added), len(removed)))


if __name__ == '__main__':
    main()
