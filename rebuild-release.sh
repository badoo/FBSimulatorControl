#!/usr/bin/env zsh
# Build a Release universal (arm64 + x86_64) fbsimctl. Logs land under ./logs/,
# build artefacts under ./build/Build/Products/Release/.

set -uo pipefail

cd "${0:A:h}"

LOG_DIR="./logs"
mkdir -p "$LOG_DIR"
TS="$(date +%Y%m%d-%H%M%S)"
REBUILD_LOG="$LOG_DIR/rebuild-release-$TS.log"

echo "Cleaning local build artifacts (Carthage checkouts, build/)…"
rm -rf ./Carthage ./fbsimctl/Carthage ./build

NO_XCPRETTY=1 BUILD_CONFIG=Release ./build.sh fbsimctl build 2>&1 | tee "$REBUILD_LOG"
rc=${pipestatus[1]}

echo
echo "----"
echo "Build exit code: $rc"
echo "Rebuild log:     $REBUILD_LOG"
if [[ $rc -eq 0 && -x ./build/Build/Products/Release/fbsimctl ]]; then
  echo "Binary:          ./build/Build/Products/Release/fbsimctl"
  echo "Architectures:   $(lipo -archs ./build/Build/Products/Release/fbsimctl)"
fi
exit "$rc"
