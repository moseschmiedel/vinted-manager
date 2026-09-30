#!/bin/sh
# Build a self-contained app. ARCHS="arm64 x86_64" builds for both Mac architectures.
set -eu
cd "$(dirname "$0")"

archs="${ARCHS:-$(uname -m)}"
identity="${SIGNING_IDENTITY:--}"
app="build/Vinted Manager.app"
mkdir -p build
stage="$(mktemp -d "$(pwd)/build/package.XXXXXX")"
trap 'rm -rf "$stage"' EXIT HUP INT TERM

for arch in $archs; do
    case "$arch" in
        arm64) target=aarch64-apple-darwin ;;
        x86_64) target=x86_64-apple-darwin ;;
        *) echo "Unsupported architecture: $arch" >&2; exit 1 ;;
    esac
    swift build -c release --arch "$arch"
    bin="$(swift build -c release --arch "$arch" --show-bin-path)"
    MACOSX_DEPLOYMENT_TARGET=26.0 cargo build --locked --release --manifest-path ../cli/Cargo.toml --target "$target"
    mkdir -p "$stage/$arch"
    cp "$bin/VintedManager" "$stage/$arch/VintedManager"
    cp "$bin/VintedPhotoConverter" "$stage/$arch/VintedPhotoConverter"
    cp "../cli/target/$target/release/vinted" "$stage/$arch/vinted"
done

bundle="$stage/Vinted Manager.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Helpers" "$bundle/Contents/Resources"
for name in VintedManager vinted VintedPhotoConverter; do
    set --
    for arch in $archs; do set -- "$@" "$stage/$arch/$name"; done
    case "$name" in
        VintedManager) output="$bundle/Contents/MacOS/$name" ;;
        *) output="$bundle/Contents/Helpers/$name" ;;
    esac
    lipo -create "$@" -output "$output"
    chmod 755 "$output"
done
cp Info.plist "$bundle/Contents/Info.plist"
if [ -n "${APP_VERSION:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$bundle/Contents/Info.plist"
fi
if [ -n "${APP_BUILD:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_BUILD" "$bundle/Contents/Info.plist"
fi

# Sign nested code first, then the enclosing app. Release signatures need a timestamp.
for code in "$bundle/Contents/Helpers/vinted" "$bundle/Contents/Helpers/VintedPhotoConverter" "$bundle"; do
    if [ "$identity" = "-" ]; then
        codesign --force --sign - "$code"
    else
        codesign --force --options runtime --timestamp --sign "$identity" "$code"
    fi
done
codesign --verify --deep --strict "$bundle"
rm -rf "$app"
mv "$bundle" "$app"

echo "Built $(pwd)/$app ($archs)"
