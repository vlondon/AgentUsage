#!/bin/zsh
set -euo pipefail

PROJECT_DIR=${0:A:h:h}
APP_DIR="$PROJECT_DIR/build/AgentAllowance.app"
CONTENTS_DIR="$APP_DIR/Contents"
ICON_SOURCE="$PROJECT_DIR/Packaging/AppIcon.icns"

cd "$PROJECT_DIR"
swift build -c release
BIN_DIR=$(swift build -c release --show-bin-path)

# Start from an empty bundle so resources from earlier builds never linger.
rm -rf "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp "$BIN_DIR/AgentAllowance" "$CONTENTS_DIR/MacOS/AgentAllowance"
cp "$PROJECT_DIR/Packaging/Info.plist" "$CONTENTS_DIR/Info.plist"

if [[ -f "$ICON_SOURCE" ]]; then
    cp "$ICON_SOURCE" "$CONTENTS_DIR/Resources/AppIcon.icns"

    # With full Xcode installed, also compile the icon into an asset catalog, the format
    # macOS 26 prefers for app icons. Command Line Tools alone have no actool, so the
    # bundle then keeps only the .icns (CFBundleIconFile).
    if ACTOOL=$(xcrun --find actool 2>/dev/null); then
        ASSET_WORK=$(mktemp -d)
        trap 'rm -rf "$ASSET_WORK"' EXIT
        ICONSET_DIR="$ASSET_WORK/Assets.xcassets/AppIcon.appiconset"
        mkdir -p "$ICONSET_DIR" "$ASSET_WORK/out"

        iconutil -c iconset -o "$ASSET_WORK/AppIcon.iconset" "$ICON_SOURCE"
        cp "$ASSET_WORK/AppIcon.iconset/"*.png "$ICONSET_DIR/"

        echo '{"info":{"author":"xcode","version":1}}' > "$ASSET_WORK/Assets.xcassets/Contents.json"
        IMAGES=()
        for size in 16 32 128 256 512; do
            IMAGES+=("{\"idiom\":\"mac\",\"size\":\"${size}x${size}\",\"scale\":\"1x\",\"filename\":\"icon_${size}x${size}.png\"}")
            IMAGES+=("{\"idiom\":\"mac\",\"size\":\"${size}x${size}\",\"scale\":\"2x\",\"filename\":\"icon_${size}x${size}@2x.png\"}")
        done
        echo "{\"images\":[${(j:,:)IMAGES}],\"info\":{\"author\":\"xcode\",\"version\":1}}" > "$ICONSET_DIR/Contents.json"

        "$ACTOOL" "$ASSET_WORK/Assets.xcassets" \
            --compile "$ASSET_WORK/out" \
            --platform macosx \
            --minimum-deployment-target "$(plutil -extract LSMinimumSystemVersion raw "$CONTENTS_DIR/Info.plist")" \
            --app-icon AppIcon \
            --output-partial-info-plist "$ASSET_WORK/partial.plist" > /dev/null
        cp "$ASSET_WORK/out/Assets.car" "$CONTENTS_DIR/Resources/Assets.car"
        plutil -replace CFBundleIconName -string AppIcon "$CONTENTS_DIR/Info.plist"
    fi
fi

codesign --force --deep --sign - "$APP_DIR"
echo "$APP_DIR"
