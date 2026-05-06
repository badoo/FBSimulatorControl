#!/usr/bin/env zsh
# Iterate fbsimctl builds with full logs kept inside the project tree.
# Never touches $HOME or other absolute paths.

set -uo pipefail

# Stay anchored to this script's directory.
cd "${0:A:h}"

LOG_DIR="./logs"
mkdir -p "$LOG_DIR"
TS="$(date +%Y%m%d-%H%M%S)"
REBUILD_LOG="$LOG_DIR/rebuild-$TS.log"

echo "Cleaning local build artifacts (Carthage checkouts, build/, derived data)…"
rm -rf ./Carthage ./fbsimctl/Carthage ./build

# NO_XCPRETTY=1 -> build.sh emits raw xcodebuild output so errors are visible.
# tee mirrors everything to a timestamped file inside ./logs/ for post-mortem.
NO_XCPRETTY=1 ./build.sh fbsimctl build 2>&1 | tee "$REBUILD_LOG"
rc=${pipestatus[1]}

echo
echo "----"
echo "Build exit code: $rc"
echo "Rebuild log:     $REBUILD_LOG"
if [[ -f ./build/xcodebuild.log ]]; then
  echo "Raw xcodebuild:  ./build/xcodebuild.log"
fi
exit "$rc"
