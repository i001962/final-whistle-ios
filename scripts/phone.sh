#!/bin/bash
# Pull latest, build, install over the old copy, launch, and confirm it
# stays running — one command.
# Run on a Mac with Xcode 27.2 or later, from the repo root:
#   bash scripts/phone.sh
# (bash works even on a fresh clone where the script is not executable yet.)
# The phone must be connected by cable, unlocked, trusted, and in Developer Mode.
# NOTE: the phone is on iOS 27.2.1. The Xcode SDK on the Mac must be 27.2.1 or
# newer to install onto it; if Xcode 27.2 ships only the 27.2 SDK, update Xcode
# first. IPHONEOS_DEPLOYMENT_TARGET stays at 26.0, which is lower than the phone.
#
# The pull handles Xcode's local rewrite of project.pbxproj the same way
# sim.sh does: a reorder-only diff is discarded. But unlike the simulator,
# a phone build NEEDS the development team, and the team lives in that
# same file — so before discarding it the script saves the team id and
# passes it back to xcodebuild as an override. The team survives every
# pull, even when the remote pbxproj changed. If no team has ever been
# selected, the build fails with "requires a development team": select
# it once in Xcode (target FinalWhistle > Signing & Capabilities), then
# re-run this script and it keeps it from then on.
set -euo pipefail
cd "$(dirname "$0")/.."
APP=FinalWhistle BUNDLE=app.final-whistle OUT=DerivedData.noindex
LOG=$OUT/phone.log; mkdir -p "$OUT"
fail() { grep -E 'error:|ERROR:|FailureReason' "$LOG" | sort -u | head -20 || true; echo "$1 failed. Log: $LOG" >&2; exit 1; }

# 1. Pull, handling Xcode's local rewrite of project.pbxproj.
#
# The development team is read from scripts/.development-team first
# (a local file phone.sh saves the first time it sees a team, so the
# team survives every pull even if project.pbxproj ever loses it
# again), and otherwise from the local pbxproj — the team is committed
# in the repo's pbxproj now, so the pull brings it and the extraction
# below finds it. A team found in the pbxproj is saved to the file so
# the next run does not depend on the pbxproj at all. If no team is
# found anywhere, the build fails with "requires a development team":
# select it once in Xcode (target FinalWhistle > Signing &
# Capabilities), then re-run and this script saves it from then on.
TEAM_FILE=scripts/.development-team
if [ -s "$TEAM_FILE" ]; then
  TEAM=$(tr -d '[:space:]' < "$TEAM_FILE")
else
  TEAM=$(grep -m1 'DEVELOPMENT_TEAM' FinalWhistle.xcodeproj/project.pbxproj 2>/dev/null | sed -E 's/.*DEVELOPMENT_TEAM = ([A-Za-z0-9]+);.*/\1/' || true)
  TEAM=$(echo "$TEAM" | tr -d '[:space:]')
  if [ -n "$TEAM" ]; then
    echo "$TEAM" > "$TEAM_FILE"
  fi
fi
if [ -n "$TEAM" ]; then
  echo "Development team $TEAM; it will be passed to the build."
else
  echo "No development team in the project yet. If the build fails with 'requires a development team', select it once in Xcode (target FinalWhistle > Signing & Capabilities), then re-run." >&2
fi

# Heal a conflicted project.pbxproj by taking the remote version.
# Only ever called for that one file: any other unmerged file stops
# the script instead.
heal_pbxproj_conflict() {
  if git rev-parse -q --verify MERGE_HEAD >/dev/null; then
    git merge --abort
  fi
  if [ -n "$(git stash list)" ] \
     && [ "$(git stash show --name-only 'stash@{0}' | sort -u)" = "FinalWhistle.xcodeproj/project.pbxproj" ]; then
    git stash drop
  fi
  git checkout HEAD -- FinalWhistle.xcodeproj/project.pbxproj
  echo "project.pbxproj was conflicted; took the remote version. The saved team ($TEAM) is still passed to the build." >&2
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

if ! git diff --quiet -- FinalWhistle.xcodeproj/project.pbxproj; then
  echo "Discarding Xcode's local rewrite of project.pbxproj (the team is saved above)."
  git checkout -- FinalWhistle.xcodeproj/project.pbxproj
fi
git pull --ff-only origin main || { echo "git pull failed (local changes elsewhere?). Resolve them, then re-run." >&2; exit 1; }
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

# 2. Pick the phone, build, install, launch, confirm it stays running.
xcrun devicectl list devices --json-output "$OUT/devices.json" >"$LOG" 2>&1
UDID=$(python3 -c 'import json, sys
d = [x["hardwareProperties"] for x in json.load(open(sys.argv[1]))["result"]["devices"]
     if x["hardwareProperties"].get("reality") == "physical"
     and x["hardwareProperties"].get("deviceType") == "iPhone"
     and x["connectionProperties"].get("pairingState") == "paired"
     and x["connectionProperties"].get("tunnelState") != "unavailable"]
print(d[0]["udid"] if d else "")' "$OUT/devices.json")
[ -n "$UDID" ] || { echo "No iPhone connected. Plug it in, unlock it and trust this Mac." >&2; exit 1; }
# Point the build at the full Xcode app, not the Command Line
# Tools. If xcode-select points at the CLT, xcodebuild cannot see
# the Apple ID accounts that live in the Xcode GUI, so it fails
# with "No Account for Team" even though the account is fine in
# Xcode. This forces the full Xcode's tools for this build only
# and does not change the system xcode-select.
echo "xcode-select points at: $(xcode-select -p 2>/dev/null || echo unknown)" >&2
if [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  echo "Using full Xcode at /Applications/Xcode.app for the build." >&2
fi
# Unlock the login keychain before building. The Apple ID account
# and the signing identity live there; the Xcode GUI unlocks it on
# demand, but a CLI xcodebuild cannot prompt, so when it is locked
# the build fails with "No Account for Team" even though the account
# is fine in Xcode. This is a no-op when the keychain is already
# unlocked, and prompts for the login password in this terminal
# when it is locked. There is no signer file to download: the
# certificate + private key are already in the keychain, which is
# why the GUI signs fine.
# If KEYCHAIN_PASSWORD is set in the environment, unlock the
# keychain non-interactively; otherwise prompt in the terminal.
# Do not put your Mac login password in a shell profile or any
# file that is backed up or shared: it would sit there in
# plaintext. To use it, set it only for this terminal session,
# e.g. `export KEYCHAIN_PASSWORD=...` before running this script,
# or unlock the keychain once in Keychain Access and let it stay
# unlocked for the session.
if [ -n "${KEYCHAIN_PASSWORD:-}" ]; then
  security unlock-keychain -p "$KEYCHAIN_PASSWORD" ~/Library/Keychains/login.keychain-db || {
    echo "Could not unlock the login keychain with KEYCHAIN_PASSWORD. If the build fails with 'No Account for Team', unlock it in Keychain Access and re-run." >&2
  }
  # Let codesign use the signing identity without prompting. Even
  # with the keychain unlocked, macOS prompts again when xcodebuild
  # accesses the private key at sign time. This grants codesign
  # (and Apple tools) access to the key so the build runs
  # non-interactively. It changes the keychain's access control
  # for the signing key; run it once per keychain, it persists.
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" ~/Library/Keychains/login.keychain-db 2>/dev/null || {
    echo "Could not grant codesign access to the signing key. The build may still prompt when it signs." >&2
  }
else
  security unlock-keychain ~/Library/Keychains/login.keychain-db || {
    echo "Could not unlock the login keychain. If the build fails with 'No Account for Team', unlock it in Keychain Access and re-run." >&2
  }
fi
# The team is an xcodebuild override, so it survives the pull above
# even though the pbxproj was discarded and re-pulled. The two
# invocations are written out (instead of an args array) because the
# Mac's bash 3.2 treats an empty array as unbound under `set -u`.
if [ -n "$TEAM" ]; then
  xcodebuild -scheme "$APP" -destination "id=$UDID" -derivedDataPath "$OUT" \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration build DEVELOPMENT_TEAM="$TEAM" >>"$LOG" 2>&1 || fail Build
else
  xcodebuild -scheme "$APP" -destination "id=$UDID" -derivedDataPath "$OUT" \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration build >>"$LOG" 2>&1 || fail Build
fi
xcrun devicectl device install app --device "$UDID" \
  "$OUT/Build/Products/Debug-iphoneos/$APP.app" >>"$LOG" 2>&1 || fail Install
xcrun devicectl device process launch --terminate-existing --device "$UDID" "$BUNDLE" >>"$LOG" 2>&1 || fail Launch
sleep 5
RUNNING=$(xcrun devicectl device info processes --device "$UDID" 2>>"$LOG") || fail "Process check"
grep -qF "$APP.app/$APP" <<<"$RUNNING" || {
  echo "$APP quit within 5 seconds. Crash reports: xcrun devicectl device info files --device $UDID --domain-type systemCrashLogs" >&2; exit 1; }
echo "$APP is running on the iPhone."
