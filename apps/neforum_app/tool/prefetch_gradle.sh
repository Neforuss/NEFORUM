#!/usr/bin/env bash
# Puts the Gradle distribution that android/gradle/wrapper/gradle-wrapper.
# properties names where the Gradle wrapper looks before it downloads, so an
# Android build does not depend on the wrapper's own download.
#
#   bash tool/prefetch_gradle.sh          (in apps/neforum_app)
#
# Why: services.gradle.org redirects the download to a GitHub release
# (gradle/gradle-distributions), and on 2026-11-09 anonymous GitHub release
# downloads answered 504 (GitHub's "surge in anonymous users" incident),
# which failed the v1.4.2 tag build's Android jobs. The same file comes down
# through the GitHub API with a token. The wrapper skips its download when
# <GRADLE_USER_HOME>/wrapper/dists/<name>/<hash>/<name>.zip exists, <hash>
# being the MD5 of the distribution URL in base 36 (Gradle's PathAssembler),
# and still checks distributionSha256Sum when the properties set one.
#
# Needs gh with GH_TOKEN and python3. Exits 0 when the zip is in place, 1 when
# it could not be fetched (the wrapper then tries its own download).
set -euo pipefail

props=android/gradle/wrapper/gradle-wrapper.properties
[ -f "$props" ] || { echo "no $props: run in apps/neforum_app" >&2; exit 2; }
url=$(sed -n 's/^distributionUrl=//p' "$props" | sed 's/\\:/:/g' | tr -d '\r')
[ -n "$url" ] || { echo "no distributionUrl in $props" >&2; exit 2; }
zip=${url##*/}                       # gradle-9.3.1-all.zip
name=${zip%.zip}                     # gradle-9.3.1-all
version=$(printf '%s' "$name" | sed -n 's/^gradle-\([0-9][0-9.]*\)-\(all\|bin\)$/\1/p')
[ -n "$version" ] || { echo "cannot read a version from $zip" >&2; exit 2; }
hash=$(python3 -c '
import hashlib, sys
n = int(hashlib.md5(sys.argv[1].encode("utf-8")).hexdigest(), 16)
digits = "0123456789abcdefghijklmnopqrstuvwxyz"
out = ""
while n:
    n, r = divmod(n, 36)
    out = digits[r] + out
print(out or "0")
' "$url")
dir="${GRADLE_USER_HOME:-$HOME/.gradle}/wrapper/dists/$name/$hash"
if [ -s "$dir/$zip" ] || [ -f "$dir/$zip.ok" ]; then
  echo "Gradle $version: already in place ($dir)"
  exit 0
fi
mkdir -p "$dir"
for attempt in 1 2 3 4 5; do
  if gh release download "v$version" --repo gradle/gradle-distributions --pattern "$zip" --dir "$dir.part" --clobber; then
    mv "$dir.part/$zip" "$dir/$zip"
    rm -rf "$dir.part"
    echo "Gradle $version: $(wc -c < "$dir/$zip") bytes -> $dir/$zip"
    exit 0
  fi
  echo "Gradle $version: attempt $attempt failed" >&2
  sleep $((attempt * 15))
done
rm -rf "$dir.part"
echo "::warning::Gradle $version could not be fetched through the API; the wrapper will try its own download"
exit 1
