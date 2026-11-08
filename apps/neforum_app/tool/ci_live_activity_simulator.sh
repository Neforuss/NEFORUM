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
# A freshly booted simulator's SpringBoard can refuse the first launches
# ("denied by service delegate (SBMainWorkspace)") for a few seconds.
launched=no
for attempt in 1 2 3 4 5 6; do
  if xcrun simctl launch --stdout="$OUT/probe.log" --stderr="$OUT/probe.log" "$UDID" "$BUNDLE_ID" 2>> "$OUT/launch.log"; then
    launched=yes
    break
  fi
  echo "launch attempt $attempt refused" | tee -a "$OUT/launch.log"
  sleep 5
done
[ "$launched" = yes ] || { echo "The simulator refused every launch of $BUNDLE_ID"; exit 1; }

# A debug build starts slowly on a CI machine.
for _ in $(seq 1 90); do
  grep -q PROBE_READY "$OUT/probe.log" 2>/dev/null && break
  sleep 2
done
grep PROBE_READY "$OUT/probe.log"
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
