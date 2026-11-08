#!/usr/bin/env bash
# CI only, on a Mac. Boots an iPhone simulator that has a Dynamic Island, starts the Live
# Activity from integration_test/live_activity_probe.dart, sends the app away, and saves
# what the island shows: live, and again once the 45 s stale date has passed with no
# update. Reads both pictures with Vision, so the job fails if "Paused" never appears.
#
# Run from apps/neforum_app. Output goes to $OUT (default build/live-activity).
set -euo pipefail

OUT="${OUT:-build/live-activity}"
BUNDLE_ID="org.neforum.neforumApp"
mkdir -p "$OUT"
# Absolute: simctl hands --stdout and --stderr to the simulator's side to open, which
# does not start in this directory. A relative path there never reached this folder.
OUT="$(cd "$OUT" && pwd -P)"
PROBE_LOG="$OUT/probe.log"
LAUNCH_LOG="$OUT/launch.log"

# The newest runtime's first iPhone Pro: every one since the 14 Pro has an island.
UDID=$(xcrun simctl list devices available -j | python3 -c '
import json, re, sys
devices = json.load(sys.stdin)["devices"]
def version(key):
    return [int(n) for n in re.findall(r"\d+", key.split("iOS")[-1])] if "iOS" in key else []
for key in sorted(devices, key=version, reverse=True):
    if "iOS" not in key:
        continue
    for d in devices[key]:
        m = re.match(r"iPhone (\d+) Pro\b", d["name"])
        if m and int(m.group(1)) >= 14:
            print(d["udid"])
            sys.exit(0)
sys.exit("no iPhone with a Dynamic Island in this Xcode")
')
xcrun simctl list devices | grep "$UDID" | tee "$OUT/device.txt"
xcrun simctl boot "$UDID" || true
xcrun simctl bootstatus "$UDID" -b

flutter build ios --simulator --debug --config-only -t integration_test/live_activity_probe.dart --dart-define=NEFORUM_MOBILE=true
# Ad hoc signed, because the simulator will not load an extension with no signature.
xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration Debug \
  -sdk iphonesimulator -destination "id=$UDID" -derivedDataPath build/ios-simulator \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM="" build
APP=build/ios-simulator/Build/Products/Debug-iphonesimulator/Runner.app
test -d "$APP/PlugIns/NeforumLiveActivity.appex"

xcrun simctl install "$UDID" "$APP"
# What was built, for any run that goes wrong later. .txt so the job uploads it.
plutil -p "$APP/Info.plist" > "$OUT/app-info-plist.txt" 2>&1 || true
plutil -p "$APP/PlugIns/NeforumLiveActivity.appex/Info.plist" > "$OUT/appex-info-plist.txt" 2>&1 || true

# Why SpringBoard said no: its own log and the app's, from the simulator.
evidence() {
  xcrun simctl spawn "$UDID" log show --last 2m --style compact \
    --predicate 'process == "SpringBoard" OR process CONTAINS "neforum" OR process == "Runner"' \
    > "$OUT/springboard-$1.log" 2>&1 || true
  {
    echo "== codesign Runner.app"
    codesign -dvvv --entitlements - "$APP" 2>&1 || true
    echo "== codesign NeforumLiveActivity.appex"
    codesign -dvvv --entitlements - "$APP/PlugIns/NeforumLiveActivity.appex" 2>&1 || true
    echo "== lipo"
    lipo -info "$APP/Runner" 2>&1 || true
    echo "== Rosetta"
    if /usr/bin/arch -x86_64 /usr/bin/true 2> /dev/null; then echo "installed"; else echo "not installed"; fi
    echo "== simctl appinfo"
    xcrun simctl appinfo "$UDID" "$BUNDLE_ID" 2>&1 || true
  } > "$OUT/app-evidence-$1.txt"
}

# The probe's own launch: its stdout carries PROBE_READY.
launch_probe() {
  local attempts="$1" attempt
  for attempt in $(seq 1 "$attempts"); do
    if xcrun simctl launch --stdout="$PROBE_LOG" --stderr="$PROBE_LOG" "$UDID" "$BUNDLE_ID" 2>> "$LAUNCH_LOG"; then
      return 0
    fi
    echo "launch attempt $attempt refused" | tee -a "$LAUNCH_LOG"
    sleep 5
  done
  return 1
}

# Where PROBE_READY is read: the redirected stdout, or the simulator's log when only a
# launch without redirection was taken.
READY_FROM=stdout
# A freshly booted simulator's SpringBoard can refuse the first launches
# ("denied by service delegate (SBMainWorkspace)") for a few seconds.
if ! launch_probe 6; then
  evidence refused
  # Is it the redirection or the app? One launch without it says which.
  if xcrun simctl launch "$UDID" "$BUNDLE_ID" 2>> "$LAUNCH_LOG"; then
    echo "a launch without --stdout/--stderr was taken: the redirection is what SpringBoard refused" | tee -a "$LAUNCH_LOG"
    READY_FROM=log
  elif ! /usr/bin/arch -x86_64 /usr/bin/true 2> /dev/null; then
    # Reported on Apple silicon runners: SpringBoard refuses until Rosetta is there.
    echo "a launch without redirection was refused too, and Rosetta is missing: installing it" | tee -a "$LAUNCH_LOG"
    sudo softwareupdate --install-rosetta --agree-to-license >> "$LAUNCH_LOG" 2>&1 || true
    if ! launch_probe 3; then
      evidence after-rosetta
      echo "The simulator refused every launch of $BUNDLE_ID, with Rosetta too. See springboard-*.log and app-evidence-*.txt"
      exit 1
    fi
  else
    echo "The simulator refused every launch of $BUNDLE_ID, with and without redirection. See springboard-refused.log and app-evidence-refused.txt"
    exit 1
  fi
fi

# A debug build starts slowly on a CI machine.
ready=no
for _ in $(seq 1 90); do
  if [ "$READY_FROM" = stdout ]; then
    grep -q PROBE_READY "$PROBE_LOG" 2>/dev/null && { ready=yes; break; }
  else
    xcrun simctl spawn "$UDID" log show --last 5m --style compact --predicate 'eventMessage CONTAINS "PROBE_READY"' \
      > "$PROBE_LOG" 2>&1 || true
    grep -q 'PROBE_READY begin=' "$PROBE_LOG" && { ready=yes; break; }
  fi
  sleep 2
done
if [ "$ready" != yes ]; then
  evidence not-ready
  echo "The probe never printed PROBE_READY (read from $READY_FROM). See probe.log and springboard-not-ready.log"
  exit 1
fi
grep PROBE_READY "$PROBE_LOG"
STARTED=$(date +%s)
xcrun simctl io "$UDID" screenshot "$OUT/app-in-front.png"

# Another app in front sends ours away, and the island shows.
xcrun simctl launch "$UDID" com.apple.Preferences
sleep 4
xcrun simctl io "$UDID" screenshot "$OUT/island-live.png"

# Past the stale date. Nothing of NEFORUM's updates it from here on.
REMAINING=$(( 50 - ( $(date +%s) - STARTED ) ))
if [ "$REMAINING" -gt 0 ]; then sleep "$REMAINING"; fi
xcrun simctl io "$UDID" screenshot "$OUT/island-stale.png"

cat > "$OUT/read_text.swift" <<'SWIFT'
import AppKit
import Vision

let image = NSImage(contentsOfFile: CommandLine.arguments[1])!
var rect = NSRect(origin: .zero, size: image.size)
let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
try VNImageRequestHandler(cgImage: cg).perform([request])
for o in request.results ?? [] { print(o.topCandidates(1).first?.string ?? "") }
SWIFT
swiftc -o "$OUT/read_text" "$OUT/read_text.swift"
"$OUT/read_text" "$OUT/island-live.png" | tee "$OUT/island-live.txt"
"$OUT/read_text" "$OUT/island-stale.png" | tee "$OUT/island-stale.txt"

# The island's small space holds "2/5" while live and "Paused" once stale.
grep -q "2/5" "$OUT/island-live.txt" || { echo "The island did not show 2/5 while live"; exit 1; }
grep -qi "Paused" "$OUT/island-stale.txt" || { echo "The island did not show Paused once stale"; exit 1; }
if grep -q "2/5" "$OUT/island-stale.txt"; then echo "The stale island still shows its live words"; exit 1; fi
echo "Island live and stale both proved."
