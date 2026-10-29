#!/usr/bin/env python3

# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

"""Generate the LDTXApp test plans from XcodeGen's target identifiers."""

import argparse
import json
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / "LDTX.xcodeproj"
ALL_TARGETS = (
    "LDTXUtilsTests",
    "LDTXOutputTests",
    "LDTXAppUIComponentTests",
    "LDTXModuleTests",
    "LDTXAppXpcTests",
)
UI_TARGET = "LDTXAppUIComponentTests"
PLANS = (
    ("AllTests", "FEA43110-E2AE-4D60-B02F-7C7FD12E7590", ALL_TARGETS, None),
    ("UIShard1", "FEA43111-E2AE-4D60-B02F-7C7FD12E7591", (UI_TARGET,), "1"),
    ("UIShard2", "FEA43112-E2AE-4D60-B02F-7C7FD12E7592", (UI_TARGET,), "2"),
)


def target_identifiers():
    project_file = PROJECT / "project.pbxproj"
    if not project_file.is_file():
        raise ValueError("Generate LDTX.xcodeproj with 'xcodegen generate' first")
    data = subprocess.check_output(
        ["plutil", "-convert", "json", "-o", "-", str(project_file)]
    )
    project = json.loads(data)
    identifiers = {}
    for identifier, target in project["objects"].items():
        if target.get("isa") != "PBXNativeTarget" or target.get("name") not in ALL_TARGETS:
            continue
        name = target["name"]
        if name in identifiers:
            raise ValueError(f"Duplicate Xcode target: {name}")
        identifiers[name] = identifier
    missing = set(ALL_TARGETS) - identifiers.keys()
    if missing:
        raise ValueError(f"Missing Xcode targets: {', '.join(sorted(missing))}")
    return identifiers


def plan_data(plan_id, targets, shard, identifiers):
    options = {"codeCoverage": False}
    if shard is not None:
        options["environmentVariableEntries"] = [
            {"key": "LDTX_UI_TEST_SHARD", "value": shard, "isEnabled": True}
        ]
    return {
        "configurations": [{"id": plan_id, "name": "Default", "options": {}}],
        "defaultOptions": options,
        "testTargets": [
            {
                "target": {
                    "containerPath": "container:LDTX.xcodeproj",
                    "identifier": identifiers[name],
                    "name": name,
                }
            }
            for name in targets
        ],
        "version": 1,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="check plans without writing")
    args = parser.parse_args()
    try:
        identifiers = target_identifiers()
        stale = []
        for name, plan_id, targets, shard in PLANS:
            path = ROOT / "Tests" / f"{name}.xctestplan"
            expected = plan_data(plan_id, targets, shard, identifiers)
            if args.check:
                try:
                    actual = json.loads(path.read_text(encoding="utf-8"))
                except (OSError, json.JSONDecodeError):
                    actual = None
                if actual != expected:
                    stale.append(path.relative_to(ROOT))
            else:
                path.write_text(json.dumps(expected, indent=2) + "\n", encoding="utf-8")
                print(f"Generated {path.relative_to(ROOT)}")
        if stale:
            for path in stale:
                print(f"Test plan is missing or out of date: {path}", file=sys.stderr)
            print("Run: python3 ci_scripts/generate-test-plans.py", file=sys.stderr)
            return 1
    except (OSError, subprocess.CalledProcessError, ValueError, KeyError) as error:
        print(f"Cannot generate test plans: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
