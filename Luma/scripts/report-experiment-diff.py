#!/usr/bin/env python3
"""Compare the isolated experiment to its read-only V.0.9.7 basis."""
from pathlib import Path
import json
import os

EXPERIMENT = Path(__file__).resolve().parents[2]
BASIS = EXPERIMENT.parents[1] / "V.0.9.7"
EXCLUDE = {".validation-tools", ".build", "__pycache__", "build-logs", "dist", ".git", "DerivedData"}

def paths(root):
    result = {}
    for folder, directories, filenames in os.walk(root):
        directories[:] = [name for name in directories if name not in EXCLUDE]
        for name in filenames:
            path = Path(folder) / name
            if name != ".DS_Store":
                result[path.relative_to(root).as_posix()] = path
    return result

before, after = paths(BASIS), paths(EXPERIMENT)
changed = [name for name in before.keys() & after.keys()
           if before[name].read_bytes() != after[name].read_bytes()]
report = {
    "basis": str(BASIS), "experiment": str(EXPERIMENT),
    "excluded_directory_names": sorted(EXCLUDE),
    "unchanged_files": len(before.keys() & after.keys()) - len(changed),
    "changed_files": sorted(changed),
    "added_files": sorted(after.keys() - before.keys()),
    "removed_files": sorted(before.keys() - after.keys()),
    "note": "source-sha256.json is an experiment snapshot; the inherited original snapshot is retained as basis-0.9.7-source-sha256.json. No original version file is written by this script."
}
report_path = EXPERIMENT / "Luma" / "Docs" / "experiment-diff.json"
report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
print(json.dumps(report, ensure_ascii=False, indent=2))
