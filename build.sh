#!/bin/bash
# Builds Spectra and packages it as build/Spectra.app.
#   ./build.sh          build
#   ./build.sh run      build, then launch
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/Spectra.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Spectra "$APP/Contents/MacOS/Spectra"
cp Support/Info.plist "$APP/Contents/Info.plist"
[ -f Support/AppIcon.icns ] && cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Sign with a real identity when one exists, so macOS remembers the audio
# permission between rebuilds. Override with SPECTRA_SIGN_IDENTITY, or set it
# to "-" to force ad-hoc signing.
IDENTITY="${SPECTRA_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk '/^ *1\)/{print $2}')}"
if [ -n "$IDENTITY" ] && [ "$IDENTITY" != "-" ] && codesign --force --sign "$IDENTITY" "$APP" 2>/dev/null; then
    echo "Signed with identity $IDENTITY"
else
    codesign --force --sign - "$APP"
    echo "Ad-hoc signed (macOS may ask for the audio permission again after a rebuild)"
fi

echo "Built $APP"
if [ "${1:-}" = "run" ]; then open "$APP"; fi
