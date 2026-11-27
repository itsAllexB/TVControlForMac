#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
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

# A release runs on Apple silicon and Intel Macs alike; a debug build is for this Mac only.
ARCHS=()
if [[ $CONFIG == release ]]; then
    ARCHS=(--arch arm64 --arch x86_64)
fi

# Record the SDK the app is really built with. SwiftPM's build system writes the
# deployment target (14.0) into the binary as its SDK version, and macOS then treats the
# app as one built for macOS 14: on macOS 26 and later it gets the old look instead of
# Liquid Glass (flat sidebar, old toolbar and controls). MIN_MACOS matches Package.swift.
MIN_MACOS="14.0"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
SDK_FLAGS=(-Xlinker -platform_version -Xlinker macos -Xlinker "$MIN_MACOS" -Xlinker "$SDK_VERSION")

swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"} "${SDK_FLAGS[@]}"
BIN="$(swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"} "${SDK_FLAGS[@]}" --show-bin-path)"

if ! vtool -show-build "$BIN/TVControlForMac" | grep -q "sdk $SDK_VERSION"; then
    echo "The binary doesn't record SDK $SDK_VERSION; the app would get the pre-macOS 26 look." >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/TVControlForMac" "$APP/Contents/MacOS/"
cp Support/Info.plist "$APP/Contents/"
cp Support/AppIcon.icns "$APP/Contents/Resources/"

# Sign with a stable local identity when there is one. macOS ties the Local Network
# permission to the signing identity, and installed copies only take an update from the
# signer they were signed by; an ad-hoc signature is a new identity on every build.
# SIGN_IDENTITY names the certificate to use. Otherwise "LGforMac Local Signing" (the
# certificate releases have been signed with since the app had that name; it comes first
# so that creating the other one later can't silently change the signer) or
# "TVControlForMac Local Signing". Ad hoc is the fallback.
IDENTITIES="$(security find-identity -p codesigning 2>/dev/null || true)"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    SIGNER="$SIGN_IDENTITY"
elif grep -q "LGforMac Local Signing" <<<"$IDENTITIES"; then
    SIGNER="LGforMac Local Signing"
elif grep -q "TVControlForMac Local Signing" <<<"$IDENTITIES"; then
    SIGNER="TVControlForMac Local Signing"
else
    SIGNER="-"
fi
codesign --force --sign "$SIGNER" "$APP"
echo "Built $APP"

if [[ $PACKAGE == 1 ]]; then
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist)"
    # Two or three parts: the updater reads a release tag as three parts, so a fourth would
    # never match the version the app inside says.
    if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
        echo "CFBundleShortVersionString \"$VERSION\" isn't a plain version like 3.0.1" >&2
        exit 1
    fi

    # What gets published has to be what the updater will accept: a valid signature.
    codesign --verify --deep --strict "$APP"

    # Installed copies only take an update from the signer they were signed by, and macOS
    # ties the Local Network permission to it too. An ad-hoc signature is a new identity
    # every build, and copies signed with a certificate would refuse such a release for
    # good, so it takes ALLOW_ADHOC_RELEASE=1 to package one.
    if [[ "$SIGNER" == "-" ]]; then
        if [[ "${ALLOW_ADHOC_RELEASE:-}" != 1 ]]; then
            echo "Refusing to package a release signed ad hoc (no signing certificate found, or SIGN_IDENTITY=-)." >&2
            echo "Copies signed with a certificate would refuse it. Set ALLOW_ADHOC_RELEASE=1 to package anyway." >&2
            exit 1
        fi
        echo "warning: signed ad hoc. Copies signed with a certificate will refuse this update," >&2
        echo "         and macOS may ask for Local Network permission again after it." >&2
    fi

    ZIP="dist/TVControlForMac-$VERSION.zip"
    DMG="dist/TVControlForMac-$VERSION.dmg"
    rm -f "$ZIP" "$DMG"

    STAGE="$(mktemp -d "${TMPDIR:-/tmp}/tvcontrol-dmg.XXXXXX")"
    CHECK="$(mktemp -d "${TMPDIR:-/tmp}/tvcontrol-zipcheck.XXXXXX")"
    # Release files that didn't pass every check below don't stay in dist/ to be published.
    PACKAGED=0
    trap 'rm -rf "$STAGE" "$CHECK"; [[ $PACKAGED == 1 ]] || rm -f "$ZIP" "$DMG"' EXIT

    # ditto keeps the bundle exactly as signed (permissions, extended attributes); the
    # updater unpacks it with ditto too.
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

    ditto "$APP" "$STAGE/TVControlForMac.app"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -quiet -volname "TVControlForMac $VERSION" -srcfolder "$STAGE" \
        -fs HFS+ -format UDZO -ov "$DMG"

    # Check the zip the way the updater will see it before calling the release done: the
    # app's own checks (zip layout, bundle, signature, same signer), then once more by hand.
    TVCONTROL_DATA_DIR="$CHECK/data" "$APP/Contents/MacOS/TVControlForMac" --update-verify "$ZIP" "$VERSION"
    UNZIPPED="$CHECK/unzipped"
    mkdir "$UNZIPPED"
    ditto -x -k "$ZIP" "$UNZIPPED"
    codesign --verify --deep --strict "$UNZIPPED/TVControlForMac.app"
    ZIPPED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$UNZIPPED/TVControlForMac.app/Contents/Info.plist")"
    if [[ "$ZIPPED_VERSION" != "$VERSION" ]]; then
        echo "The zipped app says $ZIPPED_VERSION, not $VERSION" >&2
        exit 1
    fi

    PACKAGED=1
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
