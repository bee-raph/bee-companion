#!/bin/zsh
set -euo pipefail
ROOT=${0:A:h}
MODE=${1:-release}
finish() {
  local result=$?
  if (( result != 0 )); then print -u2 '\nBuild failed. Review the error above.'; fi
  if [[ -t 0 ]]; then read -r '?Press Return to close this window.'; fi
  exit "$result"
}
trap finish EXIT
if [[ $(uname -s) != Darwin ]]; then print -u2 'Build on macOS with Xcode installed.'; exit 1; fi
if [[ "$MODE" != release && "$MODE" != debug ]]; then print -u2 'Usage: Build.command [release|debug]'; exit 1; fi
if ! xcrun --find swift >/dev/null 2>&1; then
  print -u2 'Install Xcode, launch it once, and select its command-line tools.'
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then print -u2 'Python 3 is required for packaging.'; exit 1; fi
print "Building Bee Companion ($MODE)…"
"$ROOT/scripts/build-macos" "$MODE"
print '\nApplication: '"$ROOT/macos/dist/Bee Companion.app"
if [[ "$MODE" == release ]]; then print 'Installer: '"$ROOT/macos/dist/Bee Companion.dmg"; fi
if [[ ${BEE_BUILD_REVEAL:-1} == 1 ]]; then open -R "$ROOT/macos/dist/Bee Companion.app"; fi
