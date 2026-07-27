#!/usr/bin/env bash
# Applies the small compatibility patch required to build pinned whisper.cpp
# with SwiftPM versions that inject an Objective-C resource accessor into every
# C/C++ compilation unit.
set -euo pipefail
cd "$(dirname "$0")/.."

swift package resolve

CHECKOUT=".build/checkouts/whisper.cpp"
PATCH="$PWD/patches/whisper-spm-resources.patch"

if git -C "$CHECKOUT" apply --unidiff-zero --check "$PATCH" 2>/dev/null; then
  git -C "$CHECKOUT" apply --unidiff-zero "$PATCH"
elif git -C "$CHECKOUT" apply --unidiff-zero --reverse --check "$PATCH" 2>/dev/null; then
  echo "whisper.cpp SwiftPM compatibility patch already applied."
else
  echo "ERROR: $PATCH does not apply cleanly to the pinned whisper.cpp checkout." >&2
  exit 1
fi
