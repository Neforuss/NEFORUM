#!/usr/bin/env bash
# Cases for apps/neforum_app/tool/retry_on_network.sh. Run in apps/neforum_app.
export RETRY_DELAY=0
fail=0
check() { if [ "$1" = "$2" ]; then echo "ok   $3"; else echo "FAIL $3: got $1 want $2"; fail=1; fi; }

bash tool/retry_on_network.sh 3 true > /dev/null; check "$?" 0 "success exits 0"

c=$(mktemp)
bash tool/retry_on_network.sh 3 bash -c "echo x >> $c; echo 'error: unknown flag'; exit 7" > /dev/null
check "$?:$(wc -l < "$c")" "7:1" "a real error ends at once with its code, run once"

c=$(mktemp)
bash tool/retry_on_network.sh 3 bash -c "echo x >> $c; echo 'curl: (22) The requested URL returned error: 504'; echo 'status code: 504'; exit 22" > /dev/null 2>&1
check "$?:$(wc -l < "$c")" "22:3" "a network failure is tried 3 times, then its code"

c=$(mktemp)
bash tool/retry_on_network.sh 3 bash -c "echo x >> $c; [ \$(wc -l < $c) -ge 2 ] && exit 0; echo 'https://github.com/x/issues - Unexpected status code: 504'; exit 1" > /dev/null 2>&1
check "$?:$(wc -l < "$c")" "0:2" "a network failure that clears on the second try passes"

c=$(mktemp)
bash tool/retry_on_network.sh 3 bash -c "echo x >> $c; echo \"xcodebuild: error: failed downloading 'https://github.com/a/b/releases/download/v1/x.zip'\"; exit 74" > /dev/null 2>&1
check "$?:$(wc -l < "$c")" "74:3" "Xcode's package download failure counts as network"
exit $fail
