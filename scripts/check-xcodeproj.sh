#!/bin/sh
# Fails if a build setting is set both in Glifftop.xcodeproj and in a Config/*.xcconfig.
# The project's value would win and silently override ours; remove it in Xcode
# (Build Settings ▸ select the row ▸ Delete). Read-only: never edits the project.
# Reads Xcode 27's project.xcproj (JSON5), which plutil converts to JSON, and checks every
# build-settings block in it (project, targets and per-configuration overrides).
# Uses Apple's /usr/bin/python3 (3.9), not whatever python3 is first on PATH.
set -eu

project=Glifftop.xcodeproj/project.xcproj
if [ ! -f "$project" ]; then
    echo "check-xcodeproj: $project not found; run from the repo root." >&2
    exit 1
fi

plutil -convert json -o - "$project" | /usr/bin/python3 -I -c '
import json, re, sys
from pathlib import Path

ours = set()
for config in sorted(Path("Config").glob("*.xcconfig")):
    for line in config.read_text().splitlines():
        match = re.match(r"\s*([A-Za-z_][A-Za-z0-9_]*)\s*(\[[^\]]*\])*\s*=", line)
        if match:
            ours.add(match.group(1))

duplicates = {}

def walk(node, where):
    """Record each of our settings found in any build-settings block under node."""
    if isinstance(node, list):
        for item in node:
            walk(item, where)
    elif isinstance(node, dict):
        if "name" in node:
            where = where + "/" + node["name"] if where != "project" else node["name"]
        for key, value in node.items():
            if key == "build-settings" and isinstance(value, dict):
                for setting in value:
                    name = setting.split("[", 1)[0]
                    if name in ours:
                        duplicates.setdefault(name, set()).add(where)
            else:
                walk(value, where)

walk(json.load(sys.stdin), "project")
for name, places in sorted(duplicates.items()):
    print("%s: set in Xcode (%s) and in Config/; delete it in Xcode" % (name, ", ".join(sorted(places))))
sys.exit(1 if duplicates else 0)
'
