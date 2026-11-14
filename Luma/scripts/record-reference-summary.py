#!/usr/bin/env python3
"""Summarise checks that actually ran locally; CI fields deliberately stay pending."""
from pathlib import Path
import hashlib
import json

project = Path(__file__).resolve().parents[1]
experiment = project.parent
grammar = json.loads((project / "Docs/source-grammar-checks.json").read_text())
preserved = json.loads((project / "Docs/preserved-sources-checks.json").read_text())
report = {
    "version": "0.9.9", "build": 25,
    "kind": "isolated-reference-night-experiment",
    "basis": "Design Experiments/V.0.9.8-Night-Sky (0.9.8 build 24), itself based on V.0.9.7 (23)",
    "directory": str(experiment),
    "user_local_date": "2026-11-14",
    "checks": {
        "structural_checks_passed": 161,
        "grammar_inputs": len(grammar["files"]),
        "grammar_errors": sum(len(item["errors"]) for item in grammar["files"]),
        "source_integrity_regression_tests_passed": 13,
        "unchanged_preserved_inputs": len(preserved["files"]),
        "preserved_hashes_passed": preserved["passed"],
        "intentional_preserved_scope_changes": [
            "Sources/iPhone/PhoneRootView.swift", "scripts/generate_project.py"
        ],
        "UI_test_cases_configured_not_yet_executed": 7,
    },
    "ci_branch": "design/0.9.9-reference-night",
    "Xcode_build_verified": False, "native_UI_tests_executed": False,
    "native_screenshot_received": False, "CI_status": "pending",
    "physical_device_tests_executed": False, "production_ready": False,
    "installed": False, "bundle_ID": "com.sevchlenko.luma",
    "storage_formats_changed": False, "signing_configuration_changed": False,
    "existing_version_folders_changed": False,
    "visual_limitations": [
        "Times New Roman is measured as closest; original source font is not identified.",
        "SF Symbols and accessible minimum hit areas differ from illustration pixels.",
        "Uniform art crop and adaptive controls differ on taller aspect ratios.",
        "Clean background plate requires comparison against the actual simulator PNG."
    ],
}
for output in [experiment / "verification.json", project / "Docs/reference-native-checks.json"]:
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
(experiment / "PROGRESS.json").write_text(json.dumps({
    "version": "0.9.9 (25)", "phase": "native implementation and local checks complete; awaiting Xcode CI",
    "verified": False, "production_ready": False,
}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
excluded = {".validation-tools", ".build", "__pycache__", "build-logs", "build", "dist", ".git", "DerivedData"}
snapshot = []
for file in sorted(experiment.rglob("*")):
    relative = file.relative_to(experiment)
    if not file.is_file() or any(part in excluded for part in relative.parts):
        continue
    if relative.as_posix() == "source-sha256.json":
        continue
    snapshot.append({
        "path": relative.as_posix(), "hash_mode": "raw",
        "sha256": hashlib.sha256(file.read_bytes()).hexdigest(),
    })
(experiment / "source-sha256.json").write_text(json.dumps({
    "version": "0.9.9 (25)", "kind": "new-experiment-source-snapshot-not-baseline",
    "files": snapshot,
}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(f"Recorded local reference checks and {len(snapshot)} source inputs; CI remains pending.")
