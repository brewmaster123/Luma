#!/usr/bin/env python3
"""Record authorised visual changes in this new copy, retaining original preserved hashes.

Only the UI shell and project generator leave the preserved set. Their old expected hashes
remain in an explicit ledger, rather than being silently replaced by the current bytes.
"""
from pathlib import Path
import hashlib
import json
import importlib.util

root = Path(__file__).resolve().parents[1]
path = root / "Docs/preserved-sources.json"
manifest = json.loads(path.read_text(encoding="utf-8-sig"))
spec = importlib.util.spec_from_file_location("reference_integrity", root / "scripts/check-preserved-sources.py")
integrity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(integrity)
reasons = {
    "Sources/iPhone/PhoneRootView.swift": "Authorised exact-reference Night shell, real icon navigation, alarm UI and direct startup without IntroductionView.",
    "scripts/generate_project.py": "Authorised additional native reference scene/style source membership and an isolated XCTest UI target/scheme.",
}
retained = []
ledger = manifest.setdefault("reference_design_change_ledger", [])
known = {item["path"] for item in ledger}
for item in manifest["files"]:
    if item["path"] not in reasons:
        retained.append(item)
        continue
    if item["path"] not in known:
        ledger.append({
            **item,
            "expected_before_sha256": item["sha256"],
            "after_sha256": integrity.hash_content((root / item["path"]).read_bytes(), item["hash_mode"]),
            "reason": reasons[item["path"]],
        })
    manifest["intentional_changes"][item["path"]] = reasons[item["path"]]
manifest["files"] = retained
manifest["intentional_changes"]["Config/Base.xcconfig"] = "Isolated reference design version 0.9.9 (25); identity/signing unchanged."
manifest["reference_design_note"] = "Original expected hashes are retained for every unchanged file and in the explicit ledger for the two authorised changes. Earlier version manifests were not edited."
path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(f"Recorded {len(ledger)} authorised UI/generator changes; {len(retained)} original preserved hashes unchanged.")
