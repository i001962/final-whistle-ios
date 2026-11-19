#!/bin/bash
# Build, install over the old copy, launch, and confirm it stays running.
# Run on a Mac with Xcode 27.2 or later, from the repo root:
#   ./scripts/phone.sh
# The phone must be connected by cable, unlocked, trusted, and in Developer Mode.
# NOTE: the phone is on iOS 27.2.1. The Xcode SDK on the Mac must be 27.2.1 or
# newer to install onto it; if Xcode 27.2 ships only the 27.2 SDK, update Xcode
# first. IPHONEOS_DEPLOYMENT_TARGET stays at 26.0, which is lower than the phone.
set -euo pipefail
cd "$(dirname "$0")/.."
APP=FinalWhistle BUNDLE=app.final-whistle OUT=DerivedData.noindex
LOG=$OUT/phone.log; mkdir -p "$OUT"
fail() { grep -E 'error:|ERROR:|FailureReason' "$LOG" | sort -u | head -20 || true; echo "$1 failed. Log: $LOG" >&2; exit 1; }
xcrun devicectl list devices --json-output "$OUT/devices.json" >"$LOG" 2>&1
UDID=$(python3 -c 'import json, sys
d = [x["hardwareProperties"] for x in json.load(open(sys.argv[1]))["result"]["devices"]
     if x["hardwareProperties"].get("reality") == "physical"
     and x["hardwareProperties"].get("deviceType") == "iPhone"
     and x["connectionProperties"].get("pairingState") == "paired"
     and x["connectionProperties"].get("tunnelState") != "unavailable"]
print(d[0]["udid"] if d else "")' "$OUT/devices.json")
[ -n "$UDID" ] || { echo "No iPhone connected. Plug it in, unlock it and trust this Mac." >&2; exit 1; }
xcodebuild -scheme "$APP" -destination "id=$UDID" -derivedDataPath "$OUT" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build >>"$LOG" 2>&1 || fail Build
xcrun devicectl device install app --device "$UDID" \
  "$OUT/Build/Products/Debug-iphoneos/$APP.app" >>"$LOG" 2>&1 || fail Install
xcrun devicectl device process launch --terminate-existing --device "$UDID" "$BUNDLE" >>"$LOG" 2>&1 || fail Launch
sleep 5
RUNNING=$(xcrun devicectl device info processes --device "$UDID" 2>>"$LOG") || fail "Process check"
grep -qF "$APP.app/$APP" <<<"$RUNNING" || {
  echo "$APP quit within 5 seconds. Crash reports: xcrun devicectl device info files --device $UDID --domain-type systemCrashLogs" >&2; exit 1; }
echo "$APP is running on the iPhone."
