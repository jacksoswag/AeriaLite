#!/usr/bin/env python3
"""Detach AeriaLite from Claude Code's menu-bar-items permission group.

macOS 26 groups menu bar items under the app that launched them. AeriaLite was
launched from Claude Code during development, so it was filed under
com.anthropic.claude-code, whose entry is isAllowed=false. This removes only
AeriaLite from that group. Claude Code's own permission is left denied, and no
permission is granted to anything: AeriaLite already has its own isAllowed=true
entry, which is what it falls back to.
"""
import plistlib, os, shutil, sys, subprocess, time

STRAY = {"com.jacksonadams.aerialite", "com.jacksonadams.AeriaLite"}
GROUP = "com.anthropic.claude-code"
P = os.path.expanduser("~/Library/Group Containers/group.com.apple.controlcenter"
                       "/Library/Preferences/group.com.apple.controlcenter.plist")

def bid(e):
    return (e or {}).get("bundle", {}).get("_0")

outer = plistlib.load(open(P, "rb"))
entries = plistlib.loads(outer["trackedApplications"])

changed = []
for e in entries:
    if not isinstance(e, dict) or bid(e.get("location")) != GROUP:
        continue
    keep = [m for m in e.get("menuItemLocations", []) if bid(m) not in STRAY]
    dropped = [bid(m) for m in e.get("menuItemLocations", []) if bid(m) in STRAY]
    if dropped:
        e["menuItemLocations"] = keep
        changed += dropped

if not changed:
    print("nothing to change; AeriaLite is not in Claude Code's group")
    sys.exit(0)

backup = P + ".bak-" + time.strftime("%Y%m%d%H%M%S")
shutil.copy2(P, backup)
outer["trackedApplications"] = plistlib.dumps(entries, fmt=plistlib.FMT_BINARY)
plistlib.dump(outer, open(P, "wb"), fmt=plistlib.FMT_BINARY)
print("removed from Claude Code's menu bar group:", ", ".join(changed))
print("backup:", backup)
subprocess.run(["killall", "cfprefsd"], stderr=subprocess.DEVNULL)
time.sleep(1)
subprocess.run(["killall", "ControlCenter"], stderr=subprocess.DEVNULL)
print("Control Center restarted. Relaunch AeriaLite.")
