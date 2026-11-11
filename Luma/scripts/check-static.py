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
check(len(root['targets'])==1,'Exactly one iPhone app target')
for uid in root['targets']:
    target=objects[uid]; swift=[]
    for phase_id in target['buildPhases']:
        phase=objects[phase_id]
        if phase['isa']=='PBXSourcesBuildPhase':
            swift += [files[objects[f]['fileRef']] for f in phase['files']]
    check(sum('@main' in p.read_text() for p in swift)==1,f"One entry point in {target['name']}")
    check(len(swift)==len(set(swift)),f"No duplicate source membership in {target['name']}")
    expected=set((ROOT/'Sources/LumaCore').glob('*.swift'))|set((ROOT/'Sources/Platform').glob('*.swift'))
    expected|=set((ROOT/'Sources/iPhone').glob('*.swift'))
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
notifications=(ROOT/'Sources/Platform/NotificationService.swift').read_text(encoding='utf-8-sig')
check('UNNotificationRequest(' in notifications and 'UNTimeIntervalNotificationTrigger' in notifications
      and 'repeats: false' in notifications, 'Short cues use nonrepeating system notification triggers')
check('UNNotificationSound(named:' in notifications and 'content.interruptionLevel = .active' in notifications,
      'Finite custom sound and ordinary notification delivery configured')
check('defaultCritical' not in notifications and 'ringtoneSound' not in notifications,
      'No critical-alert or looping ringtone substitution')
service=(ROOT/'Sources/iPhone/SystemAlarmService.swift').read_text(encoding='utf-8-sig')
check(not re.search(r'Task\.sleep|Timer\.|asyncAfter|beginBackgroundTask|BGTaskScheduler', service),
      'Cue completion has no app timer or background execution dependency')
check('inFlightID' in service and 'cancelAllRequested' in service and 'bootstrapTask' in service,
      'Queue admission, durable cancellation and concurrent bootstrap recovery are present')
core='\n'.join(p.read_text() for p in (ROOT/'Tests/LumaCoreTests').glob('*.swift'))
test_count=len(re.findall(r'func test\w+\(',core))
check(test_count >= 107,f'{test_count} XCTest scenarios are present (not executed by this script)')
check((ROOT/'scripts/check-finite-queue-on-mac.swift').is_file(), 'Native queue integration harness included')
check((ROOT/'Resources/Manrope-LICENSE.txt').is_file(), 'Font license included')
import wave
for n in [4,8,15]:
    with wave.open(str(ROOT/f'Resources/luma-tone-{n}.wav'),'rb') as w:
        check(w.getnframes()/w.getframerate()==n and w.getnchannels()==1 and w.getsampwidth()==2, f'Finite PCM melody: {n} seconds')
        if n == 4:
            raw=w.readframes(w.getnframes()); samples=struct.unpack('<'+'h'*(len(raw)//2),raw)
            peak=max(map(abs,samples))
            check(peak>1000 and peak<32767 and abs(samples[0])<=1 and abs(samples[-1])<=1,
                  'Four-second base sound is audible, unclipped and starts/ends at zero')
            check(max(map(abs,samples[-100:]))<peak*0.01, 'Base sound has a smooth quiet tail')
for name in ['iOS']:
    info=plistlib.loads((ROOT/f'Config/{name}-Info.plist').read_bytes())
    check(len(info['UIAppFonts'])==3 and all((ROOT/'Resources'/f).exists() for f in info['UIAppFonts']), f'Bundled Cyrillic fonts: {name}')
    ent=plistlib.loads((ROOT/f'Config/{name}.entitlements').read_bytes())
    check('com.apple.developer.usernotifications.time-sensitive' not in ent, f'Ordinary notification capabilities: {name}')
for path in ['scripts/check-on-mac.sh', 'Sources/LumaCore/RealtimeREMEngine.swift',
             'Sources/iPhone/SystemAlarmService.swift', 'Sources/LumaCore/iPhoneOnlyMigration.swift']:
    check((ROOT/path).is_file(),f'Delivery file exists: {path}')
check('NSAlarmKitUsageDescription' in plistlib.loads((ROOT/'Config/iOS-Info.plist').read_bytes()), 'AlarmKit purpose string included')
check('audio' in plistlib.loads((ROOT/'Config/iOS-Info.plist').read_bytes())['UIBackgroundModes'], 'Genuine audio background mode configured')
check('if #available(iOS 26.0, *)' in (ROOT/'Sources/iPhone/LegacyAlarmCleanup.swift').read_text(), 'Legacy AlarmKit cleanup availability gated for older iOS')
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
for mode in ['Debug', 'Release']:
    check(target_ids[('Luma', mode)] == prefix, f'Stable iPhone bundle identifier in {mode}')
    check(not any(o['isa']=='PBXCopyFilesBuildPhase' for o in objects.values()), 'No embedded Watch app phase')
check(bool(re.search(r'^CODE_SIGN_STYLE\s*=\s*Automatic\s*$', base, re.M)), 'Automatic signing remains enabled')
info=plistlib.loads((ROOT/'Config/iOS-Info.plist').read_bytes())
check('NSHealthUpdateUsageDescription' not in info, 'No workout-write permission requested')
ent=plistlib.loads((ROOT/'Config/iOS.entitlements').read_bytes())
check('com.apple.developer.healthkit.background-delivery' not in ent, 'No watch research background delivery entitlement')
check(not (ROOT/'Sources/Watch').exists(), 'Watch application source removed')
check(not (ROOT/'Sources/Platform/WatchBridge.swift').exists(), 'WatchConnectivity bridge removed')
check(not (ROOT/'Sources/iPhone/ResearchPhoneLink.swift').exists(), 'Workout session mirror removed')
check(not (ROOT/'Config/Watch-Info.plist').exists(), 'Watch companion Info.plist removed')
check(not (ROOT/'Config/Watch.entitlements').exists(), 'Watch entitlements removed')
check(not (ROOT/'Resources/WatchAssets.xcassets').exists(), 'Watch app icon catalog removed')
check(len(list((ROOT/'Luma.xcodeproj/xcshareddata/xcschemes').glob('*.xcscheme')))==1, 'Only iPhone shared scheme remains')
active='\n'.join(p.read_text() for p in (ROOT/'Sources').rglob('*.swift'))
check('AlarmManager.shared.schedule' not in active and 'manager.schedule(' not in active,
      'No new AlarmKit alarms can be scheduled by this release')
check('AlarmKitSoundBuilder' not in active, 'Unreliable AlarmKit sound path is removed')
delegate=(ROOT/'Sources/iPhone/LumaNotificationDelegate.swift').read_text()
check('completionHandler([.sound, .banner, .list])' in delegate and 'AVAudioPlayer' not in delegate.split('final class')[1],
      'Foreground delegates sound to iOS exactly once without a second audio player')
check('@UIApplicationDelegateAdaptor(LumaNotificationDelegate.self)' in (ROOT/'Sources/iPhone/LumaApp.swift').read_text(),
      'Notification delegate is installed during application launch')
sound=(ROOT/'Sources/iPhone/FiniteCueSoundBuilder.swift').read_text()
check('88200' in sound and '22050' in sound and 'renderFade' in sound and 'completeUntilFirstUserAuthentication' in sound,
      'Custom cue copies are finite, faded PCM and accessible after screen lock')
check('useNotificationDelivery()' in (ROOT/'Sources/LumaCore/iPhoneOnlyMigration.swift').read_text(),
      'Saved alarms migrate to finite notification delivery without changing the planner')
check(not re.search(r'\bimport\s+(?:WatchKit|WatchConnectivity)\b|\bWCSession\.',active), 'No direct Watch runtime imports or session access')
check('HKWorkoutSession' not in active, 'No live workout mirroring dependency')
ui='\n'.join(p.read_text() for p in (ROOT/'Sources/iPhone').glob('*.swift'))
check('ForEach(SignalOutput.allCases)' not in ui and 'watchStatus' not in ui, 'No custom Watch routing or connection controls')
workflow=(ROOT.parent/'.github/workflows/ios-build.yml').read_text()
check('check-finite-queue-on-mac.sh' in workflow, 'CI compiles and executes native queue regression harness')
check('check-preserved-sources.py' in workflow, 'CI verifies preserved planner, data and resources')
for target_id in root['targets']:
    resources=[objects[phase] for phase in objects[target_id]['buildPhases'] if objects[phase]['isa']=='PBXResourcesBuildPhase']
    bundled=[files[objects[item]['fileRef']].name for phase in resources for item in phase['files']]
    check('luma-tone-4.wav' in bundled, 'Four-second tone belongs to the app resource build phase')
check('generic/platform=watchOS' not in workflow and '-scheme "Luma Watch"' not in workflow, 'CI builds iPhone only')
check('test ! -d "$LUMA_APP/Watch"' in workflow, 'IPA packaging rejects a bundled Watch app')
engine = (ROOT/'Sources/LumaCore/RealtimeREMEngine.swift').read_text()
check('asleepREM' not in engine and 'HealthKit' not in engine.split('public struct RealtimeREMEngine')[1],
      'Live REM engine has no HealthKit sleep-stage dependency')
print(f'PASS: {len(checks)} structural checks. Swift compilation and device behavior are NOT verified.')
(ROOT/'Docs').mkdir(exist_ok=True)
(ROOT/'Docs/static-checks.json').write_text(json.dumps({'kind':'structural-only','swift_compiled':False,'xctest_executed':False,'device_tests_executed':False,'checks':checks},ensure_ascii=False,indent=2))
