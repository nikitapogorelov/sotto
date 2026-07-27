#!/usr/bin/env bash
# Builds a release binary and wraps it into Sotto.app so that TCC permissions
# (Microphone, Screen Recording) attach to a stable bundle identifier.
#
# Extra arguments are forwarded to `swift build`, e.g.:
#   ./scripts/bundle.sh --arch arm64 --arch x86_64
#
# Release automation can override the copied bundle metadata with:
#   SOTTO_VERSION=0.1.0 SOTTO_BUILD_NUMBER=42 ./scripts/bundle.sh
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD_ARGS=(-c release "$@")
swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"

APP=Sotto.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Sotto" "$APP/Contents/MacOS/Sotto"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [ -n "${SOTTO_VERSION:-}" ]; then
  plutil -replace CFBundleShortVersionString -string "$SOTTO_VERSION" "$APP/Contents/Info.plist"
fi
if [ -n "${SOTTO_BUILD_NUMBER:-}" ]; then
  plutil -replace CFBundleVersion -string "$SOTTO_BUILD_NUMBER" "$APP/Contents/Info.plist"
fi

# SPM resource bundles (KeyboardShortcuts localizations) — Bundle.module
# lookups crash in the bundled app without them.
for bundle in "$BIN_DIR"/*.bundle; do
  [ -d "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done
if [ -f Resources/Sotto.icns ]; then
  cp Resources/Sotto.icns "$APP/Contents/Resources/Sotto.icns"
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
