#!/bin/bash
# verify-bundle.sh <App.app> <min macOS> - fails if any Mach-O in the bundle
#  - is not x86_64,
#  - links to a library outside the bundle/system (Homebrew, build prefix) or to one missing from it,
#  - requires a newer macOS than <min macOS>.
set -euo pipefail
APP="$1"; MIN="$2"
fail=0
ver_gt() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ] && [ "$1" != "$2" ]; }

while IFS= read -r -d '' f; do
  file -b "$f" | grep -q 'Mach-O' || continue
  archs="$(lipo -archs "$f" 2>/dev/null || true)"
  case " $archs " in *" x86_64 "*) ;; *) echo "ARCH  $archs  $f"; fail=1 ;; esac
  minos="$(otool -l "$f" | awk '/LC_BUILD_VERSION/{b=1} b&&/minos/{print $2; exit}')"
  [ -z "$minos" ] && minos="$(otool -l "$f" | awk '/LC_VERSION_MIN_MACOSX/{b=1} b&&/ version/{print $2; exit}')"
  if [ -n "$minos" ] && ver_gt "$minos" "$MIN"; then echo "MINOS $minos  $f"; fail=1; fi
  otool -L "$f" | tail -n +2 | awk '{print $1}' | while read -r dep; do
    case "$dep" in
      /System/*|/usr/lib/*|@executable_path/*|@loader_path/*) ;;
      @rpath/*) [ -e "$APP/Contents/Frameworks/${dep#@rpath/}" ] || { echo "MISSING $dep  <- $f"; exit 1; } ;;
      *) echo "DEP   $dep  <- $f"; exit 1 ;;
    esac
  done || fail=1
done < <(find "$APP" -type f -print0)

if [ "$fail" -ne 0 ]; then
  echo "bundle verification FAILED" >&2
  exit 1
fi
echo "bundle OK: x86_64, macOS >= $MIN, no external libraries"
