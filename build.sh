#!/bin/bash
# Builds Headroom.app as a universal (Apple Silicon + Intel) binary.
#   ./build.sh            build build/Headroom.app
#   ./build.sh install    build, copy to /Applications and (re)launch
#   ./build.sh dmg        build and package build/Headroom-<version>.dmg
#
# Signing (optional; without it the app gets an ad-hoc signature):
#   SIGN_ID          Developer ID Application identity (name or SHA-1) to sign the app and DMG with
# Notarizing the DMG (needs SIGN_ID), either:
#   NOTARY_PROFILE   a profile saved with `xcrun notarytool store-credentials`, or
#   NOTARY_KEY, NOTARY_KEY_ID, NOTARY_ISSUER   an App Store Connect API key (.p8 path, key id, issuer id)
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)

# Build each architecture separately and merge with lipo: `--arch a --arch b` needs Xcode's XCBuild,
# which the command line tools alone do not include. Each slice gets its own scratch path, since newer
# SwiftPM reports the same bin path for every triple.
SLICES=()
for ARCH in arm64 x86_64; do
    OPTS=(-c release --triple "$ARCH-apple-macosx14.0" --scratch-path ".build/$ARCH")
    swift build "${OPTS[@]}"
    SLICES+=("$(swift build "${OPTS[@]}" --show-bin-path)/Headroom")
done
BIN=.build/Headroom-universal
lipo -create "${SLICES[@]}" -output "$BIN"

APP=build/Headroom.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Headroom"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Sparkle (updates). Its XPC services are only needed by sandboxed apps; dropping them leaves
# nothing whose entitlements must survive re-signing.
FW="$APP/Contents/Frameworks/Sparkle.framework"
mkdir -p "$APP/Contents/Frameworks"
cp -R "$(find .build/arm64/artifacts -type d -path '*macos*' -name Sparkle.framework | head -1)" "$FW"
rm -rf "$FW/Versions/B/XPCServices" "$FW/XPCServices"

sign() {
    if [ -n "${SIGN_ID:-}" ]; then
        # Notarization requires the hardened runtime and a secure timestamp on every nested binary.
        codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$@"
    else
        codesign --force --sign - "$@"
    fi
}
# Inside out: nested helpers, then the framework, then the app.
sign "$FW/Versions/B/Autoupdate" "$FW/Versions/B/Updater.app"
sign "$FW"
sign "$APP"
[ -z "${SIGN_ID:-}" ] || codesign --verify --deep --strict --verbose=2 "$APP"
echo "Built $APP ($VERSION, $(lipo -archs "$APP/Contents/MacOS/Headroom"))"

case "${1:-}" in
install)
    pkill -x Headroom 2>/dev/null || true
    sleep 0.5
    rm -rf /Applications/Headroom.app
    cp -R "$APP" /Applications/
    open /Applications/Headroom.app
    echo "Installed and launched /Applications/Headroom.app"
    ;;
dmg)
    DMG="build/Headroom-$VERSION.dmg"
    AUTH=()
    # Stapling fetches the ticket from Apple, which sometimes fails from CI runners. It only matters for a
    # first launch without network (Gatekeeper otherwise looks the ticket up online), so retry, then warn.
    # Apple's notary and ticket services drop connections now and then; retry everything that talks to them.
    retry() { for _ in 1 2 3 4 5; do "$@" && return 0; sleep 20; done; return 1; }
    STAPLED=1
    staple() {
        retry xcrun stapler staple "$1" && return 0
        echo "warning: could not staple $1; notarized, but the first launch needs network" >&2
        STAPLED=0
    }
    if [ -z "${SIGN_ID:-}" ]; then :
    elif [ -n "${NOTARY_PROFILE:-}" ]; then AUTH=(--keychain-profile "$NOTARY_PROFILE")
    elif [ -n "${NOTARY_KEY:-}" ]; then AUTH=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
    fi
    # Notarize and staple the app first so it keeps its ticket after being copied out of the DMG
    # (otherwise the first launch needs a network check). notarytool takes a zip, not a bundle.
    if [ ${#AUTH[@]} -gt 0 ]; then
        ditto -c -k --keepParent "$APP" build/Headroom.zip
        retry xcrun notarytool submit build/Headroom.zip "${AUTH[@]}" --wait
        rm build/Headroom.zip
        staple "$APP"
    fi

    STAGE=build/dmg
    rm -rf "$STAGE" "$DMG"
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname "Headroom $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
    rm -rf "$STAGE"
    echo "Packaged $DMG ($(du -h "$DMG" | cut -f1))"

    [ -n "${SIGN_ID:-}" ] || exit 0
    codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
    if [ ${#AUTH[@]} -eq 0 ]; then
        echo "Signed $DMG (not notarized: no NOTARY_PROFILE or NOTARY_KEY)"
        exit 0
    fi
    retry xcrun notarytool submit "$DMG" "${AUTH[@]}" --wait
    staple "$DMG"
    [ "$STAPLED" = 0 ] || retry xcrun stapler validate "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose "$DMG"
    echo "Notarized $DMG"
    ;;
esac
