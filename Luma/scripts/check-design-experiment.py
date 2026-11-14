#!/usr/bin/env python3
"""Read-only grammar and source-preservation checks for the isolated design copy.

This is not Swift type checking, XCTest, or a physical-device visual check.
"""
from pathlib import Path
import hashlib
import json
import sys

PROJECT = Path(__file__).resolve().parents[1]
EXPERIMENT = PROJECT.parent
BASIS = EXPERIMENT.parents[1] / "V.0.9.7"
sys.path.insert(0, str(PROJECT / ".validation-tools" / "packages"))
from tree_sitter import Language, Parser
import tree_sitter_swift

parser = Parser(Language(tree_sitter_swift.language()))
syntax_failures = []
swift_paths = sorted((PROJECT / "Sources").rglob("*.swift"))
for file in swift_paths:
    root = parser.parse(file.read_bytes()).root_node
    if root.has_error:
        syntax_failures.append(str(file.relative_to(PROJECT)))

panel = PROJECT / "Sources" / "iPhone" / "IndirectMethodView.swift"
other_swift = []
for file in swift_paths:
    if file == panel:
        continue
    basis = BASIS / "Luma" / file.relative_to(PROJECT)
    other_swift.append({
        "path": str(file.relative_to(PROJECT)).replace("\\", "/"),
        "unchanged": file.read_bytes() == basis.read_bytes(),
    })

text = panel.read_text(encoding="utf-8")
required = [
    "await model.stopIndirectMethod()",
    "await model.requestIndirectMethodStart()",
    "model.systemAlarms.acceptedLimitations",
    ".disabled(model.busy || model.systemAlarms.preparing)",
    ".disabled(model.indirectRunning || model.busy)",
    "await model.setIndirectInterval(minutes)",
    "ForEach(10...60, id: \\.self)",
    "model.systemAlarms.indirectRecords.first(where:",
    '.accessibilityIdentifier("indirect.help")',
    '.accessibilityIdentifier("indirect.interval")',
    '.accessibilityIdentifier("indirect.start")',
    '.accessibilityIdentifier("indirect.minutes")',
    '.accessibilityIdentifier("indirect.save")',
    "SignalReadinessView(continueTitle:",
    "IndirectHelpView().environmentObject(model)",
    "IndirectIntervalSheet().environmentObject(model)",
]
actions = [{"contract": token, "present": token in text} for token in required]
config = (PROJECT / "Config" / "Base.xcconfig").read_text(encoding="utf-8")
basis_config = (BASIS / "Luma" / "Config" / "Base.xcconfig").read_text(encoding="utf-8")
expected_config = basis_config.replace("MARKETING_VERSION = 0.9.7", "MARKETING_VERSION = 0.9.8").replace(
    "CURRENT_PROJECT_VERSION = 23", "CURRENT_PROJECT_VERSION = 24")
report = {
    "version": "0.9.8 (24)",
    "basis": "V.0.9.7 (23)",
    "kind": "grammar-and-preservation-only",
    "swift_sources_parsed": len(swift_paths),
    "syntax_failures": syntax_failures,
    "other_swift_sources": other_swift,
    "preserved_action_contracts": actions,
    "only_version_and_build_changed_in_Base_xcconfig": config == expected_config,
    "swift_compiled": False,
    "xctest_executed": False,
    "device_visuals_checked": False,
}
report["passed"] = not syntax_failures and all(r["unchanged"] for r in other_swift) and all(
    r["present"] for r in actions) and report["only_version_and_build_changed_in_Base_xcconfig"]
(PROJECT / "Docs" / "design-experiment-checks.json").write_text(
    json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
if not report["passed"]:
    raise SystemExit("FAIL: see Docs/design-experiment-checks.json")
print(f"PASS: {len(swift_paths)} Swift inputs parse, {len(other_swift)} other Swift sources match "
      f"V.0.9.7 byte-for-byte, {len(actions)} action contracts present; config only version/build changed.")

excluded = {".validation-tools", ".build", "__pycache__", "build-logs", "dist", ".git", "DerivedData"}
snapshot = []
for file in sorted(EXPERIMENT.rglob("*")):
    relative = file.relative_to(EXPERIMENT)
    if not file.is_file() or any(part in excluded for part in relative.parts):
        continue
    if relative.as_posix() in {"source-sha256.json", "verification.json"}:
        continue
    snapshot.append({"path": relative.as_posix(), "hash_mode": "raw", "sha256": hashlib.sha256(file.read_bytes()).hexdigest()})
(EXPERIMENT / "source-sha256.json").write_text(json.dumps({
    "version": "0.9.8 (24)", "kind": "isolated-experiment-input-snapshot-not-baseline", "files": snapshot
}, ensure_ascii=False, indent=2), encoding="utf-8")
