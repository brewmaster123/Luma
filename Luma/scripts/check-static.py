#!/usr/bin/env python3
"""Structural checks only. Does not compile Swift, execute XCTest, or simulate watchOS."""
from pathlib import Path
import json
import re
import plistlib
import xml.etree.ElementTree as ET
import struct

ROOT = Path(__file__).resolve().parents[1]
checks = []
def check(condition, description):
    if not condition: raise AssertionError(description)
    checks.append(description)

# Parse the actual OpenStep project, independent of its JSON reference dump.
source = (ROOT/'Luma.xcodeproj/project.pbxproj').read_text()
source = re.sub(r'//[^\n]*', '', source)
tokens = re.findall(r'"(?:\\.|[^"\\])*"|[A-Za-z0-9_.$<>/-]+|[{}=();,]', source)
cursor = 0
def take():
    global cursor
    token = tokens[cursor]; cursor += 1
    return token
def value():
    token = take()
    if token == '{':
        result = {}
        while tokens[cursor] != '}':
            key = take(); key = json.loads(key) if key.startswith('"') else key
            assert take() == '='; result[key] = value(); assert take() == ';'
        take(); return result
    if token == '(':
        result = []
        while tokens[cursor] != ')': result.append(value()); assert take() == ','
        take(); return result
    if token.startswith('"'): return json.loads(token)
    return int(token) if token.isdigit() else token
project = value()
check(cursor == len(tokens), 'Xcode project parses as an OpenStep property list')
objects = project['objects']; root = objects[project['rootObject']]
graph = json.loads((ROOT/'scripts/project-graph.json').read_text())
check(graph['objects'] == objects, 'Actual Xcode objects match the recorded project graph')
files = {}
def visit(uid, parent=ROOT):
    obj=objects[uid]
    if obj.get('sourceTree') == 'BUILT_PRODUCTS_DIR': return
    path=parent/obj.get('path','')
    if obj['isa']=='PBXGroup':
        for child in obj['children']: visit(child,path)
    elif obj['isa']=='PBXFileReference':
        check(path.exists(), f'Referenced file exists: {path.relative_to(ROOT)}');files[uid]=path
visit(root['mainGroup'])
check(len(root['targets'])==2,'Exactly two native app targets')
for uid in root['targets']:
    target=objects[uid]; swift=[]
    for phase_id in target['buildPhases']:
        phase=objects[phase_id]
        if phase['isa']=='PBXSourcesBuildPhase':
            swift += [files[objects[f]['fileRef']] for f in phase['files']]
    check(sum('@main' in p.read_text() for p in swift)==1,f"One entry point in {target['name']}")
    check(len(swift)==len(set(swift)),f"No duplicate source membership in {target['name']}")
    expected=set((ROOT/'Sources/LumaCore').glob('*.swift'))|set((ROOT/'Sources/Platform').glob('*.swift'))
    expected|=set((ROOT/('Sources/iPhone' if target['name']=='Luma' else 'Sources/Watch')).glob('*.swift'))
    check(set(swift)==expected,f"Complete and isolated source membership in {target['name']}")
for path in sorted((ROOT/'Config').glob('*.plist'))+sorted((ROOT/'Config').glob('*.entitlements'))+[ROOT/'Resources/PrivacyInfo.xcprivacy']:
    data=plistlib.loads(path.read_bytes());check(isinstance(data,dict),f'Valid XML plist: {path.name}')
for scheme in (ROOT/'Luma.xcodeproj/xcshareddata/xcschemes').glob('*.xcscheme'):
    document=ET.parse(scheme)
    check(all(n.attrib['BlueprintIdentifier'] in objects for n in document.iter('BuildableReference')),f'Valid scheme target: {scheme.name}')
for catalog in (ROOT/'Resources').glob('*.xcassets'):
    metadata=json.loads((catalog/'AppIcon.appiconset/Contents.json').read_text())
    item=metadata['images'][0];png=(catalog/'AppIcon.appiconset'/item['filename']).read_bytes()
    width,height=struct.unpack('>II',png[16:24])
    check(png[:8]==b'\x89PNG\r\n\x1a\n' and (width,height)==(1024,1024),f'1024px icon: {catalog.name}')
    check(png[25]==2,f'Opaque RGB app icon: {catalog.name}')
notifications=(ROOT/'Sources/Platform/NotificationService.swift').read_text()
check(bool(re.search(r'repeats:\s*false', notifications)) and not re.search(r'repeats:\s*true', notifications),'Notification triggers are non-repeating in source')
core='\n'.join(p.read_text() for p in (ROOT/'Tests/LumaCoreTests').glob('*.swift'))
check(len(re.findall(r'func test\w+\(',core))==49,'49 XCTest scenarios are present (not executed by this script)')
preview=(ROOT/'Design/Interface-preview.html').read_text()
check(not re.search(r'<(?:script|link)[^>]+(?:src|href)=["\']https?://',preview),'Design preview has no remote scripts or stylesheets')
check('data:font/woff;base64,' in preview, 'Preview bundles its own Manrope font')
check((ROOT/'Resources/Manrope-LICENSE.txt').is_file(), 'Font license included')
import wave
for n in [4,8,15]:
    with wave.open(str(ROOT/f'Resources/luma-tone-{n}.wav'),'rb') as w:
        check(w.getnframes()/w.getframerate()==n and w.getnchannels()==1 and w.getsampwidth()==2, f'Finite PCM melody: {n} seconds')
for name in ['iOS','Watch']:
    info=plistlib.loads((ROOT/f'Config/{name}-Info.plist').read_bytes())
    check(len(info['UIAppFonts'])==3 and all((ROOT/'Resources'/f).exists() for f in info['UIAppFonts']), f'Bundled Cyrillic fonts: {name}')
    ent=plistlib.loads((ROOT/f'Config/{name}.entitlements').read_bytes())
    check('com.apple.developer.usernotifications.time-sensitive' not in ent, f'Ordinary notification capabilities: {name}')
for path in ['README.md','Docs/DESIGN.md','Docs/TECHNICAL-NOTES.md','Docs/DEVICE-TESTS.md','scripts/check-on-mac.sh']:
    check((ROOT/path).is_file(),f'Delivery file exists: {path}')
check('NSAlarmKitUsageDescription' in plistlib.loads((ROOT/'Config/iOS-Info.plist').read_bytes()), 'Alarm permission purpose string included')
check('audio' in plistlib.loads((ROOT/'Config/iOS-Info.plist').read_bytes())['UIBackgroundModes'], 'Genuine audio background mode configured')
check('if #available(iOS 26.0, *)' in (ROOT/'Sources/iPhone/PhoneAlarmService.swift').read_text(), 'AlarmKit availability gated for older iOS')
check((ROOT/'scripts/check-audio-on-mac.sh').is_file(), 'Actual AVFoundation import check included for CI')
base = (ROOT/'Config/Base.xcconfig').read_text()
prefixes = re.findall(r'^LUMA_BUNDLE_PREFIX\s*=\s*([^\s/]+)\s*$', base, re.M)
check(len(prefixes) == 1, 'Exactly one stable base bundle identifier')
prefix = prefixes[0]
check(bool(re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+){2,}', prefix)) and not prefix.startswith('com.example.'),
      'Bundle identifier is valid and does not use the unavailable example namespace')
target_ids = {}
for uid in root['targets']:
    target = objects[uid]
    for config in objects[target['buildConfigurationList']]['buildConfigurations']:
        item = objects[config]
        target_ids[(target['name'], item['name'])] = item['buildSettings']['PRODUCT_BUNDLE_IDENTIFIER'].replace('$(LUMA_BUNDLE_PREFIX)', prefix)
companion = plistlib.loads((ROOT/'Config/Watch-Info.plist').read_bytes())['WKCompanionAppBundleIdentifier'].replace('$(LUMA_BUNDLE_PREFIX)', prefix)
for mode in ['Debug', 'Release']:
    check(target_ids[('Luma Watch', mode)] == target_ids[('Luma', mode)] + '.watchkitapp', f'Watch bundle belongs to iPhone bundle in {mode}')
    check(companion == target_ids[('Luma', mode)], f'Watch companion matches installed iPhone identity in {mode}')
check(bool(re.search(r'^CODE_SIGN_STYLE\s*=\s*Automatic\s*$', base, re.M)), 'Automatic signing remains enabled')
print(f'PASS: {len(checks)} structural checks. Swift compilation and device behavior are NOT verified.')
(ROOT/'Docs/static-checks.json').write_text(json.dumps({'kind':'structural-only','swift_compiled':False,'xctest_executed':False,'device_tests_executed':False,'checks':checks},ensure_ascii=False,indent=2))
