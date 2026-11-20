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
#      project.pbxproj is NEVER merged: when the stash pop conflicts
#      (it does whenever the remote pbxproj changed the same regions,
#      i.e. every new-file commit), the script heals it itself — abort
#      the merge, drop the leftover stash, take the remote pbxproj.
#      The cost is the team selection, which lives in the discarded
#      copy; re-select it once in Xcode for phone builds. The same
#      heal runs at startup for a conflict an earlier run left behind.
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
#
# Heal a conflicted project.pbxproj by taking the remote version.
# Only ever called for that one file: any other unmerged file stops
# the script instead. The team selection is lost with the discarded
# copy — the note says so, and the simulator does not need it.
heal_pbxproj_conflict() {
  # A plain `git pull` conflict leaves MERGE_HEAD, so abort that too;
  # a `git stash pop` conflict does NOT (modern git leaves unmerged
  # index entries with no merge state), so the abort is skipped there
  # and the line below does the resolving. Plain `git checkout --`
  # refuses an unmerged path; `git checkout HEAD --` takes HEAD's
  # version and clears the unmerged stages.
  if git rev-parse -q --verify MERGE_HEAD >/dev/null; then
    git merge --abort
  fi
  if [ -n "$(git stash list)" ] \
     && [ "$(git stash show --name-only 'stash@{0}' | sort -u)" = "FinalWhistle.xcodeproj/project.pbxproj" ]; then
    git stash drop
  fi
  git checkout HEAD -- FinalWhistle.xcodeproj/project.pbxproj
  echo "project.pbxproj was conflicted; took the remote version. If you build for a real phone, re-select your team once in Xcode (Signing & Capabilities) — the simulator does not need it." >&2
}

if git ls-files -u | grep -q .; then
  if [ -z "$(git ls-files -u | awk '{print $4}' | sort -u | grep -v '^FinalWhistle.xcodeproj/project.pbxproj$')" ]; then
    echo "Found a leftover project.pbxproj conflict; healing it."
    heal_pbxproj_conflict
  else
    echo "Unmerged files other than project.pbxproj; resolve them, then re-run." >&2
    git ls-files -u | awk '{print $4}' | sort -u >&2
    exit 1
  fi
fi

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
  if ! git stash pop; then
    echo "Stash pop conflicted; healing it the same way (remote pbxproj wins)." >&2
    heal_pbxproj_conflict
  fi
fi
echo "Pulled $(git rev-parse --short HEAD)."

# Secrets.swift holds the pfp upload API key and is gitignored, so a
# fresh clone does not have it — but it IS listed in project.pbxproj.
# Create an empty one from the template so the build never breaks for
# that reason; pfp upload reports "not configured" until the real key
# is pasted in. The file is untracked, so it never blocks a pull.
if [ ! -f FinalWhistle/Secrets.swift ]; then
  cp FinalWhistle/Secrets.example.swift FinalWhistle/Secrets.swift
  echo "Created an empty FinalWhistle/Secrets.swift — paste the pfp API key there to enable photo upload." >&2
fi

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
# Open the Simulator window. `open -a Simulator` fails with "Unable to
# find application named 'Simulator'" when LaunchServices has not
# registered it, and the single-path guess missed on this Mac too (the
# -d test failed even with the corrected Developer/Applications path),
# so search every likely home for it, then fall back to a Spotlight
# lookup by bundle ID. The GUI open is only for showing the window —
# the boot/install/launch below work without it — so never let it abort
# the run; if nothing is found, say exactly what was tried.
SIM_APP=""
for cand in \
    "$(xcode-select -p 2>/dev/null)/Applications/Simulator.app" \
    /Applications/Xcode.app/Contents/Developer/Applications/Simulator.app \
    "$HOME/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app" \
    /Applications/Xcode-beta.app/Contents/Developer/Applications/Simulator.app; do
    if [[ -d "$cand" ]]; then SIM_APP="$cand"; break; fi
done
if [[ -z "$SIM_APP" ]]; then
    SIM_APP=$(mdfind "kMDItemCFBundleIdentifier == 'com.apple.iphonesimulator'" 2>/dev/null | head -n 1)
fi
if [[ -n "$SIM_APP" ]]; then
    open "$SIM_APP" || echo "Warning: could not open $SIM_APP." >&2
else
    echo "Warning: Simulator.app not found (xcode-select: $(xcode-select -p 2>/dev/null)). The build/install/launch below still run; open Simulator from Xcode's Open Developer Tool menu to see the app." >&2
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
