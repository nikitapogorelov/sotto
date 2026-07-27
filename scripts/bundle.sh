#!/usr/bin/env bash
# Builds a release binary and wraps it into Sotto.app so that TCC permissions
# (Microphone, Screen Recording) attach to a stable bundle identifier.
#
# Extra arguments are forwarded to `swift build`. Repeated `--arch` arguments
# are built separately and merged with lipo, avoiding SwiftPM's unstable
# multi-architecture XCBuild path for executable packages. For example:
#   ./scripts/bundle.sh --arch arm64 --arch x86_64
#
# Release automation can override the copied bundle metadata with:
#   SOTTO_VERSION=0.1.0 SOTTO_BUILD_NUMBER=42 ./scripts/bundle.sh
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/prepare-dependencies.sh

ARCHITECTURES=()
BUILD_OPTIONS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --arch)
      if [ "$#" -lt 2 ]; then
        echo "ERROR: --arch requires a value." >&2
        exit 1
      fi
      ARCHITECTURES+=("$2")
      shift 2
      ;;
    --arch=*)
      ARCHITECTURES+=("${1#*=}")
      shift
      ;;
    *)
      BUILD_OPTIONS+=("$1")
      shift
      ;;
  esac
done

BUILD_ARGS=(-c release)
if [ "${#BUILD_OPTIONS[@]}" -gt 0 ]; then
  BUILD_ARGS+=("${BUILD_OPTIONS[@]}")
fi
BIN_DIRS=()
if [ "${#ARCHITECTURES[@]}" -eq 0 ]; then
  swift build "${BUILD_ARGS[@]}"
  BIN_DIRS+=("$(swift build "${BUILD_ARGS[@]}" --show-bin-path)")
else
  for architecture in "${ARCHITECTURES[@]}"; do
    ARCH_ARGS=("${BUILD_ARGS[@]}" --arch "$architecture")
    swift build "${ARCH_ARGS[@]}"
    BIN_DIRS+=("$(swift build "${ARCH_ARGS[@]}" --show-bin-path)")
  done
fi

APP=Sotto.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [ "${#BIN_DIRS[@]}" -eq 1 ]; then
  cp "${BIN_DIRS[0]}/Sotto" "$APP/Contents/MacOS/Sotto"
else
  ARCH_BINARIES=()
  for bin_dir in "${BIN_DIRS[@]}"; do
    ARCH_BINARIES+=("$bin_dir/Sotto")
  done
  lipo -create "${ARCH_BINARIES[@]}" -output "$APP/Contents/MacOS/Sotto"
fi

cp Resources/Info.plist "$APP/Contents/Info.plist"

if [ -n "${SOTTO_VERSION:-}" ]; then
  plutil -replace CFBundleShortVersionString -string "$SOTTO_VERSION" "$APP/Contents/Info.plist"
fi
if [ -n "${SOTTO_BUILD_NUMBER:-}" ]; then
  plutil -replace CFBundleVersion -string "$SOTTO_BUILD_NUMBER" "$APP/Contents/Info.plist"
fi

# SPM resource bundles (KeyboardShortcuts localizations) — Bundle.module
# lookups crash in the bundled app without them.
for bundle in "${BIN_DIRS[0]}"/*.bundle; do
  [ -d "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done
if [ -f Resources/Sotto.icns ]; then
  cp Resources/Sotto.icns "$APP/Contents/Resources/Sotto.icns"
fi

# The compatibility patch keeps whisper.cpp's mixed C/C++ target free of the
# Objective-C SwiftPM resource accessor. The statically linked Metal backend
# resolves its bundle to the main app, so place the shader at the resource root.
WHISPER_METAL_SOURCE=".build/checkouts/whisper.cpp/ggml/src/ggml-metal.metal"
if [ -f "$WHISPER_METAL_SOURCE" ]; then
  cp "$WHISPER_METAL_SOURCE" "$APP/Contents/Resources/ggml-metal.metal"
fi

# Prefer a stable identity (SOTTO_SIGN_IDENTITY, or an existing self-signed
# "Sotto Dev" certificate) — the Screen Recording TCC grant is bound to the
# code signature, and an ad-hoc signature changes on every build, silently
# killing system audio until the permission is removed and re-added.
if [ -z "${SOTTO_SIGN_IDENTITY:-}" ] && security find-certificate -c "Sotto Dev" >/dev/null 2>&1; then
  SOTTO_SIGN_IDENTITY="Sotto Dev"
fi
IDENTITY="${SOTTO_SIGN_IDENTITY:--}"
[ "$IDENTITY" != "-" ] && echo "Signing with identity: $IDENTITY"
codesign --force --deep --sign "$IDENTITY" "$APP"

echo "Built $APP — move it to /Applications and launch."
echo "On first run grant: Microphone + Screen Recording (System Settings → Privacy & Security)."
if [ "$IDENTITY" = "-" ]; then
  echo "WARNING: ad-hoc signature — this build's identity differs from the previous one."
  echo "If system audio comes back silent, remove Sotto from System Settings →"
  echo "Privacy & Security → Screen Recording and add this build again."
  echo "For a stable identity, create a self-signed code signing certificate once"
  echo "(Keychain Access → Certificate Assistant) and export SOTTO_SIGN_IDENTITY=<its name>."
fi
