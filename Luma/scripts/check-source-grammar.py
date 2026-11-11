#!/usr/bin/env python3
"""Optional portable grammar check. This is NOT swiftc, type checking or XCTest."""
from pathlib import Path
import json
import sys

ROOT = Path(__file__).resolve().parents[1]
local = ROOT / '.validation-tools/packages'
if local.is_dir():
    sys.path.insert(0, str(local))
from tree_sitter import Language, Parser
import tree_sitter_swift
import tree_sitter_bash
import yaml

swift = Parser(Language(tree_sitter_swift.language()))
bash = Parser(Language(tree_sitter_bash.language()))
results = []

def inspect(parser, code, label):
    tree = parser.parse(code)
    errors = []
    def visit(node):
        if node.type == 'ERROR' or node.is_missing:
            errors.append({'line': node.start_point.row + 1, 'column': node.start_point.column + 1,
                           'kind': node.type, 'text': code[node.start_byte:node.end_byte].decode('utf-8')[:160]})
        for child in node.children:
            visit(child)
    visit(tree.root_node)
    results.append({'file': label, 'errors': errors})

for path in sorted(ROOT.rglob('*.swift')):
    if not any(part.startswith('.') for part in path.relative_to(ROOT).parts):
        inspect(swift, path.read_bytes().removeprefix(b'\xef\xbb\xbf'), str(path.relative_to(ROOT)))
for path in sorted((ROOT / 'scripts').glob('*.sh')):
    inspect(bash, path.read_bytes().removeprefix(b'\xef\xbb\xbf'), str(path.relative_to(ROOT)))
workflow_path = ROOT.parent / '.github/workflows/ios-build.yml'
workflow = yaml.load(workflow_path.read_text(encoding='utf-8-sig'), Loader=yaml.BaseLoader)
assert 'on' in workflow and 'workflow_dispatch' in workflow['on']
assert workflow['permissions'] == {'contents': 'read'}
for step in workflow['jobs']['build']['steps']:
    if 'run' in step:
        inspect(bash, step['run'].encode(), 'workflow: ' + step['name'])
report = {'kind': 'tree-sitter-grammar-and-YAML-only', 'swift_compiled': False,
          'xctest_executed': False, 'physical_device_tested': False, 'files': results}
(ROOT / 'Docs/source-grammar-checks.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
failed = [item for item in results if item['errors']]
for item in failed:
    print(json.dumps(item, ensure_ascii=False))
print(f"{'FAIL' if failed else 'PASS'}: {len(results)} grammar inputs; YAML parsed. No Swift compilation or device validation.")
sys.exit(bool(failed))
