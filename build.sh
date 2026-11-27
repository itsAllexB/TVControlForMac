#!/bin/bash
# Builds TVControlForMac and assembles dist/TVControlForMac.app, signed with the stable
# local certificate when there is one (ad hoc otherwise).
#
# Usage: ./build.sh [debug|release] [--run] [--package]
#
# --package (release builds only) also writes the release files to dist/:
#   TVControlForMac-<version>.zip   the app, zipped with ditto. The updater looks for
#                                   exactly this name in a GitHub release.
#   TVControlForMac-<version>.dmg   the app and an Applications link, for installing by hand.
# <version> is CFBundleShortVersionString in Support/Info.plist.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="release"
RUN=0
PACKAGE=0
for arg in "$@"; do
    case "$arg" in
        debug|release) CONFIG="$arg" ;;
        --run) RUN=1 ;;
        --package) PACKAGE=1 ;;
        *) echo "Unknown argument: $arg (usage: ./build.sh [debug|release] [--run] [--package])" >&2; exit 2 ;;
    esac
done
if [[ $PACKAGE == 1 && $CONFIG != release ]]; then
    echo "--package needs a release build: ./build.sh release --package" >&2
    exit 2
fi

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
    SIGNER="TVControlForMac Local Signing"
elif grep -q "LGforMac Local Signing" <<<"$IDENTITIES"; then
    SIGNER="LGforMac Local Signing"
else
    SIGNER="-"
fi
codesign --force --sign "$SIGNER" "$APP"
echo "Built $APP"

if [[ $PACKAGE == 1 ]]; then
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist)"
    if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]]; then
        echo "CFBundleShortVersionString \"$VERSION\" isn't a plain version like 3.0.1" >&2
        exit 1
    fi

    # What gets published has to be what the updater will accept: a valid signature.
    codesign --verify --deep --strict "$APP"

    # Installed copies only take an update from the signer they were signed by, and macOS
    # ties the Local Network permission to it too. An ad-hoc signature is a new identity
    # every build, so say so loudly before anything is published with one.
    if [[ "$SIGNER" == "-" ]]; then
        echo "warning: signed ad hoc. Copies signed with a certificate will refuse this update," >&2
        echo "         and macOS may ask for Local Network permission again after it." >&2
    fi

    ZIP="dist/TVControlForMac-$VERSION.zip"
    DMG="dist/TVControlForMac-$VERSION.dmg"
    rm -f "$ZIP" "$DMG"

    # ditto keeps the bundle exactly as signed (permissions, extended attributes); the
    # updater unpacks it with ditto too.
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

    STAGE="$(mktemp -d "${TMPDIR:-/tmp}/tvcontrol-dmg.XXXXXX")"
    CHECK="$(mktemp -d "${TMPDIR:-/tmp}/tvcontrol-zipcheck.XXXXXX")"
    trap 'rm -rf "$STAGE" "$CHECK"' EXIT
    ditto "$APP" "$STAGE/TVControlForMac.app"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -quiet -volname "TVControlForMac $VERSION" -srcfolder "$STAGE" \
        -fs HFS+ -format UDZO -ov "$DMG"

    # Check the zip the way the updater will see it before calling the release done.
    ditto -x -k "$ZIP" "$CHECK"
    codesign --verify --deep --strict "$CHECK/TVControlForMac.app"
    ZIPPED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$CHECK/TVControlForMac.app/Contents/Info.plist")"
    if [[ "$ZIPPED_VERSION" != "$VERSION" ]]; then
        echo "The zipped app says $ZIPPED_VERSION, not $VERSION" >&2
        exit 1
    fi

    echo
    echo "Release files for $VERSION (signed: $([[ $SIGNER == - ]] && echo ad hoc || echo "$SIGNER")):"
    for file in "$ZIP" "$DMG"; do
        printf '  %-34s %10s bytes  sha256 %s\n' "$(basename "$file")" \
            "$(stat -f %z "$file")" "$(shasum -a 256 "$file" | cut -d' ' -f1)"
    done
    echo "Designated requirement (installed copies must keep matching it):"
    codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => /  /p'
fi

if [[ $RUN == 1 ]]; then
    open "$APP"
fi
