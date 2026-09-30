#!/bin/sh
# Wrap the built app in a disk image that opens as a "drag to Applications" window.
# Signs the image when SIGNING_IDENTITY is a real identity (not "-").
set -eu
cd "$(dirname "$0")"
app="build/Vinted Manager.app"
dmg="build/Vinted-Manager.dmg"
[ -d "$app" ] || { echo "Build the app first: app/build-app.sh" >&2; exit 1; }
if command -v dmgbuild >/dev/null 2>&1; then
    set -- dmgbuild
else
    set -- uvx --from dmgbuild==1.6.7 dmgbuild
fi
rm -f "$dmg"
"$@" -s dmg/settings.py -D app="$app" -D settings_dir="$(pwd)/dmg" "Vinted Manager" "$dmg"
identity="${SIGNING_IDENTITY:--}"
if [ "$identity" != "-" ]; then
    codesign --force --timestamp --sign "$identity" "$dmg"
fi
echo "Built $(pwd)/$dmg"
