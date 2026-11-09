#!/usr/bin/env bash
# Runs a command, and runs it again (up to <tries> times, waiting longer each
# time) only when it failed AND its output shows a network failure. Any other
# failure ends at once with the command's own exit code, so a real error is
# never retried or hidden.
#
#   bash tool/retry_on_network.sh <tries> <command> [args...]
#
# Why: during GitHub's anonymous-traffic incident (2026-11-09) the AppImage
# catalog lint's link check ("https://github.com/Neforuss/NEFORUM/issues -
# Unexpected status code: 504") and Xcode's package download of PDFium's
# xcframework failed the v1.4.2 tag build, while the same steps passed minutes
# later.
set -uo pipefail

tries=$1
shift
pattern='status code: 50[0-9]|HTTP (error )?50[0-9]|50[234] (Bad Gateway|Service Unavailable|Gateway Time-?out)|timed out|Timed out|Could not resolve host|Connection reset|failed downloading|The network connection was lost|Temporary failure in name resolution'
log=$(mktemp)
trap 'rm -f "$log"' EXIT
for attempt in $(seq 1 "$tries"); do
  "$@" 2>&1 | tee "$log"
  code=${PIPESTATUS[0]}
  [ "$code" -eq 0 ] && exit 0
  if ! grep -Eq "$pattern" "$log"; then
    exit "$code"
  fi
  if [ "$attempt" -lt "$tries" ]; then
    echo "::warning::network failure (attempt $attempt of $tries), retrying: $1"
    sleep $((attempt * ${RETRY_DELAY:-30}))
  fi
done
exit "$code"
