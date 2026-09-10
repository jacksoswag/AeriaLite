#!/usr/bin/env python3
"""Restore AeriaLite's menu bar icon when macOS has grouped it under another app.

macOS 26 files a status item under the application responsible for the process that
created it, and refuses to place items belonging to a group the user has not allowed
to add menu bar items. An installer or agent that launches AeriaLite therefore welds
it to that tool permanently: the grouping is stored by bundle id in trackedApplications
in the group.com.apple.controlcenter domain and survives relaunches by any other
parent, ControlCenter restarts, reinstalls and reboots.

This removes AeriaLite from every group that is not allowed. It grants nothing: no
isAllowed value is written, and AeriaLite's own record -- which macOS creates at
isAllowed=true -- is what it falls back to. Other applications' settings are untouched.

Usage:  python3 scripts/detach-menu-bar-group.py [--dry-run]
"""
import os
import plistlib
import shutil
import subprocess
import sys
import time

# AeriaLite's current identifier, plus the differently-cased one older builds used.
OURS = {"com.jacksonadams.aerialite", "com.jacksonadams.AeriaLite"}

PREFS = os.path.expanduser(
    "~/Library/Group Containers/group.com.apple.controlcenter"
    "/Library/Preferences/group.com.apple.controlcenter.plist"
)


def bundle_of(node):
    """trackedApplications wraps every identifier as {"bundle": {"_0": <id>}}."""
    if not isinstance(node, dict):
        return None
    return node.get("bundle", {}).get("_0")


def main():
    dry_run = "--dry-run" in sys.argv[1:]

    if not os.path.exists(PREFS):
        print("no menu bar grouping on this machine; nothing to repair")
        return 0

    outer = plistlib.load(open(PREFS, "rb"))
    if "trackedApplications" not in outer:
        print("no trackedApplications key; nothing to repair")
        return 0

    # The value is itself a binary plist, which is why a text search of the outer
    # file reports the bundle id as absent.
    entries = plistlib.loads(outer["trackedApplications"])

    detached = []
    for entry in entries:
        if not isinstance(entry, dict) or "menuItemLocations" not in entry:
            continue
        owner = bundle_of(entry.get("location"))
        if owner in OURS or entry.get("isAllowed"):
            continue                      # our own record, or a group already allowed
        members = entry["menuItemLocations"]
        keep = [m for m in members if bundle_of(m) not in OURS]
        if len(keep) != len(members):
            detached.append(owner)
            entry["menuItemLocations"] = keep

    if not detached:
        print("AeriaLite is not grouped under a denied application; nothing to repair")
        return 0

    print("detaching AeriaLite from: " + ", ".join(str(d) for d in detached))
    if dry_run:
        print("--dry-run: nothing written")
        return 0

    backup = PREFS + ".bak-" + time.strftime("%Y%m%d%H%M%S")
    shutil.copy2(PREFS, backup)
    outer["trackedApplications"] = plistlib.dumps(entries, fmt=plistlib.FMT_BINARY)
    plistlib.dump(outer, open(PREFS, "wb"), fmt=plistlib.FMT_BINARY)
    print("backup: " + backup)

    # cfprefsd serves a cached copy and ControlCenter reads the grouping at launch,
    # so both have to be restarted for the change to take effect.
    subprocess.run(["killall", "cfprefsd"], stderr=subprocess.DEVNULL)
    time.sleep(1)
    subprocess.run(["killall", "ControlCenter"], stderr=subprocess.DEVNULL)
    print("Control Center restarted; open AeriaLite again")
    return 0


if __name__ == "__main__":
    sys.exit(main())
