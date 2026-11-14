#!/usr/bin/env bash
# CI only, on a Mac. Boots an iPhone simulator that has a Dynamic Island, starts the Live
# Activity from integration_test/live_activity_probe.dart (a run with one failed
# network), sends the app away, and saves every presentation of the island:
#
#   island-compact.png   the pill, read with Vision and tool/island_pixels.dart. The
#                        job fails unless it shows the count 2/5 with the red badge.
#   island-expanded.png  a long press on the island (AXe), read for the run's words.
#   island-stale.png     the pill once the 45 s stale date has passed with no update.
#                        The job fails unless the pause shape shows with the count.
#   island-minimal.png   two activities share the island, each in its minimal circle.
#
# The expanded and minimal pictures are evidence only: a missing long press tool or a
# simulator that lays out two activities its own way warns instead of failing.
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
SUMMARY="$OUT/island-presentations.txt"
: > "$SUMMARY"

# The tools that read the pictures, made before the probe starts: the time between
# the last update and the stale date is too short to spend on a build.
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
dart compile exe tool/island_pixels.dart -o "$OUT/island_pixels"
# A long press is the only way to the expanded island, and simctl has no touch.
# AXe sends one through the simulator's own input. Optional: without it the
# expanded picture is missing and the job warns.
if ! command -v axe > /dev/null 2>&1; then
  HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 brew install cameroncooke/axe/axe > "$OUT/axe.log" 2>&1 \
    || echo "::warning::AXe did not install: no expanded island picture. See axe.log"
fi

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
# Swift packages first (PDFium's xcframework is a GitHub release download),
# retried on network failures only: one failed the v1.4.2 tag build.
bash tool/retry_on_network.sh 4 xcodebuild -resolvePackageDependencies -workspace ios/Runner.xcworkspace -scheme Runner -derivedDataPath build/ios-simulator
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
# Both places, every time: a debug Flutter app on the simulator writes its prints to
# the system log, not to the redirected stdout, even when the redirected launch was
# taken (seen on CI: the activity started and went stale, PROBE_READY never reached
# probe.log).
SYSLOG_READY="$OUT/probe-syslog.log"
for _ in $(seq 1 90); do
  if grep -q PROBE_READY "$PROBE_LOG" 2>/dev/null; then ready=yes; READY_FROM=stdout; break; fi
  xcrun simctl spawn "$UDID" log show --last 10m --style compact --predicate 'eventMessage CONTAINS "PROBE_READY"' \
    > "$SYSLOG_READY" 2>&1 || true
  if grep -q 'PROBE_READY begin=' "$SYSLOG_READY"; then
    ready=yes
    READY_FROM=syslog
    cat "$SYSLOG_READY" >> "$PROBE_LOG"
    break
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

# What the probe's run shows (integration_test/live_activity_probe.dart): two of five
# posted, one failed, "Posting 4 of 5". test/ios_live_activity_project_test.dart
# holds these to the reducer's words.
COUNT="2/5"
LABEL="Posting 4 of 5"
FAILED="1 failed"
# Vision reads the pill's small slash as a bar: the first run with the count in the
# pill showed "2/5" with the badge and was read as "2|5". So the count is looked
# for with the slash as any of the upright strokes Vision gives for it, spaces
# around it or not, and never inside a longer number ("12/5", "2/50").
COUNT_SLASH="[/|lI]"
COUNT_READ="(^|[^0-9])${COUNT%/*} ?${COUNT_SLASH} ?${COUNT#*/}([^0-9]|\$)"
# Whether the text read from a picture ($1) has the count.
shows_count() {
  grep -qE "$COUNT_READ" "$1"
}

# Every iPhone with an island is 3x, and the island's middle is about 30 pt down.
# Echoes "x y" in points for AXe.
island_point() {
  local width
  width=$(sips -g pixelWidth "$1" | awk '/pixelWidth/ {print $2}')
  echo "$(( width / 6 )) 30"
}
# A point well under the expanded island, in the app in front, in points.
outside_point() {
  local width height
  width=$(sips -g pixelWidth "$1" | awk '/pixelWidth/ {print $2}')
  height=$(sips -g pixelHeight "$1" | awk '/pixelHeight/ {print $2}')
  echo "$(( width / 6 )) $(( height * 2 / 9 ))"
}
# Whether the probe printed $1, on its redirected stdout or in the simulator's log.
probe_said() {
  grep -q "$1" "$PROBE_LOG" 2>/dev/null && return 0
  xcrun simctl spawn "$UDID" log show --last 10m --style compact --predicate "eventMessage CONTAINS \"$1\"" \
    > "$OUT/probe-syslog-$1.log" 2>&1 || true
  grep -q "$1 begin=" "$OUT/probe-syslog-$1.log"
}

# Another app in front sends ours away, and the island shows the compact pill.
xcrun simctl launch "$UDID" com.apple.Preferences
sleep 4
xcrun simctl io "$UDID" screenshot "$OUT/island-compact.png"
"$OUT/read_text" "$OUT/island-compact.png" | tee "$OUT/island-compact.txt"
# The count at all times: a failure adds the red badge beside it, never replaces it.
shows_count "$OUT/island-compact.txt" || { echo "The compact island did not show the count $COUNT during a run with a failure"; exit 1; }
"$OUT/island_pixels" "$OUT/island-compact.png" --require right.red --forbid left.orange | tee "$OUT/island-compact-colours.txt" \
  || { echo "The compact island did not show the red failure badge beside the count, or showed the pause shape while live"; exit 1; }
# The ring and the mark are the accent colour, blue unless the extension sets one.
"$OUT/island_pixels" "$OUT/island-compact.png" --require left.blue > /dev/null \
  || echo "::warning::No blue ring or mark in the compact island's leading side. See island-compact-colours.txt"
echo "compact: proved, count $COUNT with the failure badge" >> "$SUMMARY"

# The expanded island: a long press on the pill. Read once while it opens and once
# after, and the picture with the run's words is kept.
expanded=no
if command -v axe > /dev/null 2>&1; then
  read -r IX IY <<< "$(island_point "$OUT/island-compact.png")"
  { echo "== axe touch at $IX,$IY"; axe touch -x "$IX" -y "$IY" --down --up --delay 1.5 --udid "$UDID"; } >> "$OUT/axe.log" 2>&1 || true
  for attempt in 1 2; do
    sleep 0.7
    xcrun simctl io "$UDID" screenshot "$OUT/island-expanded-$attempt.png" > /dev/null
    "$OUT/read_text" "$OUT/island-expanded-$attempt.png" > "$OUT/island-expanded-$attempt.txt"
    if grep -qF "$LABEL" "$OUT/island-expanded-$attempt.txt"; then
      cp "$OUT/island-expanded-$attempt.png" "$OUT/island-expanded.png"
      cp "$OUT/island-expanded-$attempt.txt" "$OUT/island-expanded.txt"
      expanded=yes
      break
    fi
  done
  # Closed again with a tap under it, so the stale pill is what is read next.
  read -r OX OY <<< "$(outside_point "$OUT/island-compact.png")"
  { echo "== axe tap at $OX,$OY"; axe tap -x "$OX" -y "$OY" --udid "$UDID"; } >> "$OUT/axe.log" 2>&1 || true
fi
if [ "$expanded" = yes ]; then
  cat "$OUT/island-expanded.txt"
  if grep -qF "$FAILED" "$OUT/island-expanded.txt" && shows_count "$OUT/island-expanded.txt"; then
    echo "expanded: captured, with \"$LABEL\", $COUNT and \"$FAILED\"" >> "$SUMMARY"
  else
    echo "::warning::The expanded island showed \"$LABEL\" without $COUNT or \"$FAILED\". See island-expanded.png"
    echo "expanded: captured, words incomplete" >> "$SUMMARY"
  fi
else
  echo "::warning::No expanded island picture: the long press did not open it. See axe.log and island-expanded-*.png"
  echo "expanded: not captured" >> "$SUMMARY"
fi

# Past the 45 s stale date nothing of NEFORUM's updates it. iOS redraws a stale
# activity with some delay (about 2 minutes once on CI), so the island is read
# every 10 s for up to 5 minutes, and the delay is reported. Stale, the pill keeps
# the last count and the badge, the mark turns to the orange pause shape, and the
# ring loses its blue arc. No live words anywhere.
REMAINING=$(( 50 - ( $(date +%s) - STARTED ) ))
if [ "$REMAINING" -gt 0 ]; then sleep "$REMAINING"; fi
stale=no
for _ in $(seq 1 30); do
  xcrun simctl io "$UDID" screenshot "$OUT/island-stale.png" > /dev/null
  "$OUT/read_text" "$OUT/island-stale.png" > "$OUT/island-stale.txt"
  if "$OUT/island_pixels" "$OUT/island-stale.png" --require left.orange --require right.red --forbid left.blue > "$OUT/island-stale-colours.txt" \
    && shows_count "$OUT/island-stale.txt" && ! grep -q "Posting" "$OUT/island-stale.txt"; then
    stale=yes
    break
  fi
  sleep 10
done
cat "$OUT/island-stale.txt" "$OUT/island-stale-colours.txt"
echo "The pause shape showed $(( $(date +%s) - STARTED )) s after the last update (stale date 45 s)." | tee "$OUT/stale-delay.txt"
[ "$stale" = yes ] || { echo "The island did not show the pause shape with the count $COUNT and the badge within 5 minutes of the stale date"; exit 1; }
echo "stale: proved, pause shape with $COUNT and the failure badge" >> "$SUMMARY"

# The minimal presentation: back in front, the probe starts a second run, and with
# two activities iOS shows each in its minimal circle. A relaunch of a running app
# brings it to the front.
minimal=no
if xcrun simctl launch "$UDID" "$BUNDLE_ID" >> "$LAUNCH_LOG" 2>&1; then
  for _ in $(seq 1 30); do
    if probe_said PROBE_SECOND; then minimal=started; break; fi
    sleep 2
  done
fi
if [ "$minimal" = started ]; then
  xcrun simctl launch "$UDID" com.apple.Preferences
  sleep 4
  xcrun simctl io "$UDID" screenshot "$OUT/island-minimal.png"
  "$OUT/read_text" "$OUT/island-minimal.png" > "$OUT/island-minimal.txt"
  "$OUT/island_pixels" "$OUT/island-minimal.png" > "$OUT/island-minimal-colours.txt" || true
  cat "$OUT/island-minimal.txt" "$OUT/island-minimal-colours.txt"
  # Minimal circles hold rings, no text: a count means iOS chose the pill for one.
  if grep -qE "(^|[^0-9])[0-9] ?${COUNT_SLASH} ?[0-9]([^0-9]|\$)" "$OUT/island-minimal.txt"; then
    echo "::warning::With two activities the island still showed a count: not both minimal. See island-minimal.png"
    echo "minimal: captured, but a count showed (a pill, not two circles)" >> "$SUMMARY"
  else
    echo "minimal: captured, two activities and no count" >> "$SUMMARY"
  fi
else
  echo "::warning::The probe never started its second run, so no minimal island picture. See launch.log"
  echo "minimal: not captured" >> "$SUMMARY"
fi

cat "$SUMMARY"
echo "Island compact and stale both proved."
