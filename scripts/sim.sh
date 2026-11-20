#!/bin/bash
# Pull latest, build for the simulator, and launch it — one command.
# Run on a Mac with Xcode 27.2 or later, from the repo root:
#   bash scripts/sim.sh
# (bash works even on a fresh clone where the script is not executable yet.)
#
# This removes the three manual steps after a pull:
#   1. Resetting the project — Xcode rewrites project.pbxproj locally
#      (reordering sections), which used to abort `git pull`. If the
#      local diff has no signing changes, this script discards it and
#      pulls. If it DOES contain a DEVELOPMENT_TEAM / CODE_SIGN change,
#      it stashes the file, pulls, and pops the stash back.
#   2. Adding the team — not needed for the simulator at all. Simulator
#      builds run with signing off (CODE_SIGNING_ALLOWED=NO), so there
#      is no "requires a development team" step. The team only matters
#      for a real phone; that is scripts/phone.sh.
#   3. Building and launching by hand — this script picks a simulator
#      (the booted one, else the newest available iPhone), downloads
#      the iOS runtime first if it is missing, builds, installs, and
#      launches the app.
set -euo pipefail
cd "$(dirname "$0")/.."
APP=FinalWhistle
BUNDLE=app.final-whistle
OUT=DerivedData.noindex
LOG=$OUT/sim.log; mkdir -p "$OUT"
fail() { grep -E 'error:|ERROR:|FailureReason' "$LOG" | sort -u | head -20 || true; echo "$1 failed. Log: $LOG" >&2; exit 1; }

# 1. Pull, handling Xcode's local rewrite of project.pbxproj.
STASHED=""
if ! git diff --quiet -- FinalWhistle.xcodeproj/project.pbxproj; then
  if git diff -- FinalWhistle.xcodeproj/project.pbxproj | grep -qE 'DEVELOPMENT_TEAM|CODE_SIGN'; then
    echo "project.pbxproj has local signing changes; stashing them for the pull."
    git stash push -- FinalWhistle.xcodeproj/project.pbxproj
    STASHED=1
  else
    echo "Discarding Xcode's local reorder of project.pbxproj."
    git checkout -- FinalWhistle.xcodeproj/project.pbxproj
  fi
fi
git pull --ff-only origin main || { echo "git pull failed (local changes elsewhere?). Resolve them, then re-run." >&2; exit 1; }
if [ -n "$STASHED" ]; then
  git stash pop || echo "Stash pop conflicted; your signing change is in the stash (git stash list)." >&2
fi
echo "Pulled $(git rev-parse --short HEAD)."

# 2. Make sure an iOS simulator runtime exists.
if ! xcrun simctl list runtimes 2>/dev/null | grep -qi 'iOS.*available'; then
  echo "No iOS simulator runtime found; downloading it (this takes a while)..."
  xcodebuild -downloadPlatform iOS
fi

# 3. Pick a simulator: the booted iPhone if there is one, else the newest
# available iPhone. Boot it and show the Simulator app.
DEVICE=$(xcrun simctl list devices --json | python3 -c '
import json, sys
cands = []
for runtime, devs in json.load(sys.stdin)["devices"].items():
    for d in devs:
        if d.get("isAvailable") and "iPhone" in d.get("name", ""):
            cands.append((runtime, d))
if not cands:
    sys.exit(1)
booted = [c for c in cands if c[1].get("state") == "Booted"]
pool = booted if booted else cands
# Newest runtime first, then iPhone 17, then any iPhone.
pool.sort(key=lambda c: (c[0], "17" in c[1]["name"]), reverse=True)
print(pool[0][1]["udid"])
' 2>/dev/null) || { echo "No available iPhone simulator found." >&2; exit 1; }
DEVICE_NAME=$(xcrun simctl list devices --json | python3 -c "
import json, sys
for devs in json.load(sys.stdin)['devices'].values():
    for d in devs:
        if d['udid'] == '$DEVICE':
            print(d['name']); sys.exit()
")
xcrun simctl boot "$DEVICE" 2>/dev/null || true
# Open the Simulator window by its full path inside the selected Xcode.
# `open -a Simulator` fails with "Unable to find application named
# 'Simulator'" when LaunchServices has not registered it (seen
# 2026-11-20 after the Xcode 27.2 runtime download), and under set -e
# that killed the whole script before the build. The GUI open is only
# for showing the window — the boot/install/launch below work without
# it — so never let it abort the run. NOTE: xcode-select -p already
# ends in Contents/Developer, so the app is at
# $DEVELOPER_DIR/Applications/Simulator.app — the 3b7d237 version used
# ../Applications (Contents/Applications, does not exist) and fell
# straight back to the broken `open -a`.
SIM_APP="$(xcode-select -p)/Applications/Simulator.app"
if [[ -d "$SIM_APP" ]]; then
    open "$SIM_APP" || echo "Warning: could not open $SIM_APP; open it manually from Xcode if you want the window." >&2
else
    open -a Simulator || echo "Warning: could not open the Simulator app; open it manually from Xcode if you want the window." >&2
fi
echo "Simulator: $DEVICE_NAME ($DEVICE)"

# 4. Build for the simulator, signing off (no team needed).
xcodebuild -scheme "$APP" -destination "platform=iOS Simulator,id=$DEVICE" \
  -derivedDataPath "$OUT" build CODE_SIGNING_ALLOWED=NO >>"$LOG" 2>&1 || fail Build

# 5. Install over the old copy and launch.
xcrun simctl install "$DEVICE" \
  "$OUT/Build/Products/Debug-iphonesimulator/$APP.app" >>"$LOG" 2>&1 || fail Install
PID=$(xcrun simctl launch "$DEVICE" "$BUNDLE" 2>>"$LOG") || fail Launch
echo "$APP is running on $DEVICE_NAME (pid ${PID##*: })."
