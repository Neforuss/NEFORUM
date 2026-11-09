#!/usr/bin/env bash
# Puts the PDFium libraries that pdfium_dart's build hook needs where the hook
# looks first, so a build does not depend on the hook's own download.
#
#   bash tool/prefetch_pdfium.sh <platform-arch>...     (in apps/neforum_app,
#                                                        after flutter pub get)
#   e.g. bash tool/prefetch_pdfium.sh linux-x64 android-arm64
#
# Why: the hook downloads https://github.com/bblanchon/pdfium-binaries/
# releases/download/<release>/pdfium-<platform>-<arch>.tgz on every clean
# build. On 2026-11-09 that address answered HTTP 504 for an hour while the
# same files came down fine through the GitHub API, and six jobs of the
# v1.4.2 tag run failed. The hook skips its download when the library is
# already at .dart_tool/hooks_runner/shared/pdfium_dart/build/<release>/
# <platform>-<arch>/<library> (pdfium_dart hook/build.dart, _downloadPdfium),
# so this script fills that path through the API (gh release download), with
# retries. The release and the archive layout are read from the hook itself,
# so an upgrade of pdfium_dart needs no change here.
#
# Needs gh with GH_TOKEN (CI: github.token). Exits 0 when every library is in
# place, 1 when one could not be fetched (the build would then try the hook's
# own download anyway).
set -euo pipefail

[ "$#" -gt 0 ] || { echo "usage: $0 <platform-arch>..." >&2; exit 2; }
config=.dart_tool/package_config.json
[ -f "$config" ] || { echo "$config is missing: run flutter pub get first" >&2; exit 2; }

# pdfium_dart's root from the package config: the line after its name.
root=$(grep -A1 '"name": "pdfium_dart"' "$config" | sed -n 's/.*"rootUri": "\(.*\)".*/\1/p')
[ -n "$root" ] || { echo "pdfium_dart is not in $config" >&2; exit 2; }
root=${root#file://}
root=$(printf '%s' "$root" | sed 's#^/\([A-Za-z]:\)#\1#')   # file:///C:/x on Windows
hook="$root/hook/build.dart"
[ -f "$hook" ] || { echo "no $hook" >&2; exit 2; }

release=$(sed -n "s/^const _pdfiumRelease = '\(.*\)';/\1/p" "$hook")
[ -n "$release" ] || { echo "no _pdfiumRelease in $hook" >&2; exit 2; }
tag=${release//%2F//}          # chromium%2F7811 -> chromium/7811
subdir=${release//%2F/_}       # the hook's own folder name: chromium_7811
shared=.dart_tool/hooks_runner/shared/pdfium_dart/build/$subdir

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
status=0
for target in "$@"; do
  case "$target" in
    linux-*|android-*) inside=lib/libpdfium.so ;;
    mac-*) inside=lib/libpdfium.dylib ;;
    win-*) inside=bin/pdfium.dll ;;
    *) echo "unknown target $target" >&2; exit 2 ;;
  esac
  out="$shared/$target/$(basename "$inside")"
  if [ -s "$out" ]; then
    echo "PDFium $target: already in place"
    continue
  fi
  asset="pdfium-$target.tgz"
  fetched=
  for attempt in 1 2 3 4 5; do
    if gh release download "$tag" --repo bblanchon/pdfium-binaries --pattern "$asset" --dir "$work" --clobber; then
      fetched=1
      break
    fi
    echo "PDFium $target: attempt $attempt failed" >&2
    sleep $((attempt * 15))
  done
  if [ -z "$fetched" ]; then
    echo "::warning::PDFium $target could not be fetched through the API; the build hook will try its own download"
    status=1
    continue
  fi
  tar -xzf "$work/$asset" -C "$work" "$inside"
  mkdir -p "$(dirname "$out")"
  cp "$work/$inside" "$out"
  rm -f "$work/$asset" "$work/$inside"
  echo "PDFium $target: $(wc -c < "$out") bytes -> $out"
done
exit $status
