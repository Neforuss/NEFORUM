#!/usr/bin/env bash
# Does a post the person started still finish after Home and removing the task?
# Run from apps/neforum_app on a machine with an emulator running and the profile
# build of integration_test/android_background_probe.dart at $APK. The only proof is
# the fake server's log: status-created after the task was gone. Stdout is the job log.
#
#   bash tool/android_background_probe/run_probe.sh swipe   # Home, remove task, must finish
#   bash tool/android_background_probe/run_probe.sh limit   # Android's time limit, no crash
#
# ADB, DART and PROBE_* can be replaced (the script was walked with a stub adb before it
# first met an emulator). Every failure names what it saw.
set -uo pipefail

LANE="${1:-swipe}"
ADB="${ADB:-adb}"
DART="${DART:-dart}"
OUT="${PROBE_OUT:-build/android-background-probe}"
APK="${APK:-build/app/outputs/flutter-apk/app-profile.apk}"
PKG=org.neforum.app
ACTIVITY="$PKG/org.neforum.neforum_app.MainActivity"
# The port on this machine; the app always calls 8787 on its side (adb reverse). One per
# lane, so a server still closing from the first lane cannot answer the second.
# HOLD: how long the server "processes" the file. The adapter polls for 180 s at most,
# and the limit lane has to outlast Android's 60 s plus however late Android checks.
if [ "$LANE" = limit ]; then
  PORT="${PROBE_PORT:-8788}"
  HOLD="${PROBE_HOLD:-170}"
else
  PORT="${PROBE_PORT:-8787}"
  HOLD="${PROBE_HOLD:-120}"
fi
WAIT="${PROBE_WAIT:-$((HOLD + 180))}"
SERVER_LOG="$OUT/$LANE-server.log"
LOGCAT="$OUT/$LANE-logcat.txt"
SERVER_PID=""
LOGCAT_PID=""

mkdir -p "$OUT"
: > "$SERVER_LOG"
: > "$LOGCAT"

say() { echo "[probe:$LANE] $*"; }

finish() {
  [ -n "$LOGCAT_PID" ] && kill "$LOGCAT_PID" 2> /dev/null
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2> /dev/null
  echo "----- server log ($LANE) -----"
  grep -v media-poll "$SERVER_LOG" || true
  echo "polls: $(grep -c media-poll "$SERVER_LOG" || true)"
  echo "----- app lines of logcat ($LANE) -----"
  grep -E 'PROBE|publish-|PublishService|PublishHost|FATAL EXCEPTION' "$LOGCAT" 2> /dev/null | tail -n 60 || true
}
trap finish EXIT

fail() {
  echo "::error::Android background probe ($LANE): $*"
  exit 1
}

mark() { curl -fsS -X POST "http://127.0.0.1:$PORT/__mark?name=$1" > /dev/null || fail "the fake server stopped answering"; }

# wait_for <pattern> <seconds>: true when the server log has the line in time.
wait_for() {
  local waited=0
  while [ "$waited" -lt "$2" ]; do
    grep -q "$1" "$SERVER_LOG" && return 0
    sleep 2
    waited=$((waited + 2))
  done
  return 1
}

app_pid() { "$ADB" shell pidof "$PKG" | tr -d '\r'; }

service_running() { "$ADB" shell dumpsys activity services "$PKG" | grep -q 'PublishService'; }

# The id of NEFORUM's task, from Recents. Empty when there is none.
task_id() {
  "$ADB" shell dumpsys activity recents | tr -d '\r' | grep -E "Recent #[0-9]+:.*$PKG" | head -n 1 | sed -E 's/.*#([0-9]+) type=.*/\1/'
}

api_level() { "$ADB" shell getprop ro.build.version.sdk | tr -d '\r'; }

start_all() {
  "$DART" run tool/android_background_probe/fake_mastodon.dart --port "$PORT" --log "$SERVER_LOG" --hold "$HOLD" &
  SERVER_PID=$!
  local up=0
  until curl -fsS -X POST "http://127.0.0.1:$PORT/__mark?name=server-up" > /dev/null 2>&1; do
    up=$((up + 1))
    [ "$up" -lt 60 ] || fail "the fake server did not start in 120 s"
    sleep 2
  done
  "$ADB" install -r -g "$APK" || fail "the APK did not install"
  "$ADB" shell pm clear "$PKG" > /dev/null
  "$ADB" shell pm grant "$PKG" android.permission.POST_NOTIFICATIONS || true
  "$ADB" reverse tcp:8787 "tcp:$PORT" || fail "adb reverse failed"
  "$ADB" logcat -c
  "$ADB" logcat > "$LOGCAT" &
  LOGCAT_PID=$!
  "$ADB" shell am start -W -n "$ACTIVITY" || fail "the app did not start"
  wait_for media-created 180 || fail "the post never reached the server: no upload in 180 s"
  mark tapped-run-started
}

show_notification() {
  # Evidence for the log. The format of dumpsys is no contract, so a miss only warns.
  local dump
  dump="$("$ADB" shell dumpsys notification --noredact | tr -d '\r' | grep -A 40 "pkg=$PKG" | grep -E 'channel=neforum.progress|android.title|android.text|android.progress|android.template|ProgressStyle' | head -n 12)"
  echo "$dump"
  if [ "$(api_level)" -ge 36 ]; then
    echo "$dump" | grep -q 'ProgressStyle' || echo "::warning::API 36+: no ProgressStyle seen in dumpsys notification"
  else
    echo "$dump" | grep -q 'android.progress' || echo "::warning::No progress seen in dumpsys notification"
  fi
}

# ActivityTaskManager.removeTask is what a swipe in Recents calls, with its process rule.
# The real gesture is the fallback, for an image whose shell lacks the command.
remove_task() {
  "$ADB" shell am stack remove "$1"
  sleep 5
  [ -z "$(task_id)" ] && return 0
  say "am stack remove left the task; swiping it away in Recents"
  local size w h
  size="$("$ADB" shell wm size | tr -d '\r' | sed -E 's/.*: *([0-9]+x[0-9]+).*/\1/' | tail -n 1)"
  w="${size%x*}"
  h="${size#*x}"
  "$ADB" shell input keyevent KEYCODE_RECENT_APPS
  sleep 4
  "$ADB" shell input swipe $((w / 2)) $((h / 2)) $((w / 2)) 0 250
  sleep 5
  "$ADB" shell input keyevent KEYCODE_HOME
  [ -z "$(task_id)" ]
}

lane_swipe() {
  start_all
  service_running || fail "the upload is under way and PublishService is not running: the keep-alive did not start"
  sleep 12 # Android defers a foreground service's notification by up to 10 s.
  show_notification

  say "pressing Home"
  "$ADB" shell input keyevent KEYCODE_HOME
  sleep 5
  mark home
  local before
  before="$(app_pid)"
  [ -n "$before" ] || fail "the process died on Home"
  service_running || fail "PublishService stopped on Home"

  local id
  id="$(task_id)"
  [ -n "$id" ] || fail "the emulator's Recents lists no NEFORUM task, so the swipe cannot be done: $("$ADB" shell dumpsys activity recents | head -n 20)"
  say "removing task $id from Recents"
  remove_task "$id" || fail "neither am stack remove nor a swipe in Recents took the task away on this image, so nothing was proved. Recents: $("$ADB" shell dumpsys activity recents | head -n 20)"
  mark task-removed
  local after
  after="$(app_pid)"
  [ "$after" = "$before" ] || fail "the process changed from '$before' to '$after' when the task was removed: the run stopped"

  # One file's order: the post went out after the task was gone.
  grep -q 'status-created' "$SERVER_LOG" && fail "the post was created before the task was removed, so this run proves nothing: raise PROBE_HOLD"
  wait_for status-created "$WAIT" || fail "no post reached the server after the task was removed: the run stopped silently"
  local gone_line polls_after
  gone_line="$(grep -n 'mark task-removed' "$SERVER_LOG" | head -n 1 | cut -d: -f1)"
  polls_after="$(tail -n +"$gone_line" "$SERVER_LOG" | grep -c media-poll)"
  [ "$polls_after" -gt 0 ] || fail "no request came between the task's removal and the post"
  sleep 3
  [ "$(grep -c 'status-created' "$SERVER_LOG")" -eq 1 ] || fail "more than one post was created"
  grep -q 'FATAL EXCEPTION' "$LOGCAT" && fail "the app crashed during the run"

  # The run's end lets go of everything.
  local waited=0
  while service_running && [ "$waited" -lt 30 ]; do
    sleep 2
    waited=$((waited + 2))
  done
  service_running && fail "PublishService still runs 30 s after the post finished"
  say "PASS: $polls_after requests and 1 post came after the task was removed, from process $after; the service then stopped itself"
}

lane_limit() {
  [ "$(api_level)" -ge 35 ] || { say "SKIP: Android's limit starts at API 35, this is $(api_level)"; return 0; }
  # Report android.md T10. The value counts only outside the app.
  "$ADB" shell device_config put activity_manager data_sync_fgs_timeout_duration 60000
  start_all
  service_running || fail "PublishService is not running"
  "$ADB" shell input keyevent KEYCODE_HOME
  mark home
  # onTimeout comes when Android checks: wait for the service to go, the hold is longer.
  local waited=0
  while service_running && [ "$waited" -lt 160 ]; do
    sleep 2
    waited=$((waited + 2))
  done
  "$ADB" shell device_config delete activity_manager data_sync_fgs_timeout_duration || true
  service_running && fail "the service still runs 160 s after Home: Android's limit never came"
  sleep 15
  grep -q 'publish-timeout' "$LOGCAT" || fail "the service stopped without onTimeout"
  grep -q 'FATAL EXCEPTION' "$LOGCAT" && fail "the app crashed at the limit"
  grep -q 'RemoteServiceException' "$LOGCAT" && fail "Android ended the app for not stopping in time"
  grep -q 'status-created' "$SERVER_LOG" && fail "a post was created after the run was cancelled at the limit"
  say "PASS: onTimeout came, the service stopped, no crash, nothing more was posted"
}

case "$LANE" in
  swipe) lane_swipe ;;
  limit) lane_limit ;;
  *) fail "unknown lane $LANE" ;;
esac
