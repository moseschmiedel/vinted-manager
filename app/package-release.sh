#!/bin/sh
# Build, notarize, staple, verify, then produce the ZIP for direct distribution.
set -eu
cd "$(dirname "$0")"
: "${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to your Developer ID Application identity}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a notarytool Keychain profile}"
if [ "$SIGNING_IDENTITY" = "-" ]; then
    echo "A release requires a Developer ID Application certificate." >&2
    exit 1
fi
export ARCHS="${ARCHS:-arm64 x86_64}"
./build-app.sh
app="build/Vinted Manager.app"
upload="build/Vinted-Manager-notarization.zip"
archive="build/Vinted-Manager.zip"
rm -f "$upload" "$archive"
ditto -c -k --keepParent "$app" "$upload"
set -- "$upload" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json
if [ -n "${NOTARY_KEYCHAIN:-}" ]; then
    set -- "$@" --keychain "$NOTARY_KEYCHAIN"
fi
xcrun notarytool submit "$@" > build/notarization.json
# notarytool can exit successfully when the submission is rejected.
status="$(plutil -extract status raw -o - build/notarization.json)"
if [ "$status" != "Accepted" ]; then
    echo "Notarization was $status; see build/notarization.json and retrieve the notarytool log." >&2
    exit 1
fi
xcrun stapler staple "$app"
xcrun stapler validate "$app"
codesign --verify --deep --strict "$app"
spctl --assess --type execute --verbose "$app"
ditto -c -k --keepParent "$app" "$archive"
rm -f "$upload"
echo "Ready to distribute: $(pwd)/$archive"
