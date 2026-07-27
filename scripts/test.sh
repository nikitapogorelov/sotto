#!/bin/bash
# Run the unit tests.
#
# With full Xcode installed, plain `swift test` works. With Command Line
# Tools alone there is no XCTest, and swift-testing's framework isn't on
# the default search paths — pass them explicitly.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/prepare-dependencies.sh

DEV_DIR="$(xcode-select -p)"
if [[ "$DEV_DIR" == *CommandLineTools* ]]; then
  FWK="$DEV_DIR/Library/Developer/Frameworks"
  LIB="$DEV_DIR/Library/Developer/usr/lib"
  exec swift test \
    -Xswiftc -F"$FWK" \
    -Xlinker -F"$FWK" \
    -Xlinker -rpath -Xlinker "$FWK" \
    -Xlinker -rpath -Xlinker "$LIB" \
    "$@"
fi
exec swift test "$@"
