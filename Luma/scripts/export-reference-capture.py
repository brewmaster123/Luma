"""Select the explicitly named real XCTest screenshot from xcresulttool's manifest."""
from pathlib import Path
import json
import shutil
import struct
import sys

exported=Path(sys.argv[1]).resolve()
destination=Path(sys.argv[2]).resolve()
destination.mkdir(parents=True,exist_ok=True)
marker='reference-night-capture'
manifests=list(exported.rglob('manifest.json'))
if not manifests:
    raise SystemExit('No xcresult attachment manifest was exported')

def strings(value):
    if isinstance(value,str):yield value
    elif isinstance(value,list):
        for item in value:yield from strings(item)
    elif isinstance(value,dict):
        for item in value.values():yield from strings(item)

matches=[]
def visit(value):
    if isinstance(value,dict):
        blob=json.dumps(value,ensure_ascii=False)
        if marker in blob:
            matches.append((len(blob),value))
        for child in value.values():visit(child)
    elif isinstance(value,list):
        for child in value:visit(child)

for manifest in manifests:visit(json.loads(manifest.read_text(encoding='utf8')))
chosen=None
for _,record in sorted(matches,key=lambda row:row[0]):
    for value in strings(record):
        if not value.lower().endswith('.png'):continue
        candidates=[exported/value,*exported.rglob(Path(value).name)]
        for candidate in candidates:
            candidate=candidate.resolve()
            if exported not in candidate.parents or not candidate.is_file():continue
            chosen=candidate;break
        if chosen:break
    if chosen:break
if chosen is None:
    raise SystemExit('The reference-night-capture attachment was not found; no substitute screenshot accepted')
data=chosen.read_bytes()
if data[:8]!=b'\x89PNG\r\n\x1a\n':raise SystemExit('Reference capture is not PNG')
width,height=struct.unpack('>II',data[16:24])
if width<320 or height<480:raise SystemExit('Reference capture has an unexpected viewport')
shutil.copyfile(chosen,destination/'native-night.png')
(destination/'capture.json').write_text(json.dumps({'source':'actual iOS Simulator XCUIScreen screenshot','attachmentName':marker,'launchArgument':'-reference-screenshot','uiReadiness':'foreground + existing Night controls verified by XCTest before attachment','animationTime':0,'moonAngleDegrees':0,'viewport':[width,height],'fixture':'one 07:00 weekday alarm, no services scheduled','welcomeSheet':False},indent=2),encoding='utf8')
print(f'Exported actual ready Night screen: {width} x {height}, {chosen.name}')
