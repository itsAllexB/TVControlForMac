#!/bin/bash
# Builds TVControlForMac and assembles dist/TVControlForMac.app (ad-hoc signed).
# Usage: ./build.sh [debug|release] [--run]
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="dist/TVControlForMac.app"

# Generate the app icon once (committed afterwards, regenerated only if missing).
if [[ ! -f Support/AppIcon.icns ]]; then
    echo "Generating app icon…"
    swift scripts/make_icon.swift Support/AppIcon.icns
fi

swift build -c "$CONFIG"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/TVControlForMac" "$APP/Contents/MacOS/"
cp Support/Info.plist "$APP/Contents/"
cp Support/AppIcon.icns "$APP/Contents/Resources/"

# Prefer a stable local signing identity (keeps the macOS Local Network permission
# grant across rebuilds; ad-hoc signatures change identity every build). The older
# "LGforMac Local Signing" certificate is accepted too. Ad-hoc is the fallback.
IDENTITIES="$(security find-identity -p codesigning 2>/dev/null || true)"
if grep -q "TVControlForMac Local Signing" <<<"$IDENTITIES"; then
    codesign --force --sign "TVControlForMac Local Signing" "$APP"
elif grep -q "LGforMac Local Signing" <<<"$IDENTITIES"; then
    codesign --force --sign "LGforMac Local Signing" "$APP"
else
    codesign --force --sign - "$APP"
fi
echo "Built $APP"

if [[ "${2:-}" == "--run" ]]; then
    open "$APP"
fi
