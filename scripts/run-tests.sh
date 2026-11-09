#!/usr/bin/env bash
set -euo pipefail

DEV_DIR="$(xcode-select -p 2>/dev/null || true)"
EXTRA_ARGS=("$@")

if [[ "$DEV_DIR" == "/Library/Developer/CommandLineTools" ]]; then
  FRAMEWORKS="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
  exec swift test \
    --disable-xctest \
    --enable-swift-testing \
    -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
    -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
    -Xlinker -F -Xlinker "$FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
    "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"
else
  exec swift test "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"
fi

