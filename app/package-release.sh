#!/bin/sh
# Build, notarize, staple, verify, then produce the disk image for direct distribution.
set -eu
cd "$(dirname "$0")"
: "${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to your Developer ID Application identity}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a notarytool Keychain profile}"
if [ "$SIGNING_IDENTITY" = "-" ]; then
    echo "A release requires a Developer ID Application certificate." >&2
    exit 1
fi
export ARCHS="${ARCHS:-arm64 x86_64}"

# Submits a file to Apple and waits; notarytool can exit successfully when the submission is rejected.
notarize() {
    set -- "$1" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json
    if [ -n "${NOTARY_KEYCHAIN:-}" ]; then
        set -- "$@" --keychain "$NOTARY_KEYCHAIN"
    fi
    xcrun notarytool submit "$@" > build/notarization.json
    status="$(plutil -extract status raw -o - build/notarization.json)"
    if [ "$status" != "Accepted" ]; then
        echo "Notarization was $status; see build/notarization.json and retrieve the notarytool log." >&2
        exit 1
    fi
}

./build-app.sh
app="build/Vinted Manager.app"
upload="build/Vinted-Manager-notarization.zip"
dmg="build/Vinted-Manager.dmg"
rm -f "$upload"
ditto -c -k --keepParent "$app" "$upload"
notarize "$upload"
rm -f "$upload"
xcrun stapler staple "$app"
xcrun stapler validate "$app"
codesign --verify --deep --strict "$app"
spctl --assess --type execute --verbose "$app"

# The disk image holds the stapled app and gets its own signature and ticket.
./make-dmg.sh
notarize "$dmg"
xcrun stapler staple "$dmg"
spctl --assess --type open --context context:primary-signature --verbose "$dmg"
echo "Ready to distribute: $(pwd)/$dmg"
